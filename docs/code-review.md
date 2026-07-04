# Full Code Review — OpenDisplay Utility

*Reviewed 2026-07-04 · all 27 Swift files (~6,200 lines) · analysis only, no changes applied*

Overall the architecture is sound and the code quality is well above average — the BLE stack is carefully layered, watchdogs cover most stall paths, and comments explain *why* decisions were made. The main problems are: **one functional bug in the Composer (adjustment sliders do nothing)**, **a latent packing mismatch for B/W+color panels**, **an upload path with no timeout**, and **a logging system that is 100% `print()` with no severity levels at all**.

## Architecture assessment

The layering is clean and consistent:

- **UI → BLEManager → ODDevice → CoreBluetoothTransport → CBPeripheral** for the radio, with protocol logic delegated to the verbatim web `ble-common.js` via `Protocol/OpenDisplayJSRuntime.swift`. Single shared `BLEManager` via `.environmentObject` is correct.
- The "JS owns the protocol, Swift owns transport" split is well executed — the transport is genuinely the only type touching the characteristic, and the native chunk-ACK workaround in `writeConfig` is well documented.
- Watchdog coverage (GATT stall, config read, config write) shows good defensive design.

Two architectural concerns:

1. **`Views/DisplayDetailView.swift:7` is dead code.** Nothing references `DisplayDetailView` — `ContentView.swift:69-71` navigates straight to `ComposerView`. Its doc comment claims it's the detail screen with the "Send New Photo" button, but it's unreachable. Either wire it back in or delete it (note `AdvancedSettingsView` in the same file *is* used and must survive).
2. **Synchronous JavaScriptCore calls in SwiftUI computed properties.** `Views/ToolboxView.swift:659-667`: `encodedConfiguration`, `configurationValidation`, and `shareURL` each run a separate JS `encode`/`validate` on **every body evaluation** — up to 3 JS round-trips per render in Advanced mode, each printing 2 trace lines. During a config read (body re-evaluated per BLE chunk) this is a real main-thread and log-spam cost. Cache the encoded result keyed on `configuration`.

## Crash risks

1. **`fatalError` on bundle resources** — `Protocol/ToolboxConfigRuntime.swift:7-10` and `Models/ToolboxData.swift:187-194`. A missing/corrupt `toolbox-config-engine.js`, `config.yaml`, or `simple-config-presets.json` crashes at launch. Defensible for a truly-bundled resource, but the error never reaches a user or a log service. At minimum log before dying; better, degrade to a "configuration engine unavailable" state since the *consumer* flow (photo sending) doesn't need this engine.
2. **Unclamped `UInt8` conversions** — `Models/LEDPattern.swift:16-18`: `UInt8(r * 7)` traps if `UIColor.getRed` returns an extended-sRGB component outside 0…1 (negative → "Negative value is not representable"). Today colors are hardcoded presets so it won't fire, but the moment anyone adds a `ColorPicker` this becomes a crash. Same pattern: `onNibble`/`gapByte`/`durationUnits` (`LEDPattern.swift:22-23`, `:69`) trap on negative ms, and `UInt8(min(c.count, 15))` in `Protocol/ODCommands.swift:26` traps on negative count. Clamp with `UInt8(clamping:)` / `min(max(...))` throughout.
3. **Bounds safety in advertisement parsing is actually correct** — `dynamic[index + 4]` etc. in `Models/AdvertisementData.swift:154-170` checked against the validated ranges in `ODAdvertisementLayout` (touch ≤ 6, SHT40 ≤ 8, bq27220 ≤ 10 on an 11-byte array); no out-of-bounds is reachable. Good.

## Hang risks

