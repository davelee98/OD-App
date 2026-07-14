# iPad & Orientation Support Audit

Audited: 2026-07-07. Scope: `ContentView.swift`, `ODApp.swift`, and all view files under `Views/` (stray `" 2"` duplicates excluded). Audit only — no source changes.

## Overview

The Xcode project sets `TARGETED_DEVICE_FAMILY = "1,2"` and `Info.plist` contains no `UISupportedInterfaceOrientations` restriction, so the app already installs and runs on iPad in every orientation today. Hygiene is good: there is **no** `UIScreen.main.bounds`, `UIDevice.current.orientation`, or `statusBarOrientation` usage anywhere — sizing flows through `GeometryReader`, `.aspectRatio`, `containerRelativeFrame`, and one `verticalSizeClass` check. However, apart from `ComposerView`'s phone-landscape branch, no view adapts to available width: every screen is a single linear iPhone layout that simply stretches. On iPad the app is functional but reads as a scaled-up iPhone app (full-width master-only lists, edge-to-edge forms, a canvas letterboxed between huge dead margins in landscape), and one genuine correctness problem exists: rotating mid-composition silently changes the composition, because canvas annotations and the photo pan are stored in absolute canvas points that are never rescaled when the canvas box changes size.

## Findings

### [HIGH] Rotation / window resize invalidates the canvas composition
- **Location:** `Views/DisplayCanvasView.swift:84-119` (box derived from `GeometryReader`, `onChange(of: box)` at :115), annotation models at :576-605 (`Stroke.points`, `TextItem.position/fontSize`, `QRItem.position/size` — all absolute canvas points); `Views/ComposerView.swift:61-62` (`pan`/`scale`), :1143-1198 (`renderComposite` maps canvas points → panel pixels via `k = width / box.width`).
- **Issue:** The canvas box is re-derived from the current geometry on every layout pass (rotation, iPad Split View / Stage Manager resize), and `canvasSize` is updated accordingly — but nothing rescales the state expressed in the *old* box's point space. Stroke points, text positions/font sizes, and QR positions/sizes stay at their absolute values; `pan` (points) and the photo's aspect-fill base scale are recomputed against the new box.
- **Impact:** Rotate an iPhone (or resize an iPad window) mid-composition and the photo crop shifts (fixed `pan` against a re-derived aspect-fill), annotations drift relative to the photo, and text/QR elements change size *relative to the panel*. Elements can land outside the new box — they stay clipped and, since position clamping only applies during drags, there is no built-in way to recover them short of undo/reset. Because `renderComposite` uses the current `canvasSize`, the image actually **sent to the display** differs from what the user originally composed. On iPad this is triggered without rotating at all, by Split View/Stage Manager resizes.
- **Recommendation:** Store annotation geometry and pan in normalized (0–1, box-relative) or panel-pixel coordinates and convert to view points at render time; alternatively, on `box` change, rescale all point-space state by `newBox.width / oldBox.width` (the aspect ratio is fixed, so one factor suffices). Either approach also makes the composite render independent of the on-screen box.

### [MEDIUM] ComposerView never uses its landscape layout on iPad — huge dead margins around the canvas
- **Location:** `Views/ComposerView.swift:53, 154-163` (branch on `verticalSizeClass == .compact`), :224-231 (`portraitLayout`), :235-250 (`landscapeLayout`).
- **Issue:** The layout branch keys exclusively on compact *vertical* size class, which only occurs on iPhone landscape (the inline comment acknowledges: "iPad stays regular → portrait"). An iPad in landscape — regular/regular — always gets the stacked portrait layout: canvas on top, action row, chip bar, and tool panel below.
- **Impact:** On a 13" iPad in landscape (~1366×1024 pt), the canvas (a wide 800×480-class panel aspect) is height-limited by the space left above the controls and floats between very large empty side margins, while the tool controls stretch to full window width below. The screen that most benefits from a side-rail layout never gets one on the device with the most room for it.
- **Recommendation:** Also branch on `horizontalSizeClass == .regular` (iPad, both orientations, and wide Stage Manager windows) into the side-by-side layout — canvas filling the leading region, controls in a trailing rail. Consider making the rail proportional or `.frame(idealWidth:)`-based rather than the current hard `.frame(width: 340)` (:247) so it scales on a 13" screen.

### [MEDIUM] Master-only navigation lists waste iPad width (ContentView, AdvancedView)
- **Location:** `ContentView.swift:17-47` (root `NavigationStack` + full-width `List`); `Views/AdvancedView.swift:11-79` (same pattern inside a sheet).
- **Issue:** The home "My Displays" screen is a `NavigationStack` with a single `insetGrouped` list; each row's label stretches `maxWidth: .infinity` (`ContentView.swift:139`). There is no `NavigationSplitView` or width-class adaptation anywhere in the app.
- **Impact:** On iPad the displays list becomes a sparse sheet of ~1000-pt-wide rows containing three short lines of text each; selecting a display then replaces the whole screen with the Composer. It works, but it is the canonical "stretched iPhone app" look and forfeits iPad's natural list-detail idiom.
- **Recommendation (design, not implemented):** On regular horizontal size class, present `NavigationSplitView` with the displays list as the sidebar and the Composer as the detail pane. `AdvancedView`'s tools list is presented in a sheet so it is naturally card-sized on iPad and is lower priority, but the same split pattern would suit it if it ever moves out of a sheet.

