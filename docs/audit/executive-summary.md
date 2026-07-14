# OD App Code Audit — Executive Summary

Date: 2026-07-14
Scope: six parallel audits of the areas requested — Canvas/Composer, the Add-Device flow (race condition), the Device Configuration flow, the three Engineering Tools, Dark Mode readiness, and iPad/orientation support. Each area has a standalone findings document in this directory; this summary synthesizes across all six and calls out cross-cutting themes.

| Document | Critical | High | Medium | Low |
|---|---|---|---|---|
| [add-device-race-condition.md](add-device-race-condition.md) | 1 | 2 | 2 | 2 |
| [canvas-composer.md](canvas-composer.md) | 0 | 3 | 3 | 5 |
| [device-configuration.md](device-configuration.md) | 0 | 2 | 4 | 5 |
| [engineering-tools.md](engineering-tools.md) | 0 | 3 | 9 | 10 |
| [dark-mode-readiness.md](dark-mode-readiness.md) | 0 | 1 | 2 | 2 |
| [ipad-orientation-support.md](ipad-orientation-support.md) | 0 | 1 | 4 | 2 |
| **Total** | **1** | **12** | **24** | **26** |

Overall: the codebase is well-structured with real engineering discipline in places (BLE watchdogs, validation-gated writes, tail-preservation in config export, clean gesture composition in most of the Composer). The problems cluster in three places: **one deterministic bug** in the add-device flow, **one architectural gap** in the canvas/annotation coordinate system that resurfaces in three of the six audits, and **UX/consistency debt** across the Engineering Tools and appearance-adaptation areas rather than deep correctness rot.

## The one thing to fix first

**[CRITICAL] The add-device resolution/color-scheme bug is not a race — it's deterministic, and it happens on every single add.** (`add-device-race-condition.md`)

`AddDisplaySheet`'s `.onChange(of: connectedDevice)` fires the moment CoreBluetooth reports "connected," which is *before* the app's own connection-setup (`runtime.setConnected(true)`) completes. The device's own JS layer (`ble-common.js`) hard-rejects the config read with "Not connected" at that point, and nothing retries — so `device.config` stays `nil` for the entire add flow, every time, not occasionally. The Save button is enabled from the first frame and silently commits the hardcoded 800×480 / color-scheme-0 default as if it were a confirmed hardware reading, with no field anywhere to distinguish "guessed" from "confirmed." Because the upsert path in `save(_:)` overwrites existing entities unconditionally, this can also **regress a previously-correct saved resolution** if a user re-opens an already-good device and happens to hit Save before a fresh read lands.

This exactly confirms the symptom you described — the front screen defaulting to 800×480 instead of indicating "updating" — and the fix is UI-state, not timing: introduce an explicit `ConfigReadState` (not-yet-read / reading / confirmed / stale-cached / failed) and gate Save (or at least visibly flag the value) on it, rather than silently falling through to a numeric default. `add-device-race-condition.md` includes the specific four-state design and every call site that needs to change.

## Theme 1: the canvas/annotation coordinate model is the single biggest architectural finding, and it appears in three audits independently

Three separate agents — auditing Canvas/Composer, the race condition, and iPad/orientation — converged on the same root cause without being told to look for it:

- `DisplayCanvasView` stores strokes, text, QR codes, and photo pan/zoom in **absolute canvas points**, while the canvas box itself is re-derived from `GeometryReader` on every layout pass (rotation, iPad Split View/Stage Manager resize, or a late-arriving device config that changes the aspect ratio).
- The result: rotating the device, resizing a multitasking window, or a background config read landing after the user started composing can all silently shift the crop and drift annotations relative to the photo — and `renderComposite` faithfully sends whatever the rearranged result is to the physical display, with no error and no undo.
- Also in this cluster: pinch-to-zoom (photo) and drag (element move/resize) run as simultaneous gesture recognizers with no coordination, so pinching over an element both resizes and drags it, occasionally pushing duplicate undo entries. Per `canvas-composer.md`, the originally-intended "resize via corner handles, not pinch" model appears to have never been implemented — resize is pinch-based today, which is the root of the conflict.

**Recommendation:** this is worth scoping as one fix, not three. Move annotation/pan state to normalized (0–1) or panel-pixel coordinates, and capture gesture baselines at gesture-start rather than persisting them across the view's lifetime. `canvas-composer.md` and `ipad-orientation-support.md` both have exact file:line locations.

## Theme 2: Device Configuration has a real firmware-write bug, not just UX debt

`device-configuration.md` found that `ToolboxView.idFromIndex` maps stored preset indices by **list position**, while the JS config engine writes each preset's explicit `index` property — these diverge for boards past position 7 and most displays (e.g. a device configured with `ep75-800x480` reads back showing `ep42-400x300`). Re-writing from that misread state sends the wrong panel/pin configuration to real hardware. Separately, a failed "Simple" config build is swallowed and the *previous* configuration is written anyway with a success message shown to the user. Both are high-severity because they write incorrect data to physical devices, not just incorrect data to the screen.

