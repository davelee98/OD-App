# Follow-up Audit — Fix Verification & New Findings

Date: 2026-07-14
Scope: verification that PRs #16–#20 resolve their original audit findings, plus a hunt for issues the fixes introduced. All code evidence was read from the **integrated state** (a scratch clone with all five branches merged onto `main`; it builds and the full test suite passes). File:line references are to that integrated tree, which matches what `main` will look like after all five merges. Original findings docs: the per-area files in this directory; deferred items listed in `remediation-summary.md` are not re-reported here.

## Verification results

### PR #19 — `fix/add-device-config-state` (vs `add-device-race-condition.md`)

| Original finding | Verdict | Evidence |
|---|---|---|
| [CRITICAL] Add-flow `readConfig()` fires before GATT ready, deterministically fails | **RESOLVED** | Auto-read moved into `transport.onReady`, after `setConnected(true)` (`BLE/ODDevice.swift:171-182`); the premature view-side trigger is gone (`ContentView.swift:212-217`, comment documents why). JS-side `handleConfigReadNotification` dispatches on the command byte, so the back-to-back `readFirmware()` + `readConfig()` at onReady can't swallow each other's responses (`Resources/ble-common.js:1647-1660`). |
| [HIGH] Save persists 800×480/B-W guess with no provenance; upsert can regress good data | **RESOLVED** | Save disabled for a new display until `device.config` is real (`ContentView.swift:266-270`); `save()` persists exclusively through `entity.apply(config:)` in both upsert branches (`ContentView.swift:323-340`) — the width/height/scheme fallback expressions are gone. `SavedDisplayEntity.resolutionConfirmed` added, set only by `apply(config:)` (`Models/DisplayDevice.swift:55, 101-109`); default value `false` keeps the SwiftData migration lightweight (verified: plain stored property with default, no schema versioning needed). Tests pin both behaviors (`Tests/ToolboxConfigTests.swift:243-269`). |
| [HIGH] Sheet stuck at "Reading configuration…" with no error and no retry | **RESOLVED** (one residual gap, see New finding N5) | `ODDevice.ConfigReadState` (`unread/reading/loaded/failed`) published at `BLE/ODDevice.swift:19, 25`; `configStatus(for:)` renders all four designed states — confirmed, confirmed+refreshing spinner, cached+failed+Retry, fetching (`ContentView.swift:272-310`). Retry wired to `readConfig()` (`:293`). Sheet re-render on device state change works because `BLEManager` forwards the child's `objectWillChange` (`BLE/BLEManager.swift:293-297`). |
| [MEDIUM] Entity re-sync accidental/incomplete | **RESOLVED** | `syncFromDevice()` now applies an already-loaded config to the entity (`Views/ComposerView.swift:880-891`), closing the config-loaded-before-appear gap; `.onChange(of: device?.config)` still applies on change (`:199-204`); the edit-sheet save applies whenever a config is in hand (`ContentView.swift:317`). Toolbox reads still don't touch the registry directly, but the connect-time auto-read plus the Composer paths close the practical repair gap. |
| [MEDIUM] Config-read watchdog fixed 10s, never re-armed | **RESOLVED** (one residual inconsistency, see N4) | Watchdog re-armed on every `configProgress` event, gated on `.reading` (`BLE/ODDevice.swift:736-740`); timeout now fires the shared `configReadFinish`, flipping state and draining all waiters (`:402-411`). Joining an in-flight read works: a second `readConfig` appends its completion instead of being rejected (`:328-334`), and `finish` drains the whole waiter list exactly once (`:340-353`). Mid-read disconnect drains waiters definitively (`:160-166`). |
| [LOW] `didDisconnect` never clears config; reconnects never refresh | **RESOLVED** | The cached config is kept for instant display and a refresh auto-fires on every reconnect from `onReady` (`BLE/ODDevice.swift:177-181`); the Add/Edit sheet shows the cached value with a refresh spinner while `.reading` (`ContentView.swift:296-302`). |
| [LOW] Mid-add disconnect strands the sheet on "Starting Bluetooth…" | **NOT RESOLVED** (not claimed by the PR) | `AddDisplaySheet.onAppear`/`onChange(of: bluetoothState)` logic unchanged (`ContentView.swift:200-211`); the `deactivate()`-after-disconnect path in `BLEManager` (`BLE/BLEManager.swift:342-347`) still flips `bluetoothState` with no re-activation path in the open sheet. |