1. **`uploadImage` has no watchdog** — `BLE/ODDevice.swift:411-442`. 10s watchdogs were added to `readConfig` and `writeConfig` precisely because `ble-common.js` promises can stall forever, but the image upload has none. If the device stops ACKing mid-upload, `isUploading` stays `true` forever and the Composer's full-canvas upload overlay (`ComposerView.swift:163`, `allowsHitTesting(true)`) blocks the UI indefinitely with no error. Same gap, bigger blast radius. `readFirmware`, `readMSD`, and `authenticate` also have no timeout, but their failure modes are less visible.
2. **Trace flood during upload defeats the chunk-log suppression.** `BLE/ODDevice.swift:502-511` deliberately suppresses per-chunk log entries — but `transport.onNotification` (`ODDevice.swift:127-133`) calls `trace("notification received…")` for **every** chunk ACK, and the transport traces every `write()`/`drainWrites` (`CoreBluetoothTransport.swift:32`, `:55`). Each trace appends to the `@Published` `log` array → `objectWillChange` → Composer body re-render. A 210-chunk upload produces ~600 main-thread log appends and re-renders — exactly the churn the suppression comment says was being avoided. Gate transport/notification traces behind `BLELogging.detailedPayloads` too.
3. **`BLEManager.log` is unbounded** (`BLE/BLEManager.swift:12`). The UI only shows `suffix(50)` but the array grows for the whole session; combined with (2), a few uploads leave thousands of entries publishing on every append. Cap it (e.g. keep last 500) the way `ToolboxView.statusLog` already does.

## Logic bugs (by page)

### ComposerView — the most important finding in the review

- **The exposure/brightness/contrast sliders don't update the canvas.** All the infrastructure exists (`composerCanvasQueue`, render token, downscaled `previewBase`, `refreshCanvasImage()`), but nothing calls `refreshCanvasImage()` when the sliders move — there is no `.onChange(of: exposureEV/brightness/contrast)` anywhere in `Views/ComposerView.swift` (adjustments at :289-321). The canvas only refreshes on photo load, color-scheme change, or pressing Preview. The final send *does* apply the values (in `renderComposite`), so users adjust blind. Fix: add `.onChange` for the three values calling `refreshCanvasImage()`.
- **Silent send failure** — `ComposerView.swift:633-634`: if `ImageProcessor.process` returns nil, `sendPhoto` just `return`s from a background queue. The user taps Send and nothing happens, nothing logged. Set `device.lastError` and log it.
- **`resetPage()` resets `colorScheme = 0`** (`ComposerView.swift:588`) instead of re-deriving the panel's scheme via `applyScheme(device?.config?.colorScheme ?? entity scheme)`. After a reset on a 4-gray panel, the Preview renders 1-bit B/W while Send encodes 4-gray — preview and result diverge.

### DisplayCanvasView

- **`odGenerateQR` ignores its `color` parameter** (`Views/DisplayCanvasView.swift:221-229`) — the QR swatch picker in the Composer does nothing; QR codes are always black. Apply a `CIFilter.falseColor` pass or drop the picker.
- Pan/zoom are unbounded (photo can be dragged entirely out of the crop box) — minor UX, not a bug.

### ImageProcessor

- **Scheme 1/2 packing is internally inconsistent with the size check.** `expectedPackedByteCount` for schemes 1, 2, 5 is row-padded: `((width+7)/8) * height * 2` (`Models/ImageProcessor.swift:53`), but `pack2planes` (`ImageProcessor.swift:266-277`) packs bits continuously across rows: `(w*h+7)/8` per plane. For any panel whose width isn't a multiple of 8, the two disagree and `uploadImage`'s guard (`ODDevice.swift:420-424`) will reject every B/W+Red / B/W+Yellow upload. `packGray4` (scheme 5) is row-padded and correct — `pack2planes` should be rewritten the same way (row-padded is almost certainly what the panel expects too).

### ODDevice

- **`sendRaw` drops its `label` and never reports failure** (`BLE/ODDevice.swift:158-162`). The `label:` argument ("LED Pattern", "Raw", …) is unused, so BLE Tester entries lose their names, and on failure the completion is never called and no error is surfaced — a failed raw send is invisible.

### Toolbox / config layer

- `ODConfig.serialize` swallows the encode error with `try?` (`Protocol/ODConfig.swift:9-11`); `writeConfig` then reports the generic "Could not build Toolbox configuration", losing the actual JS validation message.
- `ToolboxConfiguration.remove(type:autoSecurityOnly:)` ignores its `autoSecurityOnly` parameter (`Models/ToolboxData.swift:268-270`) — either implement it or remove it before someone relies on it.

### BLEManager