## Theme 3: the Engineering Tools work, but actively fight the debugging sessions they exist for

`engineering-tools.md` (the largest single findings set, 3 High / 9 Medium / 10 Low) found the BLE Tester and BLE Log are functionally solid but have a pattern of **failing exactly under the conditions engineers actually use them**: the Tester silently hides any packet whose second byte is `0x71` (which includes its own "Image Data" preset — the tool appears broken for that command), auto-scroll permanently stops the moment the shared log hits its 500-entry cap (i.e., during exactly the long sessions the tool is for), and the BLE Log opens at the *oldest* entry with Share/Clear buried below up to 500 rows. A stale `lastError` banner is never cleared for the rest of the session in either tool. Three tools also implement three different logging designs with three different clear-confirmation behaviors — one of them (BLE Log) clears the shared log with an unconfirmed single tap, while the Tester confirms clearing the identical resource.

None of this blocks release, but it's the kind of debt that erodes trust in the tools during the moments they matter most (an engineer chasing a flaky connection in the field).

## Theme 4: Dark Mode and iPad support are "unadapted but not broken" — narrower gaps than expected

Both audits found the app is in reasonable shape structurally (no forced `.preferredColorScheme`, no `UIUserInterfaceStyle` override, `TARGETED_DEVICE_FAMILY = "1,2"` already builds for iPad, zero `UIScreen.main.bounds`/`UIDevice.orientation` anti-patterns) — the gaps are narrow and fixable rather than systemic:

- **Dark Mode:** the app already tracks system appearance and ~90% of the UI (all system components, semantic colors) adapts correctly today. The real defect is the `ODLogo` asset having no dark-appearance variant — the "OpenDisplay" wordmark is pure black with no fallback, so it disappears against a dark background on the home screen header. `SplashView` is fully hardcoded light (a 5-second bright flash at launch in dark mode) — flagged as possibly-deliberate branding, needs a product call. A black ink-color swatch in the Composer is nearly invisible against the dark palette panel.
- **iPad/orientation:** the app runs on iPad today but reads as a stretched iPhone app. `ComposerView`'s landscape branch only checks `verticalSizeClass == .compact` (an iPhone-landscape signal), so iPad landscape gets the phone's stacked portrait layout with large dead margins instead of using the freed-up width. `ContentView`'s device list and `ToolboxView`'s form are both single-column layouts that don't take advantage of iPad's width — `NavigationSplitView` is recommended as a design direction, not urgent. The one High-severity finding here (canvas coordinate drift on rotate/resize) is the same defect as Theme 1 above, not a separate bug.

## Cross-cutting recommendations, in priority order

1. **Fix the add-device config-read flow first.** It's the only Critical finding, it's deterministic (not intermittent), and it's the specific bug you asked about. Introduce the `ConfigReadState` design in `add-device-race-condition.md` before touching anything else in that flow.
2. **Fix the Toolbox preset-index round-trip bug** (`device-configuration.md`, Finding 1) — it writes wrong configuration to real hardware, which is a step beyond every other finding in this audit.
3. **Rework the canvas/annotation coordinate model** to normalized coordinates and gesture-start-relative baselines — this single change resolves the top finding in three of the six documents (Canvas/Composer, iPad/orientation, and a contributing factor in the add-device flow's Composer-side symptoms).
4. **Engineering Tools log/scroll/clear-consistency pass** — no single fix, but a worthwhile batch: fix the `0x71` suppression bug, switch auto-scroll to observe `log.last?.id` instead of `count`, move Share/Clear to the nav bar and reverse BLE Log's sort order, unify the three tools' clear-confirmation behavior, and fix the never-cleared `lastError` banner (one fix in `ODDevice` repairs all three surfaces).
5. **Dark Mode:** ship the `ODLogo` dark variant (the one user-visible breakage); treat `SplashView`'s fixed-light branding as a product decision rather than a bug.
6. **iPad layout:** lower priority — extend `ComposerView`'s landscape check to also branch on regular horizontal size class, and consider `NavigationSplitView` for `ContentView` as a larger follow-up, not urgent.

## What's already solid (don't disturb)

- BLE operation watchdogs, main-thread confinement of the CoreBluetooth/JS-runtime bridge, and completion-driven UI state are consistently well-built across `ODDevice`, `BLEManager`, and the Toolbox write path — no data races found anywhere in this audit, only UI/state-sequencing issues.
- Config write validation (dirty-state tracking, gated Write button, tail-preservation on export/import at the packet level) in Device Configuration is a strong pattern worth propagating to the other Engineering Tools' logging UX.
- Empty-state and filter handling in BLE Log is fully correct, including the "entries exist but none match filter" corner case.
- The app already avoids the classic iPhone-only anti-patterns (`UIScreen.main.bounds`, `UIDevice.orientation`) that usually make iPad/orientation audits much worse than this one turned out to be.
