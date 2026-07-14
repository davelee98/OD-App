# Device Configuration Flow Audit

Audited: `Views/ToolboxView.swift`, `Protocol/ToolboxConfigRuntime.swift`, `Protocol/OpenDisplayJSRuntime.swift`, `Models/ToolboxData.swift`, `Resources/toolbox-config-engine.js` (read-only), `Tests/ToolboxConfigTests.swift`, `scripts/toolbox-config-smoke.swift`, plus the entry point (`Views/AdvancedView.swift`) and the adjacent `Views/AdvancedSettingsView.swift`. Date: 2026-07-07.

## Overview

The Device Configuration flow (home gear → Advanced → Device Configuration) lets a user compose the full OpenDisplay firmware configuration — board, panel, power, deep sleep, encryption, plus a raw packet editor — and read/write it over BLE. Encoding, decoding, validation, and the simple-preset builder run in a JavaScriptCore port of the website Toolbox (`toolbox-config-engine.js`), keeping `config.yaml` the protocol source of truth. The overall engineering quality is high: watchdogs cover every BLE exchange, encode is gated on schema validation, unknown firmware packets are preserved through read-edit-write, and the JS boundary is well tested. However, the Simple-mode read-back path maps preset indexes incorrectly (a real hardware-misconfiguration risk), a failed preset build silently writes the previous configuration, and the connect-then-write flow can wedge the UI permanently on a failed connection.

## Findings

### [HIGH] Simple-mode read-back maps preset indexes by list position, but the engine writes catalog `index` values

- **Location:** `Views/ToolboxView.swift:737-740` (`idFromIndex`), used by `syncSimpleSelections` at `Views/ToolboxView.swift:713-725`; counterpart `presetIndex` in `Resources/toolbox-config-engine.js:294-299`; data in `Resources/simple-config-presets.json`.
- **Issue:** When writing, `build_simple` stores `simple_config_driver_index` / `display_index` / `power_index` using each preset's explicit `index` property (`presetIndex` returns `item.index` when present — and every entry in `simple-config-presets.json` has one). When reading back, `idFromIndex` interprets the stored number as a **1-based list position** (`values[index - 1].id`). The two agree only where `index` happens to equal position. They diverge for boards from position 8 onward (`reterminal-sticky` is position 8 with `index: 20`; `ee03` is position 9 with `index: 8`) and for most displays (`ep75-800x480` is position 19 with `index: 14`; position 14 is `ep42-400x300`).
- **Impact:** A device configured by this very app (or the website) reads back showing the wrong board/display/power in Simple mode. Two of the built-in preset tiles already round-trip wrong: “Waveshare PhotoPainter” (`esp32-s3-wspp`, position 19, index 18) reads back as `m3-core-silabs`, and `ep73-spectra-800x480` (position 21, index 15) reads back as `ep42yr-400x300`. If the user then taps “Configure over Bluetooth” trusting the displayed selection, the app writes a *wrong panel/board configuration to real hardware* (wrong panel IC init sequence, wrong pins). The `compatibleDisplays` fallback at `ToolboxView.swift:724` can mask the mismatch by silently substituting the board's default display, which is also wrong.
- **Recommendation:** In `idFromIndex` (or a dedicated helper), resolve by the catalog item's `index` property (`values.first { $0.index == parsedValue }`), falling back to position only when `index` is nil — exactly mirroring `presetIndex`. `ToolboxBoard`/`ToolboxDisplay`/`ToolboxPower` already decode `index`. Add a unit test asserting `buildSimple → syncSimpleSelections` round-trips every catalog entry.
- **Related data issue (flag only, do not implement):** `simple-config-presets.json` contains duplicate display indexes — `ep29yr-168x384`, `ep397-800x480`, and `ep426-800x480-4g` all carry `index: 33`. Even with the Swift fix, read-back for those three is ambiguous. This is a `Resources/` data problem (likely inherited from the website) — flag to the user/upstream; per project policy, do not edit Resources.