No retain cycles in the new completion plumbing: `configReadFinish` captures `self` weakly (`BLE/ODDevice.swift:340-341`), and `configReadCompletions` is always drained by `finish`, which is guaranteed to run via the watchdog or the disconnect drain.

### PR #18 — `fix/toolbox-preset-index` (vs `device-configuration.md` findings 1–3)

| Original finding | Verdict | Evidence |
|---|---|---|
| [HIGH] `idFromIndex` maps by list position while the engine writes catalog `index` | **RESOLVED** | `idFromIndex` delegates to `id(forPresetIndex:)` (`Views/ToolboxView.swift:801-804`); `ToolboxIndexedPreset` + `presetIndex(for:)` / `id(forPresetIndex:)` (`Models/ToolboxData.swift:96-121`) are a faithful mirror of JS `presetIndex` (`Resources/toolbox-config-engine.js:294-299`, written by `build_simple` at `:340-342`): explicit `index` wins (including `0`), else 1-based position, else 0 for a foreign item — verified case-by-case against the JS, including the null/empty-string handling. Duplicate-index resolution is deterministic first-match in document order (known-deferred dup `index: 33` unchanged). Regression tests are non-tautological: they pin the divergent `ep75-800x480`↔`ep42-400x300` case in both directions, round-trip the whole catalog, and go end-to-end through the real JS engine (`Tests/ToolboxConfigTests.swift:29-81`). |
| [HIGH] Failed Simple build still writes previous config with success message | **RESOLVED** | `buildSimpleConfiguration()` returns `Bool` and leaves `configuration` untouched on a throw (`Views/ToolboxView.swift:664-683`); the Configure action guards on it and aborts (`:461-465`); a user-visible "Configuration not written" alert is bound to `configureErrorMessage` (`:81-87`). The old second build call before the deferred-connect sheet no longer exists (single caller). |
| [MEDIUM] Connect-then-write wedge on failed connection | **RESOLVED** | `abortDeferredWrite` (`Views/ToolboxView.swift:686-694`) resets `writeAfterConnecting`/`rebootAfterWrite`/`isConfiguring`/`configureProgress`, called from both the `connectedDevice → nil` path (`:165-176`, covers `didFailToConnect` and `didDisconnect`, `BLE/BLEManager.swift:314-348`) and the `.failed`-without-disconnect path (`:186-189`). Pre-`didConnect` hangs are covered by the transport's per-stage discovery watchdogs → `.failed`. A legitimate armed write is not spuriously aborted (no transient `connectedDevice` nil during a normal connect). |

The `body`/`formBody` split moved only the reboot alert + dirty dialog and added the new alert; all other modifiers (`onAppear`, the nine `onChange`s, sheets, importer/exporter) verified still attached to the Form subtree.

### PR #20 — `fix/canvas-normalized-coords` (vs `canvas-composer.md` + coordinate findings in `ipad-orientation-support.md`)

