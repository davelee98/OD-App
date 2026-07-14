# Add-Device Race Condition Audit

Audited: 2026-07-07. Scope: the Add Display flow (`ContentView.swift` / `AddDisplaySheet`), config read plumbing (`BLE/ODDevice.swift`, `BLE/BLEManager.swift`, `BLE/CoreBluetoothTransport.swift`, `Protocol/OpenDisplayJSRuntime.swift`, `Resources/ble-app-adapter.js`, `Resources/ble-common.js` — read only), persistence (`Models/DisplayDevice.swift`), and the surfaces that re-display the cached values (`Views/ComposerView.swift`, `Views/Components/DeviceRowView.swift`, `ContentView.swift`'s `DisplayRowLabel`). Stray `" 2"` duplicate files excluded. Audit only — no source changes.

## Overview

When a user adds a display, the app is supposed to read the panel's real resolution and color scheme over BLE and persist them. In practice the config read kicked off by the Add sheet fails **deterministically** — it is fired the instant Core Bluetooth reports a link, before the GATT handshake finishes, so the JS protocol engine rejects it with "Not connected" — and nothing retries. The sheet then shows "Reading configuration…" forever, and tapping Save silently persists a hardcoded 800×480 / B-W guess as if it were a confirmed hardware reading, with no marker distinguishing guess from fact. The value is only repaired later, opportunistically, if the user opens the Composer while connected; the saved-displays list has no way to show that a value is provisional or being refreshed.

## Root cause analysis

This is not merely a "read is slow, user saves too early" race. There are two stacked mechanisms.

### Mechanism 1: the Add-flow config read fires before the link is usable (deterministic failure)

Trace, in order:

1. User taps a discovered device → `BLEManager.connect(_:)` → `centralManager.connect` (`BLE/BLEManager.swift:124-131`).
2. `centralManager(_:didConnect:)` fires on the main queue. It creates/reuses the `ODDevice` (config still `nil`), sets `device.connectionState = .connecting`, publishes `connectedDevice = device`, and only *then* starts GATT setup via `device.discoverServices()` (`BLE/BLEManager.swift:283-301`).
3. Publishing `connectedDevice` re-renders `AddDisplaySheet` on the next run-loop tick (milliseconds). Its `.onChange(of: connectedDevice)` sees a non-nil device with `config == nil` and immediately calls `device.readConfig()` (`ContentView.swift:212-213`).
4. But the JS protocol engine is only told the link is usable in `transport.onReady` — after service discovery → characteristic discovery → notify enable, each an over-the-air round trip taking hundreds of milliseconds to seconds (plus a possible pairing prompt). Only then does `ODDevice` call `runtime.setConnected(true)` and flip `connectionState = .connected` (`BLE/ODDevice.swift:153-158`, `BLE/CoreBluetoothTransport.swift:24-105`).
5. `ble-common.js`'s `readConfig` hard-gates on that flag: `if (!this.isConnected) throw new Error('Not connected')` (`Resources/ble-common.js:2335-2338`; the flag is set solely by `__odSetConnected`, `Resources/ble-app-adapter.js:35-41`). The rejected promise is routed back through `fail(id)` → `OpenDisplayJSRuntime.handleEvent` → the `readConfig` completion, which sets `lastError = "Not connected"` and leaves `config` nil (`BLE/ODDevice.swift:347-352`).

A SwiftUI render pass (~1 frame) always beats a multi-round-trip GATT handshake, so the Add sheet's one and only `readConfig()` call **always** fails on a fresh connection. `.onChange(of: connectedDevice)` never re-fires when the same `ODDevice` instance transitions `.connecting → .connected` (the observed value — the object reference — is unchanged), and nothing else in `AddDisplaySheet` triggers a read. `device.config` therefore stays `nil` for the entire Add flow.

(Contrast with the two flows that *do* work: `ComposerView` reads config from `handleConnectionState(.connected)` → `syncFromDevice()` (`Views/ComposerView.swift:822-834, 862-866`), and `ToolboxView` reads on appear against an already-connected device (`Views/ToolboxView.swift:570-577, 609-618`). Both run after `setConnected(true)`, so they succeed.)

### Mechanism 2: Save silently commits the hardcoded default as if confirmed

With `config` nil, `save(_:)` for a new display evaluates

```swift
let width  = (device.config?.displayWidth ?? 0) > 0 ? device.config!.displayWidth : 800
let height = (device.config?.displayHeight ?? 0) > 0 ? device.config!.displayHeight : 480
let scheme = Int(device.config?.colorScheme ?? 0)
```

(`ContentView.swift:281-283`) and persists 800×480 / scheme 0 (B/W) into `SavedDisplayEntity` (`ContentView.swift:288-297`). The Save button is enabled the moment `friendlyName` is non-empty — and it is pre-filled from the peripheral name in the same `.onChange` that fired the doomed read (`ContentView.swift:214, 262-265`) — so nothing gates Save on a completed read. The entity's own initializer defaults reinforce the same guess (`Models/DisplayDevice.swift:54-55`; the `DisplayDevice` DTO likewise at `:26`). Neither `SavedDisplayEntity` nor the DTO has any field recording whether width/height/scheme came from hardware or from the fallback, so no later code can distinguish "confirmed 800×480 panel" from "we never asked."

### Repair paths (when the wrong value gets fixed — and when it doesn't)

`entity.apply(config:)` (`Models/DisplayDevice.swift:94-99`) is called from exactly two places:

- `ComposerView`'s `.onChange(of: device?.config)` (`Views/ComposerView.swift:200-205`) — fires only when the config *changes while the Composer is on screen*. This is the de-facto repair path: open the Composer, it reconnects, `syncFromDevice()` triggers a successful read, `apply` fixes the entity. But if the config was already loaded before the Composer appeared (e.g. a Toolbox read on the same connection), `onChange` never fires and `syncFromDevice()` (`:862-866`) applies only the color scheme to canvas state — never `entity.apply` — so the persisted 800×480 survives.
- `AddDisplaySheet.save(_:)` in **edit mode only**, and only if the device is currently connected *and* `config` is non-nil (`ContentView.swift:274`) — which, per Mechanism 1, is normally false during the edit sheet too.

`ToolboxView` reads config but knows nothing about `SavedDisplayEntity`, so an Advanced-mode read never repairs the registry. `DisplayRowLabel` (`ContentView.swift:129`) and the Composer fall back to `entity.width/height` (`Views/ComposerView.swift:125-133`) with no indicator of provenance or freshness.

### Concurrency model (question 4)

No data race exists. The entire stack is main-queue confined by construction: `CBCentralManager` is created with `queue: .main` (`BLE/BLEManager.swift:48`), the transport asserts `dispatchPrecondition(.onQueue(.main))` (`BLE/CoreBluetoothTransport.swift:31`), the JSCore runtime is documented and used as main-thread-confined with all timers on `DispatchQueue.main` (`Protocol/OpenDisplayJSRuntime.swift:28-29, 185`), and every watchdog is scheduled on main (`BLE/ODDevice.swift:227`). `device.config` is written inside the JS-event → completion chain, which originates from a CB delegate callback on main. The bug is purely a state-machine/UX race, not memory unsafety.

## Findings

### [CRITICAL] Add-flow `readConfig()` fires before GATT ready and deterministically fails with "Not connected"
- **Location:** `ContentView.swift:212-213`; interacting with `BLE/BLEManager.swift:283-301`, `BLE/ODDevice.swift:153-158`, `Resources/ble-common.js:2335-2338`.
- **Issue:** `.onChange(of: connectedDevice)` fires when `didConnect` publishes the device (state `.connecting`, `setConnected(true)` not yet called). `ble-common.js` rejects the read immediately. The trigger never re-fires on the `.connecting → .connected` transition (same object reference), and no retry exists anywhere in the sheet.
- **Impact:** On every fresh Add (and every edit-sheet reconnect), `device.config` remains `nil` for the whole flow. Every downstream symptom in this audit follows from this: the stuck "Reading configuration…" label, and 800×480/B-W being persisted.
- **Recommendation:** Trigger the read off readiness, not existence: observe `connectedDevice?.connectionState` and call `readConfig()` on `.connected` — or better, have `ODDevice` itself auto-read config in `transport.onReady` (next to the existing `readFirmware()` call, `BLE/ODDevice.swift:158`), so every surface benefits and no view needs to remember to ask.

### [HIGH] Save persists the hardcoded 800×480 / B-W guess with no provisional marker — and can overwrite previously-correct data
- **Location:** `ContentView.swift:281-283` (fallback), `:288-297` (persist/upsert), `:262-265` (Save enabled regardless); `Models/DisplayDevice.swift:26, 54-55` (defaults), `:94-99` (no provenance field).
- **Issue:** With config unread, Save writes 800×480 and color scheme 0 into SwiftData as ordinary confirmed-looking values. Worse, the upsert branch (`:288-292`) unconditionally overwrites `width/height/colorScheme` on an *existing* entity — so re-adding a display whose entity had already been corrected (via a past Composer session) regresses it back to the defaults. Scheme 0 (B/W) also poisons the offline Composer palette for color panels.
- **Impact:** Wrong canvas aspect ratio and palette in the offline Composer, wrong "800×480 · B/W" line in the displays list, and — because there is no provenance flag — no code or user can ever tell the value was a guess.
- **Recommendation:** Add a provenance field to `SavedDisplayEntity` (e.g. `resolutionConfirmed: Bool` or a `configSource` enum), set it only in `apply(config:)`. In `save(_:)`, never fabricate dimensions: persist the entity without confirmed dimensions (or with the flag false) and keep the connection alive to finish the read; in the upsert branch, only overwrite dimensions when a fresh config is actually in hand.

### [HIGH] Read failure/timeout leaves the Add sheet stuck at "Reading configuration…" with no error and no retry
- **Location:** `ContentView.swift:237-245` (three-state header: live config / entity cache / "Reading configuration…"); `BLE/ODDevice.swift:299-368` (failure lands only in `lastError`/completion, both unobserved by the sheet).
- **Issue:** The header's fallback text claims a read is in progress regardless of whether one is in flight, failed, or was never retried. `AddDisplaySheet` passes no completion to `readConfig()` and observes neither `lastError` nor `isConfigReadInFlight` (which is `private` anyway). After the deterministic failure (or a genuine 10s watchdog timeout on a flaky link), the label is a permanent lie while Save remains enabled.
- **Impact:** The user has no signal that anything failed, no way to retry short of cancelling the sheet, and the most natural action (Save) silently commits the default.
- **Recommendation:** Publish a config-read state from `ODDevice` (see Proposed UI states) and render all four states in the header, with a Retry affordance on failure. `readConfig`'s completion parameter already exists precisely for this — use it.

### [MEDIUM] Entity re-sync from a successful read is accidental and incomplete
- **Location:** `Views/ComposerView.swift:200-205` (`.onChange(of: device?.config)` → `entity.apply`), `:862-866` (`syncFromDevice` applies scheme only, never `entity.apply`); `ContentView.swift:274` (edit-mode save applies only if connected + loaded); `Views/ToolboxView.swift:609-618` (reads config, never touches any entity).
- **Issue:** The only reliable repair path requires the config value to *change while ComposerView is visible*. If the config arrives before the Composer appears (same-session Toolbox read, or a future fix to the Add flow), `onChange` never fires and `syncFromDevice` doesn't apply it; Toolbox reads never propagate to the registry at all.
- **Impact:** A persisted 800×480 guess can survive indefinitely across app launches even though the app has repeatedly held the true config in memory.
- **Recommendation:** Centralize: whenever a config read succeeds for device X, update the `SavedDisplayEntity` with id X (e.g. a small registry service observing `ODDevice.config`, or calling `entity.apply` from `syncFromDevice` too and from a shared completion). Don't rely on view-local `.onChange` diffing.

### [MEDIUM] Config-read watchdog is a fixed 10s window, never re-armed on progress
- **Location:** `BLE/ODDevice.swift:315-317, 360-368` (armed once), `:688-691` (`configProgress` events update `configReadProgress` but do not re-arm — contrast the upload watchdog, `:675-687`, which deliberately re-arms on every progress event).
- **Issue:** A chunked config read that is making steady progress but takes >10s total (large config, long connection interval, congested radio) is declared failed. `finish(.failure)` runs, `isConfigReadInFlight` clears, `lastError` is set — yet the JS promise stays pending and, if the read then completes, the `call` completion still executes `self.config = model` (`:333-340`) because only `finish` is gated by `didComplete`, not the state mutation.
- **Impact:** Spurious timeout errors on slow links; contradictory state (caller told "failed", `config` silently populated moments later); a retry started after the false timeout can overlap the still-active JS `configReadState`.
- **Recommendation:** Re-arm the watchdog from the `configProgress` event exactly as the upload path does; on watchdog fire, also cancel/reset the JS-side read state before allowing a retry.

### [LOW] `didDisconnect()` never clears `config`, so reconnects reuse stale config and suppress fresh reads
- **Location:** `BLE/ODDevice.swift:132-150`; guard at `ContentView.swift:213` (`config == nil`) and `Views/ComposerView.swift:865` (same pattern).
- **Issue:** The cached `ODDevice` in `BLEManager.deviceMap` keeps its `config` across disconnects, and both read triggers are gated on `config == nil`, so a reconnect never refreshes. If the panel's config changed in between (another phone, web Toolbox, hardware swap at the same address), the app composes/sends against outdated resolution or color scheme with no expiry.
- **Recommendation:** Keep the cached config for instant display (it *is* the "stale value" the UI should label as such) but always kick a refresh on `.connected`, applying the result via the centralized entity-sync path.

### [LOW] Mid-add disconnect strands the sheet on "Starting Bluetooth…"
- **Location:** `BLE/BLEManager.swift:328-341` (`didDisconnectPeripheral` → deferred `deactivate()`, which sets `bluetoothState = .unknown`); `ContentView.swift:191-197, 209-211` (Scan button and auto-rescan only exist when `.poweredOn`); `ContentView.swift:336-337` (`DevicePickerContent` default case shows an indefinite "Starting Bluetooth…" spinner).
- **Issue:** If the device drops (or the app is backgrounded long enough for iOS to sever the link) while the user is on the naming step, `connectedDevice` becomes nil, the sheet falls back to the picker — and the async `deactivate()` then tears down the central, flipping `bluetoothState` to `.unknown`. Nothing in the still-open sheet calls `activate()` again (`onAppear` already ran), the Scan toolbar button is hidden, and the `.onChange(of: bluetoothState)` rescan trigger never sees `.poweredOn`.
- **Impact:** The user's entered name/location silently loses its context and the sheet shows a perpetual "Starting Bluetooth…" spinner; the only recovery is Cancel and reopen.
- **Recommendation:** In `AddDisplaySheet`, on losing `connectedDevice` while not saved, either surface an explicit "connection lost — Retry" state or re-run the `onAppear` activation logic; alternatively have `BLEManager.deactivate()` skip teardown while an Add flow holds the session.

## Proposed UI states

The single missing primitive is an observable config-read state on `ODDevice` (replacing the unpublishable `private var isConfigReadInFlight` at `BLE/ODDevice.swift:61`), plus a provenance flag on `SavedDisplayEntity`:

```swift
enum ConfigReadState { case unread, reading, confirmed(Date), failed(String) }   // @Published on ODDevice
var resolutionConfirmed: Bool                                                    // on SavedDisplayEntity
```

| State | Meaning | Where surfaced |
|---|---|---|
| **Fetching (no reading yet)** | No cached value; read in flight or about to start | Add sheet header `ContentView.swift:244`: keep "Reading configuration…" but bind it to `.reading`, not to `config == nil`; disable Save or relabel it "Save anyway" while in this state (`:262-265`) |
| **Confirmed from hardware** | Value read from the device this session | Add sheet header `:237-239` (current behavior, now meaning what it implies); `entity.apply` sets `resolutionConfirmed = true` (`Models/DisplayDevice.swift:94-99`); save persists real values (`ContentView.swift:281-297`) |
| **Stale cached, refresh in flight** | Showing `entity.width/height` while a fresh read runs | Edit-sheet header `:240-242` and `DisplayRowLabel` `:129` gain a small "updating"/clock badge keyed on `resolutionConfirmed` + `ConfigReadState.reading`; Composer size line `Views/ComposerView.swift:125-133, 771` may show the same subtle indicator |
| **Read failed** | Last read errored/timed out; cached (or no) value shown | Add/edit sheet header: error text + Retry button wired to `readConfig()` (`ContentView.swift:237-245`); Composer: today's send-time `failUpload("Waiting for a valid device configuration…")` (`Views/ComposerView.swift:1084-1087`) becomes reachable-before-send by disabling Send with an explanatory hint while state is `.failed`/`.unread` |

State transitions live in exactly one place — `ODDevice.readConfig` (`BLE/ODDevice.swift:299-354`: `.reading` on entry, `.confirmed` on decode success, `.failed` on error/watchdog) — with the read itself kicked from `transport.onReady` (`:158`) so every surface, including the Add sheet, gets it for free.