### [HIGH] A failed Simple build still writes the previous configuration and reboots the device

- **Location:** `Views/ToolboxView.swift:421-433` (Configure button action) and `Views/ToolboxView.swift:621-636` (`buildSimpleConfiguration`).
- **Issue:** `buildSimpleConfiguration()` catches any `buildSimple` error (e.g. “Cannot add, remove, or reorder packets while preserving an unknown packet tail”, thrown by the engine at `toolbox-config-engine.js:375-379`) and only logs it. The button action does not check the outcome: it proceeds to `writeConfiguration(rebootWhenDone: true)`, which encodes and writes whatever `configuration` held *before* the tap — typically the config previously read from the device — then reboots.
- **Impact:** The user selects new hardware, taps Configure, sees a progress bar, a “Configuration written successfully” log line, and a reboot — but the device still has its old configuration. Their selection was silently dropped. The tiny “Configuration build failed” log entry is easy to miss below the fold.
- **Recommendation:** Make `buildSimpleConfiguration()` return `Bool` (or throw) and abort the button action on failure (`isConfiguring = false`, keep the error log, optionally an alert). Same guard for the deferred-connect path, which also calls `buildSimpleConfiguration()` before showing the connection sheet.

### [MEDIUM] Connect-then-write flow wedges the view permanently if the connection fails after the sheet dismisses

- **Location:** `Views/ToolboxView.swift:140-149` (`onChange(of: device?.connectionState)`), `Views/ToolboxView.swift:168-175` (connection sheet `onDismiss`), `Views/ToolboxView.swift:132-135`.
- **Issue:** Tapping Configure with no device sets `isConfiguring = true`, `writeAfterConnecting = true` and shows the connection sheet. The sheet auto-dismisses as soon as `ble.connectedDevice` is set — which happens at CoreBluetooth `didConnect`, *before* GATT discovery. The `onDismiss` reset only runs when `connectedDevice == nil`. If the connection then ends in `.failed` (or drops) instead of reaching `.connected`, the `onChange` handler never fires: `writeAfterConnecting` stays true, `isConfiguring` stays true, and the progress row is stuck at “Preparing configuration…” with the Configure button disabled — indefinitely, with no timeout. The only escape is leaving the screen (state resets because it is `@State`).
- **Impact:** The app appears to hang mid-configuration on any failed connect. Worse, `writeAfterConnecting` remains armed: if a connection later succeeds for any reason while the user is still on the screen, a stale configuration write plus reboot fires unexpectedly.
- **Recommendation:** In the `connectionState` onChange, also handle `.failed`/`.disconnected` while `writeAfterConnecting` is set: clear `writeAfterConnecting`/`rebootAfterWrite`, set `isConfiguring = false`, `configureProgress = 0`, and log a clear “Connection failed — configuration not written” error. Consider a watchdog on the connect-to-write window as belt and braces.

### [MEDIUM] Custom schema applied in the Toolbox silently changes config encode/decode for the whole app, for the rest of the session