### [MEDIUM] ToolboxView renders as one edge-to-edge form column on iPad
- **Location:** `Views/ToolboxView.swift:68-92` (single `Form` containing everything: connection, mode picker, presets, hardware pickers, deep sleep, packet editor, encoded-bytes hex dump, import/export, schema, device actions, status log).
- **Issue:** A very long single-column `Form` with no size-class awareness. Individual rows (pickers, `LabeledContent`, toggles) stretch to the full window width; the hex dump (:369-371) and status log (:510-524) become extremely long lines on a 1024–1366 pt window. The preset `LazyVGrid` (:231) is the one element that adapts well.
- **Impact:** On iPad the form is readable but wasteful — label-left/value-right rows separated by ~800 pt of whitespace, and a scroll length identical to iPhone despite several-fold more area. No breakage, purely un-adapted.
- **Recommendation:** On regular width, either constrain the form's content width (e.g. `.frame(maxWidth: ~640)` centered), or split into two columns: configuration sections (mode/presets/hardware/packets) leading, live output (encoded bytes, validation, status log) trailing — the log in particular would be far more useful as a persistent side panel while configuring.

### [MEDIUM] BLETesterView: fixed vertical split starves the log in phone landscape, stretches on iPad
- **Location:** `Views/BLETesterView.swift:14-27` (fixed `VStack`: `commandPanel` above `logPanel`), :31-113 (command panel is ~5-7 stacked rows tall).
- **Issue:** The command panel/log split is a fixed vertical stack with no size-class or orientation branch. In iPhone landscape (~375 pt usable height) the command panel — segmented picker, command/opcode row, payload row, validation caption, send/clear row, plus optional error banners — consumes most of the height, leaving a few rows of log. On iPad, both panels stretch to full window width (text fields ~900 pt wide next to 70 pt fixed labels at :64/:75).
- **Impact:** The screen's core purpose (watching request/response traffic while sending commands) is compromised in phone landscape; on iPad it's usable but visually unbalanced.
- **Recommendation:** On compact height or regular width, place the command panel and log side by side (`HStack`), command panel at a fixed/ideal ~360 pt, log filling the rest. This is the same shape ComposerView already uses for phone landscape.

### [LOW] SplashView: unconstrained text width and fixed type sizes on iPad
- **Location:** `Views/SplashView.swift:18-33` (headline at fixed 28 pt, body at fixed 16 pt, only `.padding(.horizontal, 32)` constraining width).
- **Issue:** The logo is handled well (`containerRelativeFrame` 50% of width, capped at 320 pt, :15-16), but the tagline/description have no max width — on a 1024–1366 pt window the description runs as one or two very long centered lines — and the fixed font sizes don't scale up for the larger canvas (nor with Dynamic Type).
- **Impact:** Cosmetic: the first-impression screen looks sparse and off-balance on iPad; small text swims in whitespace.
- **Recommendation:** Wrap the text block in `.frame(maxWidth: ~480)`, and prefer semantic text styles (`.title`, `.body`) or size-class-scaled values over hardcoded 28/16 pt.

### [LOW] ContentView header logo/title fixed for iPhone proportions
- **Location:** `ContentView.swift:49-59` (`pageHeader`: `.title2` text + `ODLogoView(height: 80)`); `Views/ODLogoView.swift:3-13` (fixed-height logo).
- **Issue:** The custom header is tuned for iPhone width — an 80 pt logo pinned to the trailing edge with the title leading. On iPad the two elements sit at opposite ends of a ~1000 pt bar with empty space between.
- **Impact:** Cosmetic only.
- **Recommendation:** On regular width, either center the header content at a constrained width or fold the branding into the navigation bar; `ODLogoView`'s parameterized height is fine as-is.

### [INFO] Sheets and overlays behave correctly on iPad — no action needed
- **Location:** `ContentView.swift:36-40` (`AddDisplaySheet`, `AdvancedView` sheets); `Views/ToolboxView.swift:166-175` (packet editor / schema / connection sheets); `Views/ComposerView.swift:1279-1337` (`UploadStatusOverlay`).
- **Notes:** No sheet forces `presentationDetents` or fixed frames that would misbehave as an iPad centered card; forms inside sheets size naturally. `UploadStatusOverlay` fills whatever container it's in with material + adaptive `aspectRatio` hero image, so it scales to iPad cleanly. Similarly, no deprecated orientation APIs exist anywhere in the audited files — orientation handling is structurally sound; the problems above are adaptation quality (and the HIGH coordinate-space issue), not API misuse.

## Recommended layout adaptations

Per-screen, in priority order (recommendations only — none implemented):

1. **DisplayCanvasView / ComposerView (correctness first):** store annotation and pan state in box-independent coordinates (normalized 0–1 or panel pixels), or rescale all point-space state when the canvas box size changes, so rotation and iPad window resizing preserve the composition and the sent image.
2. **ComposerView:** extend the side-by-side layout to `horizontalSizeClass == .regular` — canvas scaled to fill the leading area, controls in a trailing rail; make the rail width proportional/ideal-width instead of the hard 340 pt so it breathes on 13" iPads.
3. **ContentView:** on regular width, adopt `NavigationSplitView` — "My Displays" as sidebar, the selected display's Composer as detail. This single change removes most of the "stretched iPhone" impression.
4. **ToolboxView:** on regular width, constrain the form to a readable column (~640 pt) or split into a two-column layout with the status log / encoded-bytes output as a persistent trailing panel.
5. **BLETesterView:** side-by-side command panel + log on compact height (phone landscape) and regular width (iPad), mirroring ComposerView's landscape shape.
6. **SplashView:** cap the text block width (~480 pt) and use semantic/Dynamic-Type-aware fonts.
7. **ContentView header:** constrain or restyle `pageHeader` on regular width so the title and logo don't span the full window.
8. **AdvancedView / sheets:** no structural change needed; they present as correctly sized cards on iPad today.
