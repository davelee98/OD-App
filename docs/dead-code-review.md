# Dead / Stale Code Review

**Date:** 2026-07-18
**Reviewed at:** branch `feat/merge-adjust-into-photo` (post Rust-dithering migration + ADJUST→PHOTO merge)
**Method:** `rg` sweeps across all 37 Swift files including `Tests/`; automated single-reference sweeps for every `private func`, `private var/let`, all-access `func`, and type-level computed `var`; plus targeted manual confirmation of each candidate. Vendored `Resources/*.js`, `config.yaml`, and `EpaperDithering.xcframework` were excluded from "dead" consideration (intentional artifacts).

> **Status:** All **High-confidence** items (§1–§5) were actioned in the `chore/dead-code-cleanup` PR — dead `CanvasMode` metadata/conformances, `ImageProcessor.process`, the `pack1bpp` `invert` param, `ODConfigModel.deviceLabel`, and the stale `architecture.md`/`README.md` dithering docs are all resolved. The **Medium-confidence** items (§6–§11) remain open pending an intent check (especially the NFC cluster, which is an unwired device capability rather than obvious cruft).

**Headline:** The two recent refactors are clean at the code level. The Swift-dithering removal left no orphaned functions in `ImageProcessor` beyond the items below; the ADJUST→PHOTO move left **zero** orphaned `@State`/bindings (every `ImageAdjustments` field and adjustment helper is still driven by the sliders now living in `photoPanel`). The real residue is stale **docs** plus a handful of pre-existing unreferenced members. **No finding is a bug risk — all pure cleanup.**

All paths are relative to the repo root (`OD App/`).

---

## High confidence

### 1. `CanvasMode.title` + `.systemImage` + `CaseIterable`/`Identifiable` conformances — dead
`Views/DisplayCanvasView.swift:592-611`. `CanvasMode` is consumed only via `switch mode` / `mode == .move` equality (lines 205, 457, 471, 503…). Grep across app+Tests: **0** references to `CanvasMode.`, `.allCases`, `mode.title`, or `mode.systemImage`. UI metadata now lives on `ComposerTool`.
**Action:** trim to `enum CanvasMode: String { case move, draw, text, qr }`.

### 2. `ImageProcessor.process(image:...)` — zero callers
`Models/ImageProcessor.swift:103-128`. Replaced by `processWithPreview` (used in `sendPhoto`) and `preview` (used in `generatePreview`). No `ImageProcessor.process(` call sites across app+Tests; only textual hit is a comment. Duplicates the pipeline of the other two entry points.
**Action:** delete (or refactor `preview`/`processWithPreview` onto a shared core).

### 3. `pack1bpp`'s `invert` parameter — dead branch
`Models/ImageProcessor.swift:402-409`. Both call sites (lines 390, 397) pass `invert: false`; the `invert ? … : …` branch is unreachable.
**Action:** drop the parameter and the branch.

### 4. `ODConfigModel.deviceLabel` — vestigial stub
`Models/ConfigModel.swift:99-102`. Self-documented ("The current website schema has no device-label field"); getter returns `""`, setter is a no-op. Grep: 0 references.
**Action:** delete.

### 5. Stale documentation — old Swift-dithering path still described
- `docs/architecture.md:155` (flow step 5) and `:220` (module inventory) describe `ImageProcessor` as doing **"error-diffusion dithering (8 kernels) → palette quantization"** in Swift. That code was deleted in commit `1da5667`; dithering now runs in the Rust core via `Models/RustDither.swift` + `Frameworks/EpaperDithering.xcframework`. Neither `RustDither` nor the xcframework appears anywhere in `architecture.md` — a post-migration documentation gap.
- `docs/architecture.md:220` lists `ImageProcessor.swift` as `543` lines (actually 511) and ComposerView `:204` as `1,387` (actually 1,442).
- `README.md:69` labels `ImageProcessor.swift` "Dithering engine, palette quantization…" — the engine is now Rust; ImageProcessor only pre-processes, packs, and delegates.
**Action:** update prose to reflect the Rust FFI path; add `RustDither.swift`/xcframework to the inventory; refresh line counts.

---

## Medium confidence

### 6. NFC command cluster — no callers, no UI (possibly intentional device API)
`BLE/ODDevice.swift:562 writeNFC(type:payload:)`, its four builders `ODCommands.nfcWriteSingle/Start/Chunk/End` (`Protocol/ODCommands.swift:14-37`), and `Data.chunked(size:)` (`ODCommands.swift:43`, used only by `writeNFC`). `writeNFC` has 0 callers across app+Tests, so the whole chain is unreachable. (The `OD.Cmd.nfc` opcode `0x0082` itself *is* still used — it appears in the BLETester preset-command list — so only the higher-level write helpers are dead.)
**Action:** confirm intent; if no NFC feature is planned, delete `writeNFC` + the four builders + `chunked`.

### 7. Unused `ODConfigModel` accessors
`Models/ConfigModel.swift`: `refreshMode` (31), `deepSleepEnabled` (43), `displayDiagonalInches` (56), `batteryMSDByteIndex` (80), `pskHex` (84). Each has 0 references. Sibling accessors (`displayWidth`/`colorScheme`/`transmissionModes`) *are* used, so the type isn't dead — just these members.
**Action:** delete unless kept as deliberate model API.

### 8. `ColorScheme.bitsPerPixel`
`BLE/ODConstants.swift:126-136`. Unused enum computed property (0 refs).

### 9. `AdvertisementData.formattedDescription`
`Models/AdvertisementData.swift:219`. Multi-line debug/inspection string with 0 references; likely orphaned when an engineering view stopped displaying it.

### 10. `ToolboxPacketDefinition.fixedPayloadLength`
`Models/ToolboxData.swift:213`. Unused computed helper (0 refs).

### 11. `docs/code-review.md` is stale
Dated 2026-07-04. Its headline bug "adjustment sliders do nothing" is already fixed (`ComposerView.swift:179` `.onChange(of: adjustments) { … refreshCanvasImage() }`), and it references a symbol `exposureEV` that no longer exists. It's an explicitly dated snapshot, so lower priority, but now describes a resolved state.

---

## Checked — nothing found
- No unused `private func` (whole-repo sweep) and **no orphaned `@State`/bindings** from the ADJUST→PHOTO move — the refactor was tidy.
- No `TODO`/`FIXME`/`XXX`/`HACK` and no commented-out code blocks.
- No unused bundled resources or test fixtures (`simple-config-presets.json` and all `.js`/`.yaml` referenced; `ble-common.js` pinned by test + build phase).
- `DevicePreset` / its `.all` catalog (flagged in the old `docs/audit/canvas-composer.md`) has **already been removed**.

---

## Summary
- **~5 high-confidence removals** (CanvasMode metadata + conformances, `ImageProcessor.process`, `pack1bpp` invert param, `deviceLabel`) plus the high-confidence **stale `architecture.md`/`README.md` dithering docs**.
- **~6 medium-confidence** items (NFC cluster, five `ODConfigModel` accessors, `bitsPerPixel`, `formattedDescription`, `fixedPayloadLength`, stale `code-review.md`) — verify intent before deleting model/device API surface.
- **Bug risk: none.** Every finding is pure cleanup. The one behavioral caveat is the NFC cluster: deleting it removes a currently-unwired device capability, so confirm intent rather than assume cruft.