- **Cold-start `startScan()` is a silent no-op** (`BLE/BLEManager.swift:68-70`): the first call creates the central (state `.unknown`), then the poweredOn guard bails without setting `isScanning` or logging. `centralManagerDidUpdateState` resumes reconnects but *not* scans. The two scan sheets both work around this with their own `.onChange(of: bluetoothState)`, but any future caller will hit it. Track a `pendingScan` flag the way `pendingReconnectID` is tracked, and log the deferral.
- `didDisconnectPeripheral` calls `deactivate()` (`BLEManager.swift:273`), which clears `pendingReconnectID` unconditionally — if display A drops while a reconnect to display B is pending, B's reconnect is silently killed. Edge case, worth a guard.

### ODAuth

- `randomPSK()` falls back to an **all-zero key** on `SecRandomCopyBytes` failure (`Protocol/ODAuth.swift:41-47`) — silently generating a known key for an *encryption* feature. Fail loudly instead (return nil / fatal), and log it.
- `SecItemDelete`/`SecItemAdd` statuses are discarded in `savePSK` (`ODAuth.swift:15-16`) — a keychain save failure means the user can never re-authenticate, and there's no trace of why.

## Logging: no levels exist, and errors go missing

This is the weakest area relative to the stated requirements:

- **Everything is `print()`** — zero use of `os.Logger`/`os_log` anywhere in the app. That means: no severity levels at all, no subsystem/category filtering in Console.app, nothing persisted for a TestFlight/field report, and `print` still pays string-interpolation cost in Release builds.
- **Prefixes are inconsistent**: `[BLE]`, `[BLETrace]`, `[OpenDisplayJSRuntime]`, `[ToolboxConfigRuntime]`, `[ble-common]`, and leftover `[diag]` debug prints in `Views/ToolboxView.swift:108, :117, :123, :525, :534` that read like a debugging session that was never cleaned up.
- **Severity is flattened**: `BLEManager.trace` logs GATT failures, routine state changes, and stall watchdogs identically. `didFailToConnect` (a real error) and "activate reused central" (debug noise) are indistinguishable.
- **Silent failure paths with no log at all**: keychain save/delete failures, `randomPSK` fallback, `sendPhoto`'s nil-pixels bail, `sendRaw` failures, `startScan` deferral, `CGContext` creation failure in `rgbaPixels` (returns `[]`).

**Recommendation:** introduce one `Logger` per subsystem — e.g. `Logger(subsystem: "org.opendisplay.app", category: "ble" / "protocol" / "toolbox" / "imaging")` — and map existing prints:

| Level | What goes there |
|---|---|
| `.error` | Stall watchdogs, GATT failures, keychain failures, upload/config failures |
| `.warning` | Unexpected-but-recovered states (retrievePeripherals miss, scan deferral, NACK) |
| `.info` | Connection lifecycle |
| `.debug` | Per-chunk / per-write traces (unified log drops these cheaply in Release) |

Route `ODDevice.trace`/`BLEManager.trace` through it so the in-app BLE Log keeps working while the console gets real levels.

## Minor notes

- `Info.plist` has both Bluetooth usage strings — good. There are two Info.plists (root and `OD App/Info.plist`); make sure the target uses the intended one.
- `BLETesterView.sendCommand` fakes completion with a 0.3s timer (`Views/BLETesterView.swift:137`) — fine for a tester, but wiring it to `sendRaw`'s (currently broken) completion would be honest.
- `SplashView` uses `UIScreen.main.bounds` (deprecated direction on iOS 17+); a `GeometryReader` fraction would be cleaner.
- LED/buzzer/NFC senders on `ODDevice` appear to have no remaining UI callers since the old DeviceDetailView was deleted — worth confirming before the clamping fixes, or pruning.

## Suggested priority

1. Composer sliders → `refreshCanvasImage()` (user-visible feature simply doesn't work)
2. `pack2planes` row padding (blocks uploads on non-×8-width B/W+color panels)
3. Upload watchdog + trace-flood gating (hang + perf during the app's core action)
4. Silent-failure logging (`sendPhoto`, `sendRaw`, keychain, `randomPSK`)
5. `os.Logger` migration with real severity levels
6. Dead-code cleanup (`DisplayDetailView`, `[diag]` prints, `autoSecurityOnly`)