- **Location:** `Views/ToolboxView.swift:553-560` (schema editor Apply), `Protocol/ToolboxConfigRuntime.swift:47-53` (`applySchema` mutates the singleton JS engine's global `schema`), consumed app-wide via `Protocol/ODConfig.swift:5-11` → `Models/ToolboxData.swift:327-334` (`ToolboxPacketCodec` → `ToolboxConfigRuntime.shared`).
- **Issue:** “Edit Schema → Apply” replaces the active schema inside the shared `ToolboxConfigRuntime`. That runtime is the codec for *every* config read/write in the app — `ODDevice.readConfig`/`writeConfig` are used by `ContentView` (`ContentView.swift:213`) and the Composer (`ComposerView.swift:865, 1086`), not just the Toolbox. Navigating away from ToolboxView does not restore the bundled schema; only the explicit “Reload Bundled Schema” button or an app restart does.
- **Impact:** After experimenting with a custom YAML in the Toolbox, ordinary flows (connecting a display, sending an image) parse the device config against the edited schema. A schema with altered packet sizes mis-decodes width/height/color scheme, or makes decode fail outright — long after the user left the Toolbox, with no visible connection to the cause.
- **Related:** `ToolboxPacketCodec.encode(_:schema:)`/`decode(_:schema:)` accept a `schema:` parameter that is completely ignored (`Models/ToolboxData.swift:328-334`); the call at `ToolboxView.swift:793` passes the view's schema, which has no effect. Misleading API — it *looks* like the view is scoped to its own schema when it is not.
- **Recommendation:** Either scope schema edits to the Toolbox session (restore the bundled schema in `onDisappear` unless the user opts in to keeping it) or surface a persistent, app-wide indicator that a non-bundled schema is active. Remove the dead `schema:` parameters or make them real.

### [MEDIUM] No range validation on numeric fields — out-of-range values wrap silently before hitting hardware

- **Location:** `Resources/toolbox-config-engine.js:109-123` (`encodeField` → `littleEndian`, which reduces the value modulo 256^size), `toolbox-config-engine.js:159-207` (`validationIssues` has no per-field range checks); Swift-side supplement `Models/ToolboxData.swift:295-323` (`ToolboxSwiftValidation` only checks text length and encryption-key shape); free-text numeric entry in `ToolboxView.swift:1024-1034` / `valueBinding` at `1050-1052`.
- **Issue:** In the Advanced packet editor, any numeric field is a raw TextField. At encode time, a value that exceeds the field's byte width silently wraps (70000 in a 2-byte field encodes as 4464); a negative value two's-complements; a typo like `1O0` parses to `null` and encodes as **0** (`parseNumber(raw) || 0`). Neither the engine's `validate` nor `ToolboxSwiftValidation` reports any of this, so the “Finished Package Bytes” section shows a clean encode and Write Toolbox proceeds.
- **Impact:** Plausible-looking but wrong values are written to fixed firmware packet schemas on real e-paper hardware — e.g. a wrong `deep_sleep_time_seconds`, a wrong pin number, a battery threshold of 0 — with zero feedback. This is exactly the class of silent corruption the packet-bytes preview cannot catch by eye.
- **Recommendation:** The engine is a read-only Resource, so add checks to `ToolboxSwiftValidation.issues(for:schema:)` (the established pattern for supplementing the engine): for each fixed-size non-text, non-hex field, warn when `parseInteger` fails on a non-empty value (“will encode as 0”) and when the parsed value is outside `0 ..< 256^size` (“will wrap to N”). Any engine-side fix would require a `Resources/` change — flag to the user, do not implement.

### [MEDIUM] JSON export/import silently drops the preserved unknown-packet tail

- **Location:** `Views/ToolboxView.swift:678-697` (`exportConfiguration` builds the JSON by hand, no tail), `Views/ToolboxView.swift:699-711` (`importResult` decodes via `JSONDecoder.toolbox`), `Models/ToolboxData.swift:267-274` (`unknownPacketTail` is deliberately excluded from `CodingKeys`).
- **Issue:** The in-app read-edit-write cycle carefully preserves `unknownPacketTail` (newer-firmware packets this app cannot parse), and structural edits are locked down while a tail exists. But Export JSON omits the tail entirely, and Import sets `lastPersistedConfiguration = configuration` — marking the tail-less config as “clean”.
- **Impact:** A user who exports a device's config as a backup, later imports it, and writes it back has silently stripped the firmware-extension packets the device originally had. The whole point of the tail-preservation machinery is defeated by the backup path, with no warning.
- **Recommendation:** Include `unknown_tail_hex` in the export object and honour it on import (the JS engine already speaks that key). At minimum, warn on export/import when a non-empty tail is being dropped.

### [LOW] A background config read clobbers unsaved packet edits without confirmation

- **Location:** `Views/ToolboxView.swift:119-124` (`onChange(of: device?.config)`); external read triggers at `ContentView.swift:213` and `ComposerView.swift:865, 1086`.
- **Issue:** Whenever `device.config` changes, the handler unconditionally replaces `configuration` and `lastPersistedConfiguration`. The comment documents this as intended sync, but if the user has unsaved Advanced-mode edits (the view even shows the orange “Edits not yet written” badge) and a read initiated elsewhere completes — e.g. the auto-read on connect racing the user's first edits — their edits are silently discarded and the dirty flag cleared. This contradicts the dirty-guard philosophy applied to Import/Reset/Reload.
- **Recommendation:** When `hasUnsavedChanges`, don't overwrite silently — keep the edits and log/badge that a newer device config is available, or route through the existing `DirtyAction` confirmation.

### [LOW] `syncSimpleSelections` never clears stale security/deep-sleep state

- **Location:** `Views/ToolboxView.swift:726-735`.
- **Issue:** `isLocked`/`encryptionKey` are only ever set to true/populated (when packet 39 has `encryption_enabled != 0`) and `deepSleepMinutes` only updated when packet 4 exists. Reading a device *without* encryption after having toggled the lock on (or after reading a locked device) leaves `isLocked = true` and the old key in the field; the next Configure would then re-enable encryption with a leftover key.
- **Recommendation:** Add the else branches: no packet 39 or `encryption_enabled == 0` → `isLocked = false`, `encryptionKey = ""`; no packet 4 → `deepSleepMinutes = 0`.

### [LOW] Destructive actions are inconsistent between the two “advanced” surfaces

- **Location:** `Views/ToolboxView.swift:181-184, 497-500` vs `Views/AdvancedSettingsView.swift:23-28`.
- **Issue:** ToolboxView requires confirmation to reboot; `AdvancedSettingsView` (reached from a saved display's Advanced Settings row) reboots, deep-sleeps, and **enters DFU** — the most disruptive action of all — with a single unconfirmed tap. The two surfaces don't conflict on persisted settings (AdvancedSettingsView writes nothing), but “Deep Sleep” there is an immediate sleep-now command while “Deep sleep” in the Toolbox is a configured wake interval — same label, different semantics, likely to confuse.
- **Recommendation:** Add confirmation to Enter DFU (and ideally Reboot) in `AdvancedSettingsView`; rename one of the deep-sleep labels (e.g. “Sleep Now” vs “Deep sleep interval”).

### [LOW] “Reset Packet UI” silently does nothing when an unknown packet tail is preserved

- **Location:** `Views/ToolboxView.swift:394` (button) and `Views/ToolboxView.swift:872-873` (`resetConfiguration` guard).
- **Issue:** With a non-empty `unknownPacketTail`, the destructive button is still enabled, may even show the “Discard unsaved changes?” confirmation, and then no-ops with no feedback.
- **Recommendation:** Disable the button when `!configuration.unknownPacketTail.isEmpty` (matching the packet-list footer's explanation) or log why nothing happened.

### [LOW] Read/write failures are logged twice in the status log

- **Location:** `Views/ToolboxView.swift:129-131` (`onChange(of: device?.lastError)`) vs the direct completion logging in `readConfiguration` (`:609-619`) and `writeConfiguration` (`:658-660`); `ODDevice` sets `lastError` on the same failures (`BLE/ODDevice.swift:343, 349, 450`).
- **Issue:** The first occurrence of a read/write failure produces two nearly identical log rows (completion + `lastError` diff). The comments explain why the completion path exists (repeat-error dedup), but the catch-all doesn't exclude errors already reported.
- **Recommendation:** Cosmetic; either tag toolbox-originated operations so the catch-all skips their `lastError`, or accept the duplicate.

### [INFO] Concurrency: currently safe, but only by convention

- **Location:** `Protocol/ToolboxConfigRuntime.swift:101-125`, `Protocol/OpenDisplayJSRuntime.swift:29`, `BLE/BLEManager.swift:48`, `BLE/CoreBluetoothTransport.swift:31`.
- **Assessment:** Everything that touches either JSContext runs on the main thread today: `CBCentralManager` is created with `queue: .main`, so all BLE callbacks (and hence `ODConfig.parse`/`serialize`) are main-thread; ToolboxView calls the runtime from SwiftUI. `CoreBluetoothTransport` asserts this (`dispatchPrecondition`), but `ToolboxConfigRuntime` — a globally reachable singleton whose JS engine holds mutable state (`schema`) — has no such assertion. JavaScriptCore's per-VM locking would prevent memory corruption from a stray background call, but interleaved `apply_schema`/`encode` calls could still produce wrong bytes. Add `dispatchPrecondition(condition: .onQueue(.main))` at the top of `ToolboxConfigRuntime.call` to turn a future regression into a loud crash instead of silent misbehaviour. The synchronous main-thread JS round-trips per keystroke (encode + validate on every `configuration` change) are acknowledged in comments and acceptably fast at current config sizes.

### [INFO] Minor usability notes

- The Simple flow's section headers imply numbered steps but only step “1. Choose Hardware” exists (`ToolboxView.swift:257`); presets, deep sleep, and the Configure action are unnumbered, so the intended order (preset → hardware → sleep → configure) is conveyed only by layout.
- Back navigation with unsaved packet edits is deliberately not intercepted (documented at `ToolboxView.swift:59-61`); the in-view destroyers are guarded. Reasonable trade-off, worth revisiting if NavigationStack interception becomes practical.
- The navigation title “OpenDisplay Device Configuration” is long for inline display; the entry row calls it “Device Configuration”.

## Positive observations

- **Every BLE exchange has a stall watchdog** (`ODDevice.makeWatchdog`, 10 s): read, write, firmware, MSD, auth. Since `ble-common.js` has no timeouts of its own, this is what keeps the UI from hanging on a silent device — and completions are documented to fire exactly once (`didComplete` guards everywhere).
- **Invalid configurations cannot reach the device through the normal paths**: the engine's `encode` runs `validationIssues` first and throws on any error (missing required packet, duplicate instance, unknown type, packet/sequence capacity), `encodedConfiguration == nil` disables Write Toolbox, and `ODDevice.writeConfig` re-serializes through the same gate. The firmware's missing 0xCE/0xCF completion is worked around with native per-chunk ACK counting plus NACK detection (`ODDevice.swift:408-434`).
- **Unknown-packet-tail preservation is thorough**: decode keeps unrecognized bytes verbatim, structural edits (add/remove/reorder) are disabled while a tail exists, and `build_simple` refuses to change packet structure under a tail — so newer-firmware settings survive a read-edit-write cycle.
- **The dirty-state model is well designed**: `lastPersistedConfiguration` diffing, an orange unsaved badge, and confirmation dialogs before Import/Reset/Reload.
- **Text-field handling is carefully matched to the engine** (null-terminator byte reserved, UTF-8 clamping at grapheme boundaries, the ssid/password by-name special case mirrored and regression-tested) — `Tests/ToolboxConfigTests.swift` covers round-trips, truncation, duplicate instances, and the seeding bug that once wrote literal `0x0` as an SSID.
- **Performance pitfalls are documented and fixed in place**: cached encode/validate instead of per-render JS calls, `.onChange` instead of resubscribing `.onReceive`, `.sheet(item:)` to fix a first-tap race, `.equatable()` on the hardware pickers — each with an explanatory comment.
- The deferred write correctly waits for `connectionState == .connected` (GATT ready) rather than `didConnect`, avoiding writes to not-yet-discovered characteristics.
- `scripts/toolbox-config-smoke.swift` exercises the real bundled JS end-to-end (build → encode → decode → validate, UTF-8, duplicates, capacity) without needing the app.
