# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Native iOS/iPadOS SwiftUI app ("OpenDisplay Utility") for OpenDisplay e-paper displays. It scans for OD hardware over BLE, keeps a persistent "My Displays" registry (SwiftData), composes photos with strokes/text/QR on a panel-shaped canvas, dithers + bit-packs the result and streams it over one GATT characteristic, and exposes the schema-driven device-config "Toolbox" plus raw engineering tools. Bundle id `org.opendisplay.open-display-utility`, iOS 17.0+, Swift 5, one SPM dependency (CryptoSwift). It exists because mobile Safari blocks Web Bluetooth, so the website's tools are unusable on iPhone/iPad.

**Read [docs/architecture.md](docs/architecture.md) first** — it is thorough and current (layer map, all six major flows, design decisions, module inventory, test-coverage map). This file only covers commands and the highest-value rules.

## Commands

Xcode project is `OD App.xcodeproj`; scheme is `OD App`; test target is `OD AppTests` (hosted XCTest via `TEST_HOST`, so tests can read `Bundle.main` resources). No CocoaPods/workspace — open the `.xcodeproj` directly.

```sh
sh scripts/setup.sh          # run once after clone: installs git clean filter that strips DEVELOPMENT_TEAM from the pbxproj

# Build (BLE needs a real device; Simulator has no CoreBluetooth, app crashes on launch there)
xcodebuild -project "OD App.xcodeproj" -scheme "OD App" -destination 'generic/platform=iOS' build

# Test — pure/deterministic tests run fine on a Simulator
xcodebuild -project "OD App.xcodeproj" -scheme "OD App" -destination 'platform=iOS Simulator,name=iPhone 15' test

# Run a single test class or method
xcodebuild ... test -only-testing:"OD AppTests/ToolboxConfigTests"
xcodebuild ... test -only-testing:"OD AppTests/ToolboxConfigTests/testSimplePresetRoundTrip"
```

Signing: copy `Local.xcconfig.example` → `Local.xcconfig` (gitignored) and set your Team ID; build works without it (Automatic signing falls back to the selected team). Debug launch arg `-BLEVerbosePayloadLogging` restores per-chunk image-payload logs (suppressed by default; Debug-only).

## Non-obvious rules that will break things if ignored

- **`Resources/*.js` and `Resources/config.yaml` are vendored verbatim from opendisplay.org and must not be edited.** The single exception is `ble-app-adapter.js` (app-owned glue). `ble-common.js` (4,227 lines, the entire BLE protocol) is SHA-256-pinned by the **"Verify ble-common.js" build phase** (`scripts/verify-ble-common.sh`) — any byte change fails the build. To update it: `scripts/sync-ble-common.sh <path-to-upstream>` then paste the new hash into `verify-ble-common.sh`. This "no drift with the website" rule is the reason for the deliberate Swift-side duplication you'll see (`ToolboxSwiftValidation`, the text-field special case, the native config-write ACK counter).

- **The BLE protocol is not in Swift — it runs inside JavaScriptCore.** `OpenDisplayJSRuntime` hosts `ble-common.js` (async, event-driven); a *separate* `ToolboxConfigRuntime` JSContext runs `toolbox-config-engine.js` (synchronous request/response) for config schema/encode/decode. Swift provides only the radio, crypto primitives, timers, and UI. Don't reimplement protocol logic in Swift — call the runtime.

- **Main-thread confined.** CoreBluetooth central is created with `queue: .main`, both JSContexts are main-thread-only (not thread-safe), and `CoreBluetoothTransport.write` asserts `.onQueue(.main)`. Only image processing goes off-main, and only via immutable value-type snapshots.

- **`CoreBluetoothTransport` is the only type allowed to touch the `0x2446` GATT characteristic.** `ODDevice` forwards every `CBPeripheralDelegate` callback to it.

- **The JS layer has no timeouts.** Every native operation that waits on the device arms a `DispatchWorkItem` watchdog (`ODDevice.makeWatchdog`; ~10s, upload 30s, GATT stages 8s). Watchdog slots are single/shared, so overlapping same-kind ops clobber each other — that's why concurrent config reads *join* and concurrent writes are *rejected*.

- **`OD.configWriteChunkSize` (=200) must match the bundled JS exactly** — the native chunk-ACK prediction in `writeConfig` breaks silently otherwise. `BLEChunkSizeTests` pins it against the literal in `ble-common.js`; keep that test green.

- **Canvas geometry is stored normalized (0…1) to the aspect-locked canvas box.** Rotation/resize/late aspect changes cost nothing; final render is `normalized × panelPixels`. `CanvasCoordinateTests` proves equivalence to the old point→pixel math — don't reintroduce absolute coordinates.

- **New displays can't be saved until a real config has been read from hardware** (`ConfigReadState`, `resolutionConfirmed` provenance flag). Persisting the 800×480 fallback as confirmed is the exact bug this flow prevents.