| Original finding | Verdict | Evidence |
|---|---|---|
| [HIGH] Rotation resets gesture baselines but not the transform — photo snaps | **RESOLVED** | Baselines captured at gesture start, not persisted: `pinchBaseScale` on the first pinch tick (`Views/DisplayCanvasView.swift:373-384`), drag baselines on the first `onChanged` (`:420-428`). `transformResetToken` fully removed (zero occurrences repo-wide). Rotation recreating the view (the `portraitLayout`/`landscapeLayout` structural branch survives at `Views/ComposerView.swift:153-161`) is now harmless by construction. |
| [HIGH] Pinch and drag run simultaneously and fight | **RESOLVED** (one edge regression, see N2) | Pinch is photo-zoom only — the selected-element branch of the old zoom gesture is gone (`Views/DisplayCanvasView.swift:367-384`); `pinchActive` gates the draw layer (`:390-392`, `:401-406`) and the selection layer, which holds the element/pan at gesture-start values during a pinch and suppresses its tap/commit (`:430-439`, `:456-464`). Double undo entries impossible (the zoom gesture commits nothing). All four originally documented failure modes are closed for the two-fingers-down-and-up case. |
| [HIGH] Annotations/pan stored in absolute points, never remapped on box change (also the ipad-orientation HIGH) | **RESOLVED** | All geometry stored normalized: `Stroke`/`TextItem`/`QRItem` (`Views/DisplayCanvasView.swift:598-626`), pan (`Views/ComposerView.swift:61-65`). `CanvasSpace`/`PanelSpace` convert at the display/hit-test/gesture/render boundaries with zero-box guards (`Models/CanvasCoordinates.swift`). `renderComposite` maps normalized → panel pixels with no dependency on the on-screen box (`Views/ComposerView.swift:1170-1224`); I verified the math algebraically equivalent to the old `× k` path (the box always shares the panel aspect via `boxSize`/`aspectRatio`, `DisplayCanvasView.swift:78-127`), and `Tests/CanvasCoordinateTests.swift:85-117` pins round-trip identity, box-independence, zero-box safety, and legacy render equivalence. No absolute-coordinate holdouts found: clamp logic, tap slop, drag-origin math, selection chrome, duplicate-offset, and QR placement all convert through `CanvasSpace` in consistent spaces. Undo snapshots are all-normalized (`CanvasSnapshot`, applied via `applySnapshot`) — no mixed-representation states. |
| [MEDIUM] `ImageProcessor.preview` missing empty-pixel guard (crash path) | **NOT RESOLVED** (deferred, not claimed) | Guard still absent: `Models/ImageProcessor.swift` `preview()` feeds `rgbaPixels` output straight to `toFloat` while `process`/`processWithPreview` both guard `!pixels.isEmpty`. Risk is further reduced by PR #19 (entities can no longer be saved with fabricated/zero dimensions), but the crash path remains. |
| [MEDIUM] Composing against stale fallback resolution while config loads | **PARTIALLY RESOLVED** (via #19 + #20 jointly) | The auto-read makes the real config arrive promptly on connect, and a late aspect change now re-flows the normalized composition instead of scrambling it. Remaining: no "reading configuration…" indicator on the canvas, and the config-blocked send is still a manual-retry dead end (`Views/ComposerView.swift:1106-1112`). |
| [MEDIUM] QR regenerated through Core Image on the main thread per size change | **NOT RESOLVED** (surface changed) | Pinch no longer resizes QR, but the size slider (step 2, `Views/ComposerView.swift:482`) still causes a cache-miss + synchronous CI render roughly every 2pt via `odGenerateQR` (`Views/DisplayCanvasView.swift:173-186, 535-567`). Milder than the per-frame pinch case, still a slider-drag jank source on old devices. |
| [LOW] Pan unclamped / zoom unbounded | NOT RESOLVED (deferred) | `scale = max(1, …)` with no upper bound (`Views/DisplayCanvasView.swift:378`); pan unclamped (`:450-453`). |
| [LOW] Canvas vs send colorimetric gaps | NOT RESOLVED (deferred) | Unchanged. |
| [LOW] Dead code (`process`, `DevicePreset`, `CanvasMode` UI metadata, …) | NOT RESOLVED (deferred) | `Models/DevicePreset.swift` still present; `CanvasMode.title/systemImage` still present (`Views/DisplayCanvasView.swift:571-590`). |
| [LOW] Test gap: packing + transform math | **PARTIALLY RESOLVED** | Transform math now covered (`Tests/CanvasCoordinateTests.swift`); wire-format packing still untested. |
| [LOW] Corner-handle vs pinch-resize convention drift | **PARTIALLY RESOLVED** (decision made) | Pinch is now exclusively photo zoom; element resize is the tool-panel slider (documented at `Views/DisplayCanvasView.swift:200-204, 367-372`). Corner handles were *not* implemented — if the planning notes still call for them, that remains open as a product decision. |

### PR #17 — `fix/engineering-tools-logging` (vs `engineering-tools.md`)

| Original finding | Verdict | Evidence |
|---|---|---|
| [HIGH] 0x71 suppression hides Tester sends/ACKs | **RESOLVED** | Suppression now requires `uploadPhase == .sending` (`BLE/ODDevice.swift:773-774`); a one-line "chunks hidden" notice is emitted once per upload, after the early-failure guard (`:582-595`). Non-0x71 Tester sends during an upload still log; `uploadPhase` cannot stick at `.sending` (completion, early-complete, stall watchdog, disconnect, and `failUpload` all exit it). |
| [HIGH] Auto-scroll dies at the 500-entry cap | **RESOLVED** | Observes `ble.log.last?.id` (`Views/BLETesterView.swift:134`); `LogEntry.id` is a per-instance UUID. Clear is safe: the handler no-ops when `last` is nil (`:135`). |
| [HIGH] BLE Log oldest-first, actions buried | **RESOLVED** | Newest-first via `ForEach(Array(filteredEntries.reversed()))` (`Views/AdvancedView.swift:138`; stable UUID identity, filter-then-reverse correct, both empty states intact); Share/Clear are toolbar items (`:155-169`). The O(n) reverse copy per body evaluation is negligible next to the pre-existing (deferred) eager `formattedLog` rebuild, which this PR did not worsen. |
| [MEDIUM] Unconfirmed one-tap clear of the shared log | **RESOLVED** | Shared `clearSharedLogConfirmation` modifier with destructive role, used by both screens (`Views/BLETesterView.swift:268-279`, `Views/AdvancedView.swift:173`). Wording nit → N9. |
| [MEDIUM] `lastError` never cleared | **RESOLVED** | Cleared on `sendRaw` success (`BLE/ODDevice.swift:226-229`). Deliberately narrow (other successful ops don't clear); no conflict with PR #19 — the Add sheet reports config-read failures via `configReadState`, not `lastError`. Latent edge → N10. |
| [MEDIUM] Invisible 500-entry trim | **RESOLVED** | `trimmedCount` on `BLEManager` (`BLE/BLEManager.swift:109-127`), reset in `clearLog()` (`:104-107`); surfaced at the oldest end of both screens (`Views/AdvancedView.swift:141-147`, `Views/BLETesterView.swift:116-121`) and in the export header (`AdvancedView.swift:191-193`). |
| Bonus: on-screen `HH:mm:ss.SSS` timestamps | **RESOLVED** | Static hoisted formatter used by `LogEntryRow` (`Views/BLETesterView.swift:203-207, 223`). Locale nit → N8. |

### PR #16 — `fix/dark-logo-variant` (vs `dark-mode-readiness.md`)

| Original finding | Verdict | Evidence |
|---|---|---|
| [HIGH] ODLogo has no dark variant | **RESOLVED** | `Assets.xcassets/ODLogo.imageset/Contents.json` valid: dark entry with `luminosity: dark`, both files present, shared `preserves-vector-representation`/`rendering-intent`. `icon-dark.svg` differs from `icon.svg` by exactly two lines (text fill and outline stroke `#000` → `#E8EBEE`); exhaustive color inventory shows no leftover black fills/strokes and no paths inheriting SVG default black; identical dimensions/viewBox. |
| SplashView logo pinned light | **RESOLVED** | `.environment(\.colorScheme, .light)` scoped to the logo `Image` (`Views/SplashView.swift:17-20`); the `ColorScheme` domain-enum shadowing is a non-issue here (key-path resolution; the domain enum has no `.light` case, so mis-resolution would fail to compile). |
| [MEDIUM] Black palette swatch invisible in dark mode | **RESOLVED** | Unselected stroke is `Color.primary.opacity(0.3)` (`Views/ComposerView.swift:754`) — and it **survived the PR #20 merge** (verified against branch cut points and merge order). |

## New findings

Only issues introduced by the fixes or newly noticed during this pass; known-deferred items from `remediation-summary.md` are excluded.

**N1. [MEDIUM] PR #19's auto-read races the Toolbox connect-then-write flow — a successful Configure ends showing the OLD configuration plus a false dirty badge**
- Location: `BLE/ODDevice.swift:177-181` (auto-read at onReady) × `Views/ToolboxView.swift:152-157` (`.onChange(of: device?.config)` unconditionally replaces `configuration` and `lastPersistedConfiguration`), `:181-196` (deferred write fires on `.connected`), `:715-719` (`written` captured at write start; `lastPersistedConfiguration = written` on success).
- Issue: In the connect-then-write flow, the auto-read of the device's *current* (pre-write) config starts at `onReady`, and the deferred write of the user's newly built config starts an instant later. The read is small and typically completes mid-write: `device.config` flips to the OLD config → the `onChange` replaces `configuration` with it and reverts the Simple pickers on screen. When the write then succeeds, `lastPersistedConfiguration` becomes the NEW config while `configuration` holds the OLD one — so after "Configuration written successfully" + reboot, the screen shows the pre-write hardware config as current *and* an "Edits not yet written" dirty badge. The bytes written are correct (`written` is captured before the clobber); only the UI/state ends wrong. Secondary risk: the chunked read and chunked write are now concurrently in flight on the same characteristic — JS-side dispatch is safe (command-byte routed), firmware-side interleaving is untested.
- Impact: Deterministic-ish UX corruption of the flow PR #18 just repaired; users will believe their configure was lost and re-run it.
- Recommendation: After a successful `writeConfig`, set `device.config` to the written model (or trigger a fresh read); and/or make ToolboxView's config `onChange` skip while `isConfiguring`/`hasUnsavedChanges` (routing through the existing `DirtyAction` confirmation). Deferring the auto-read until no write is in flight would also close the concurrent read/write window.

**N2. [MEDIUM] The pinch gate isn't sticky: lifting one finger mid-pinch resumes the underlying drag — the element jumps and the move bypasses the undo stack**
- Location: `Views/DisplayCanvasView.swift:430-439` (freeze only while `pinchActive`), `:441-454` (move/pan resume), `:456-464` (`pinchDuringDrag` suppresses only the *commit*, not the mutation); draw-mode analog at `:390-392, 401-406`.
- Issue: `MagnificationGesture` ends when the second finger lifts, clearing `pinchActive`, while the surviving finger's `DragGesture` keeps running. The next `onChanged` falls through the (now false) `pinchActive` check and moves the element to `origin + v.translation` — where `translation` includes everything accumulated during the pinch — so the element (or the photo pan) jumps. Because `pinchDuringDrag` is still true, `onEnded` swallows the undo commit, leaving a state mutation with no undo entry. In draw mode, the surviving finger starts and *commits* a fresh stroke post-pinch.
- Impact: Pinch-then-continue-with-one-finger (a common gesture) moves elements unpredictably and corrupts undo consistency — the exact interaction class PR #20 set out to fix.
- Recommendation: Make the freeze sticky for the drag's lifetime: gate the move/pan branch on `pinchActive || pinchDuringDrag` (and in `drawGesture`, decline to start a new stroke once a pinch occurred during the touch sequence).

**N3. [LOW] A stale `readConfig` JS completion cancels the *successor* read's watchdog**
- Location: `BLE/ODDevice.swift:356-359` — the `call("readConfig")` completion cancels `configReadWatchdog` unconditionally, before any `didComplete` check.
- Issue: If read #1's JS promise settles *after* read #2 has started (e.g. the queued `0x0040` write fails late after a watchdog timeout already finished read #1), completion #1 cancels read #2's watchdog. Read #2 is then unguarded until its first `configProgress` event; if it stalls before any progress, `configReadState` sticks at `.reading` forever — perpetual spinner, Save disabled, waiters never drained until disconnect. Narrow window (the JS engine drops the old `onComplete` on a new read, and disconnect rejection is handled), but the shared-slot hazard is real.
- Recommendation: Move the `configReadWatchdog?.cancel()` inside `finish` only (it's already there), or guard the completion's cancel with its own `didComplete`/generation token.

**N4. [LOW] A late read success after a watchdog timeout populates `config` while `configReadState` stays `.failed`**
- Location: `BLE/ODDevice.swift:361-383` — `self.config = model`, `configReadProgress = 1`, `reparseAdvertisement()` run before `finish(...)`, and are not gated by `didComplete`.
- Issue: After a timeout has finished the read as `.failed`, a late-arriving JS result still mutates `config`/progress; `finish` is then a no-op, so the published state says "failed" while a fresh config sits loaded. The Add sheet masks it (the `config != nil` branch wins), but any consumer branching on `configReadState` (current or future) sees contradictory state, and `lastError` keeps a stale timeout message.
- Recommendation: Gate the state mutations on `!didComplete` (fold them into `finish`'s success arm), or accept the late value by also flipping the state to `.loaded`.

**N5. [LOW] Add sheet has no UI state for a connection-stage failure — perpetual "Reading configuration…" spinner**
- Location: `ContentView.swift:303-309` (fallback branch), `BLE/ODDevice.swift:194-198` (transport `onError` → `connectionState = .failed` without clearing `connectedDevice`), `BLE/BLEManager.swift:314-348` (`connectedDevice` cleared only on `didFailToConnect`/`didDisconnect`).
- Issue: If GATT setup fails or stalls after `didConnect` (transport watchdogs flip the device to `.failed` without an OS-level disconnect), no read ever starts, `configReadState` stays `.unread`, and the new-display sheet shows the fetching spinner indefinitely with Save disabled and no Retry (the failed branch keys on the *read* state, not the connection state).
- Recommendation: In `configStatus`/`saveDisabled`, also branch on `device.connectionState == .failed` (message + retry-connect affordance), mirroring what the Composer's connection gate already does.

**N6. [LOW] Element size sliders clamp normalized sizes to a view-point range that shifts with the canvas box**
- Location: `Views/ComposerView.swift:561-573` (`textSizeBinding`), `:605-617` (`qrSizeBinding`), slider ranges at `:449` (8…200) and `:482` (40…300); readouts at `:452, 485`.
- Issue: Stored sizes are normalized, but the sliders present/edit them as points relative to the *current* box. Rotating the phone (portrait box ≈360pt wide → landscape ≈530pt) or moving to iPad rescales the point value: an element that was in range can land outside the slider bounds, the "pt" readout changes for an unchanged composition, and touching the slider snaps the element to the clamped bound. (This is the risk the PR itself flagged; confirmed real.)
- Recommendation: Normalize the slider ranges too (derive min/max from the box, or slide the normalized value directly with a fixed 0–1-style range), and only write back on user interaction deltas rather than absolute clamped values.

**N7. [LOW] False "Connection ended — configuration not written" after a fully successful write**
- Location: `Views/ToolboxView.swift:165-176` vs `:716-731`.
- Issue: In the reboot-when-done flow, `isConfiguring` stays true from write success until the +1s reboot block runs. A link drop inside that window (plausible — the device may reset itself after a config write) triggers `abortDeferredWrite("Connection ended — configuration not written")`, directly contradicting the "Configuration written successfully" line just logged.
- Recommendation: Track write-completed state and use neutral wording ("Connection ended") when only `isConfiguring` is set post-write.

**N8. [LOW] Log timestamp `DateFormatter`s lack `en_US_POSIX` locale**
- Location: `Views/BLETesterView.swift:203-207` (new on-screen formatter), `Views/AdvancedView.swift:178-179` (export formatter).
- Issue: A fixed `dateFormat` without `en_US_POSIX` can be rewritten by the user's 12/24-hour Settings override (documented Apple behavior), mangling the `HH:mm:ss.SSS` rendering the fix exists to provide, and letting on-screen and export disagree.
- Recommendation: `formatter.locale = Locale(identifier: "en_US_POSIX")` on both.

**N9. [LOW] Shared clear-confirmation message reads wrong on the BLE Log screen**
- Location: `Views/BLETesterView.swift:276`, presented from `Views/AdvancedView.swift:173`.
- Issue: "…shown here and on the BLE Log screen" is Tester-viewpoint text; on the BLE Log screen it names the screen the user is already on as somewhere else.
- Recommendation: Neutral wording or a per-caller message parameter.

**N10. [LOW] `writeNFC`'s pipelined sends can self-wipe their own failure via the new `lastError = nil`**
- Location: `BLE/ODDevice.swift:544-556` vs the success arm at `:226-229`.
- Issue: A failed middle chunk sets `lastError`, then a later successful chunk/end clears it — erasing the only banner-visible evidence of the partial failure. Latent: `writeNFC` currently has no UI caller.
- Recommendation: Track failures across the sequence, or clear `lastError` only for labeled (Tester-originated) sends.

**N11. [LOW] Preview-sheet image border still uses `systemGray4`**
- Location: `Views/ComposerView.swift:784`.
- Issue: Same low-contrast-in-dark-mode construction the swatch fix addressed, not covered by the original audit or PR #16. Minimal impact (the dithered preview is predominantly light).
- Recommendation: `.border(Color.primary.opacity(0.3))` for consistency.

**N12. [INFO] BLE Log trim notice counts the full log regardless of the active filter**
- Location: `Views/AdvancedView.swift:141-147`.
- Issue: Under a filter the "showing the most recent 500 of N" numbers don't match the visible rows, and the notice is hidden entirely when the filter matches nothing.
- Recommendation: Filter-agnostic wording ("Log trimmed to the most recent 500 of N entries") hoisted out of the non-empty branch.

**N13. [INFO] Duplicate error rows on a mid-write disconnect in the Toolbox**
- Location: `Views/ToolboxView.swift:174` + `:717`.
- Issue: Both the abort handler and the write completion log the failure — accurate but noisy; state handling is idempotent. Same family as the audit's existing "logged twice" LOW.

**N14. [INFO] Zero-box element placement would normalize sizes to 0**
- Location: `Views/ComposerView.swift:1039-1045` (`placeQRAtCenter`), `:1026` (`placeTextAtPoint`).
- Issue: If `canvasSize` were still `.zero` (pre-layout), `toNorm(length:)`'s zero-box guard returns 0 and the placed element gets size 0 (invisible, persisted). Practically unreachable today (both paths require the laid-out canvas or its tool panel), noted for the coordinate model's edge-case ledger.

## Cross-PR interaction check

- **`ODDevice.swift` (P1 + P4):** compose correctly. P4's `lastError = nil` on `sendRaw` success cannot mask P1's config-read failure reporting — the Add sheet and its Retry run off `configReadState` (`ContentView.swift:274, 282-295`), which only `readConfig`'s `finish` mutates. Conversely, P1's failures still set `lastError` for the Tester/BLE Log banners, where P4's healing semantics are the intended behavior. The auto-read does add per-connect log traffic (config chunks are `0x40`, unaffected by the `0x71` gate) — noise only.
- **`ComposerView.swift` (P1 + P3 + P5):** compose correctly, and P1×P3 is genuinely synergistic — a late-arriving config that changes the panel aspect now re-flows the normalized composition instead of scrambling it (the compounding failure called out in three original audits). `syncFromDevice`'s new `entity.apply` doesn't touch any canvas geometry; pan/scale reset happens only on photo load/reset, unrelated to config arrival. P5's swatch fix survived P3's larger merge into the same file (verified against both branches and the merge order).
- **P1 × P2 (`ToolboxView` flows):** the one real composition problem — finding N1 above (auto-read vs deferred connect-then-write). Related aggravation: the auto-read on *every* reconnect makes the known-deferred "background read clobbers unsaved Toolbox edits" LOW (original `device-configuration.md` finding) fire deterministically whenever the link drops and re-establishes while a user has unsaved Advanced edits — worth bundling into the N1 fix (dirty-guard the config `onChange`).
- **`project.pbxproj`:** as documented in `remediation-summary.md`, the integrated tree carries no `DEVELOPMENT_TEAM` lines (P3's pbxproj edit passed through the repo's `strip-team` clean filter). Confirmed present in the integrated clone; decide at merge time per the remediation guidance.
- **Build/tests:** the integrated clone builds and the full suite (including the new coordinate and preset-index tests) passes, per the integration setup verified before this audit.

## Conclusion

All five PRs substantively fix what they claim. PR #19 eliminates the deterministic add-device failure and every fabricated-default persistence path; PR #18's Swift index mapping is an exact JS mirror with strong tests; PR #20's normalized coordinate model is correctly implemented end-to-end (storage, gestures, hit-testing, render) with verified render equivalence; PR #17 and #16 fully deliver their smaller scopes. Of the 22 originally listed findings across the five target docs, 15 are fully resolved, 4 partially (all with the residuals identified above or known-deferred), and 3 remain open by design (unclaimed LOW/MEDIUM items).

Two new MEDIUMs deserve fixes before or shortly after merge: **N1** (the auto-read racing the Toolbox connect-then-write flow — a P1×P2 emergent interaction that undermines the just-repaired Configure UX) and **N2** (the non-sticky pinch gate, which reintroduces a narrow variant of the gesture conflict PR #20 fixed, with an undo-integrity hole). Both are small, localized changes. The remaining new findings are LOW/INFO polish that can ride any later batch.
