# Audit Remediation Summary

Date: 2026-07-14
Scope: fixes for priorities 1–5 from [executive-summary.md](executive-summary.md), implemented as five independent pull requests against `main`. Each fix was implemented by a dedicated agent whose first task was to re-verify the issue still existed in current `main`; every issue was confirmed still present. Each PR was then independently reviewed (diff-level validation) before being accepted, and the five branches were merged together in a scratch clone to confirm they integrate cleanly: **no merge conflicts, integrated build succeeds, full test suite passes.**

## Pull requests

| PR | Priority | Branch | What it fixes |
|---|---|---|---|
| [#19](https://github.com/davelee98/OD-App/pull/19) | P1 (Critical) | `fix/add-device-config-state` | Add-device config read failing deterministically; silent 800×480 default persisted as if confirmed |
| [#18](https://github.com/davelee98/OD-App/pull/18) | P2 | `fix/toolbox-preset-index` | Preset index round-trip writing wrong panel/pin config to hardware; failed build writing stale config |
| [#20](https://github.com/davelee98/OD-App/pull/20) | P3 | `fix/canvas-normalized-coords` | Canvas composition corrupted by rotation/resize; stale gesture baselines; pinch/drag conflict |
| [#17](https://github.com/davelee98/OD-App/pull/17) | P4 | `fix/engineering-tools-logging` | 0x71 log suppression, dead auto-scroll at cap, buried log actions, clear-confirm inconsistency, stale error banners |
| [#16](https://github.com/davelee98/OD-App/pull/16) | P5 | `fix/dark-logo-variant` | Logo wordmark invisible in dark mode; invisible black palette swatch |

## What changed, per PR

### PR #19 — Add-device config-read flow (P1, Critical)
- The config read now auto-fires from `transport.onReady` — the point where the GATT link is actually usable — instead of from `AddDisplaySheet`'s `.onChange(of: connectedDevice)`, which fired while the link was still `.connecting` and was rejected by the JS layer with "Not connected" on every single add.
- New published `ODDevice.ConfigReadState` (`unread / reading / loaded / failed`) drives four distinct UI states in the Add/Edit sheet: reading (spinner), confirmed from hardware, stale-cached-while-refreshing, and failed-with-Retry. Callers that request a read while one is in flight now join it instead of receiving a spurious rejection.
- Save is disabled for a new display until a real config has been read; `save()` persists exclusively through `entity.apply(config:)` and can no longer fabricate the 800×480 / color-scheme-0 default.
- New `SavedDisplayEntity.resolutionConfirmed` provenance flag (defaults `false` for lightweight SwiftData migration); only `apply(config:)` sets it. Not yet surfaced in the home-list row — trivial follow-up if a visual "unconfirmed" badge is wanted.
- The config-read watchdog is re-armed on every progress event (matching the upload watchdog), and a mid-read disconnect drains all waiters with a definitive failure instead of hanging.
- `ComposerView.syncFromDevice()` now applies an already-loaded config to the registry entity, closing the config-loaded-before-view-appeared repair gap.
- Verified: build + tests pass; the runtime BLE race itself requires hardware to exercise end-to-end (verified by inspection + unit tests).

### PR #18 — Toolbox preset index (P2)
- `idFromIndex` now resolves stored `simple_config_*_index` values by each preset's explicit catalog `index` property — a faithful Swift mirror of the JS engine's `presetIndex` (explicit index, else 1-based list position) — instead of raw list position. Previously `ep75-800x480` (stored index 14) read back as `ep42-400x300`, and re-writing from that state sent wrong panel/pin config to real hardware.
- A failed Simple-mode build now aborts the Configure flow with a user-visible alert instead of silently writing the previous configuration with a success message.
- The connect-then-write wedge is fixed: `abortDeferredWrite` resets `isConfiguring`/`writeAfterConnecting` from both the disconnect and `.failed` paths, so the Configure button can't be disabled forever with a stale write armed.
- Three new regression tests, including one that goes end-to-end through the real JS engine. Known data issue left flagged (not fixed, per Resources policy): three displays share `index: 33` in `simple-config-presets.json`; read-back is deterministic first-match-wins until that's fixed upstream.

### PR #20 — Canvas normalized coordinates (P3)
- Strokes, text/QR positions and sizes, stroke width, and photo pan are now stored **normalized (0–1) relative to the canvas box** — box-independent by construction, so rotation, iPad window resize, and late-config aspect changes preserve the composition on screen and in the bitmap sent to the panel. New `Models/CanvasCoordinates.swift` (`CanvasSpace`/`PanelSpace`) does all conversion at the gesture/display/hit-test/render boundaries.
- `renderComposite` maps normalized → panel pixels directly; the math was verified algebraically identical to the old `point × k` path, so an untouched composition renders the same bytes.
- Gesture baselines are captured at gesture start rather than persisted across view recreation (the rotation-snap bug); the `transformResetToken` plumbing is gone.
- Pinch is now photo-zoom only (element resize is the tool-panel slider, per the intended interaction model); a `pinchActive` flag gates the drag/draw layer so a pinch can't also drag an element, drift the pan, double-push undo, or commit a stray stroke.
- 7 new coordinate tests (round-trip identity, box independence, zero-box safety, render equivalence vs the legacy math). Full suite passes.

### PR #17 — Engineering Tools logging (P4)
- The image-chunk (`0x71`) log suppression now applies only during an active upload (`uploadPhase == .sending`), so Tester sends of the Image Data preset, their ACKs, and raw `0x__71` packets stay visible; a one-line notice marks when chunks are being hidden.
- Tester auto-scroll observes `log.last?.id` instead of `log.count`, so it keeps following after the 500-entry cap pins the count.
- BLE Log renders newest-first with Share/Clear moved to the navigation bar; a shared confirm-before-clear modifier is used by both the Tester and BLE Log so their semantics can't drift.
- `lastError` is cleared on a successful send, healing the permanently-stale error banners on both surfaces.
- Bonus: on-screen timestamps now show `HH:mm:ss.SSS` (matching the export), and a `trimmedCount` on `BLEManager` surfaces "showing the most recent N of M" both on screen and in shared exports.

### PR #16 — Dark-mode logo (P5)
- Added `icon-dark.svg` (black lettering/outline recolored to light ink `#E8EBEE`, blue arcs untouched) registered as the imageset's dark-luminosity appearance — the home-screen wordmark no longer vanishes in dark mode.
- SplashView's logo is pinned to the light variant (its paper background is deliberately fixed-light branding, and the dark variant would have been invisible on it).
- The unselected palette swatch border in the Composer is now `Color.primary.opacity(0.3)` instead of `systemGray4`, making the black ink swatch visible in dark mode.

## Merge guidance
- All five branches merge cleanly onto current `main` in any order (verified in a scratch clone: no conflicts, integrated build succeeds, full test suite passes on simulator).
- **One caveat to decide at merge time:** PR #20 includes `project.pbxproj` changes (required — it adds two new source files). The repo's committed `.gitattributes` applies a `strip-team` clean filter to `*.pbxproj`, so the commit also removes the two `DEVELOPMENT_TEAM = GUYFAK8DC6` lines that landed via the `bundle-id-update` PR (which was committed from an environment without the filter configured). This is consistent with the repo's own stated policy, but it does revert a recent deliberate change — either accept it (Xcode re-resolves the team locally with automatic signing) or re-add the team lines from an environment without the filter.

## Not addressed in this batch
Priority 6 (iPad layout adaptations) was explicitly out of scope, as were the remaining Medium/Low audit findings in each area (listed in the per-area audit documents). Notable deferred items: Composer landscape layout on iPad regular-width, `NavigationSplitView` for the home list, the Tester's follow/pause scroll pill and opcode length validation, BLE Log's lazy share-export, SplashView dark styling (product decision), and surfacing the new `resolutionConfirmed` flag in the home-list row.
