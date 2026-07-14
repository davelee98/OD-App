# Dark Mode Readiness Audit

Date: 2026-07-07 · Scope: `Views/*.swift` (excluding stray `* 2.swift` duplicates), `ContentView.swift`, `ODApp.swift`, `Assets.xcassets`, `Info.plist`, `OD App.xcodeproj/project.pbxproj`

## Overview

The app is **unadapted-but-following-system-default**: there is no `UIUserInterfaceStyle` key in `Info.plist` or the pbxproj, and no `.preferredColorScheme(...)` call anywhere, so the app tracks the user's system appearance. The large majority of the UI is built from system components (`List`, `Form`, `NavigationStack`, `ContentUnavailableView`) and semantic styles (`.primary`, `.secondary`, `.tertiary`, `Color(.systemBackground)`, `Color(.secondarySystemBackground)`, `.regularMaterial`), which adapt correctly out of the box. The real problems are concentrated in three places: the ODLogo asset (black glyphs with no dark variant, shown on an adaptive background on the home screen), the fully fixed-light SplashView, and a few low-contrast details (black palette swatch, near-invisible log-row tints). The e-paper canvas itself is intentionally fixed white and is correct as-is.

## Findings

### [HIGH] ODLogo has no dark-appearance variant — black portions of the logo disappear on the home screen
- **Location:** `Assets.xcassets/ODLogo.imageset/Contents.json` (single universal `icon.svg`, `rendering-intent: original`); rendered at `ContentView.swift:54` via `ODLogoView` (`Views/ODLogoView.swift:7-11`)
- **Issue:** `icon.svg` contains a blue arc group (`#00bfff`), a **black** text group (`fill:#000000`, the "OpenDisplay" lettering) and a **black** outline stroke (`stroke:#000`). The imageset defines only one appearance (no `luminosity: dark` entry). The home-screen header places this logo directly on the adaptive system background, which is near-black in dark mode.
- **Impact:** In dark mode the logo's lettering and outline are invisible; users see only floating blue arcs. This is the app's primary branding on its most-visited screen.
- **Recommendation:** Add a dark variant to the imageset (`appearances: [{appearance: luminosity, value: dark}]` entry pointing at a copy of `icon.svg` with the `#000` fills/strokes changed to a light ink, e.g. `#FBFAF7` or `#E6E9EC`). SplashView's usage is unaffected (fixed light background there is fine, see Deliberately-fixed section).

### [MEDIUM] SplashView is hard-coded fully light — bright full-screen flash at launch in dark mode
- **Location:** `Views/SplashView.swift:43` (`.background(ODPalette.paper)`) and `Views/SplashView.swift:49-53` (fixed `ODPalette` RGB literals: ink `#0B0F12`, ink2 `#2A3138`, ink3 `#5A6470`, blueInk `#00A6DD`, paper `#FBFAF7`)
- **Issue:** Background and all four text colors are fixed literals lifted from opendisplay.org's light design tokens. The view is self-consistent (text is always legible), but it does not adapt.
- **Impact:** In dark mode the launch sequence is: black system launch screen (`UILaunchScreen` is an empty dict → adaptive) → **5 seconds of a bright near-white full-screen splash** → dark home screen. Jarring, especially at night; no readability failure though.
- **Recommendation:** Either (a) declare it a deliberate "paper" brand moment and keep it (then reduce the 5 s auto-dismiss for dark users' comfort is optional), or (b) make `ODPalette` adaptive with `Color(uiColor: UIColor { trait in ... })` dynamic providers, mirroring the website's dark tokens (paper → near-black `#0B0F12`, ink → light, ink2/ink3 → mid grays, blueInk can stay). Option (b) is recommended; the black lettering in the logo would also need finding #1 fixed to stay visible on a dark splash.

### [MEDIUM] Composer palette swatch picker: black swatch nearly invisible in dark mode
- **Location:** `Views/ComposerView.swift:726-743` (`colorSwatchPicker`) — `RoundedRectangle.fill(palette[i])` with a 1 pt `Color(.systemGray4)` border for unselected swatches
- **Issue:** Every e-paper palette begins with pure black `(0,0,0)` (`Models/ImageProcessor.swift:62-70`). The tool panel sits on the default system background (near-black in dark mode), and `systemGray4` resolves to a dark gray (`#3A3A3C`) in dark mode — so an unselected black swatch is a black square with a barely-darker hairline on a black page.
- **Impact:** Users can't see the default draw/text/QR color chip (which is also the *selected default*, index 0) in dark mode; the swatch grid looks like it has a hole in it. The white swatch in light mode has the same construction but survives because `systemGray4` light (`#D1D1D6`) contrasts adequately.
- **Recommendation:** Give each swatch a contrast-safe surround: e.g. change the unselected stroke to `Color.primary.opacity(0.3)`, or place swatches on a `Color(.secondarySystemBackground)` rounded chip, or add a second inner stroke `Color(.systemBackground)` so both black-on-dark and white-on-light are delimited.

### [LOW] BLE Tester log-row tints (5–7% opacity) effectively vanish in dark mode
- **Location:** `Views/BLETesterView.swift:244-250` (`LogEntryRow.backgroundColor`: `Color.blue.opacity(0.05)`, `.green.opacity(0.05)`, `.orange.opacity(0.07)`), rendered on `Color(.systemGroupedBackground)` (`BLETesterView.swift:129`), which is pure black in dark mode
- **Issue:** A 5% tint over pure black is imperceptible; the direction color-coding of rows is lost. (The 3 pt colored direction bar at `BLETesterView.swift:229-234` still conveys the information, so this is cosmetic degradation, not information loss.)
- **Impact:** Log rows lose their subtle sent/received/system grouping in dark mode; slightly harder to scan. Engineering-tools screen, low traffic.
- **Recommendation:** Raise opacity (0.12–0.15 reads correctly in both modes), or compose over an adaptive row surface: `Color(.secondarySystemGroupedBackground)` overlaid with the tint.

### [LOW] Canvas placeholder hint uses *adaptive* grays on the *fixed white* canvas — inconsistent by construction
- **Location:** `Views/DisplayCanvasView.swift:132-142` (`placeholder`: icon `Color(.systemGray3)`, caption `Color(.systemGray2)`) drawn over the intentionally fixed `Color.white` canvas (`DisplayCanvasView.swift:89`)
- **Issue:** The canvas background is (correctly) fixed light, but the placeholder colors are dynamic: in dark mode `systemGray2`/`systemGray3` resolve to darker grays, so the hint gets *darker* on the same white canvas.
- **Impact:** No readability failure — contrast actually increases — but on-canvas content changes with app appearance even though the canvas simulates fixed physical media. Cosmetic inconsistency.
- **Recommendation:** Pin the placeholder to fixed light-appearance values (e.g. `Color(white: 0.72)` / `Color(white: 0.62)`), or apply `.environment(\.colorScheme, .light)` to the canvas `ZStack` content so everything drawn "on paper" always renders with light-mode semantics.

### [INFO] Name collision: domain enum `ColorScheme` shadows `SwiftUI.ColorScheme`
- **Location:** `BLE/ODConstants.swift:103` (`enum ColorScheme: UInt8` — e-paper color capability), used in `ContentView.swift:144,304`, `ComposerView.swift:516`
- **Issue:** Not a dark-mode bug today, but any future remediation that adds `@Environment(\.colorScheme)` to these files must spell the environment type `SwiftUI.ColorScheme`, or the compiler will resolve the OD enum and fail confusingly.
- **Impact:** Developer friction risk during remediation only.
- **Recommendation:** When implementing dark-mode work, qualify the SwiftUI type where needed; longer term consider renaming the domain enum to `ODColorScheme`.

### Verified clean (no action needed)
- **No forced appearance anywhere:** no `.preferredColorScheme(...)` in any Swift file; no `UIUserInterfaceStyle` in `Info.plist` or `project.pbxproj`. The app honors the system setting.
- **No custom color assets to audit:** `Assets.xcassets` contains only `AppIcon` and `ODLogo` (no colorsets, no `AccentColor` — accent falls back to adaptive system blue, which is fine everywhere it's used: tool chips `ComposerView.swift:382-384`, selection chrome `DisplayCanvasView.swift:205,235`, swatch selection ring `ComposerView.swift:736`).
- **ToolboxView.swift, AdvancedView.swift, AdvancedSettingsView.swift, Components/DeviceRowView.swift, ContentView.swift chrome:** built entirely from `Form`/`List`/semantic styles plus adaptive system status colors (`.green`, `.red`, `.orange`, `.blue` are dynamic system colors with dark variants and adequate contrast on dark backgrounds). Status dots (`ToolboxView.swift:514,908`), connection badges (`DeviceRowView.swift:35-58`), and warning labels all render correctly in both modes.
- **Composer chrome adapts correctly:** connection overlay `Color(.systemBackground).opacity(0.92)` (`ComposerView.swift:284`), upload overlay `.regularMaterial` (`ComposerView.swift:1281`), inactive tool chips `Color(.secondarySystemBackground)` + `Color.primary` (`ComposerView.swift:382-384`), white-on-accent active chip — all fine in both modes.
- **`.opacity` usage elsewhere:** `ComposerView.swift:690` (`.opacity(useMeasuredPalette ? 1 : 0.4)` disabled-control dimming) is appearance-neutral. No black-at-low-opacity shadow/border hacks found.

## Remediation checklist

Ordered by impact; each item is independently shippable.

### 1. `Assets.xcassets/ODLogo.imageset/` (fixes HIGH #1)
- [ ] Create `icon-dark.svg`: copy of `icon.svg` with the `text` group's `fill:#000000` (line 39) and the `outline` stroke `#000` (line 93) changed to a light ink (suggest `#E8EBEE`; keep `#00bfff` arcs unchanged).
- [ ] Edit `Contents.json`: add a second `images` entry `{ "appearances": [{ "appearance": "luminosity", "value": "dark" }], "filename": "icon-dark.svg", "idiom": "universal" }`.
- [ ] Verify `ContentView.swift:54` header and dark-splash (if item 2b chosen) render the correct variant. No code change needed — `Image("ODLogo")` picks up the variant automatically.

### 2. `Views/SplashView.swift` (fixes MEDIUM #2) — pick (a) or (b)
- [ ] (a) Keep fixed-light as a brand decision: add a comment on line 43 documenting the intent, and record it under Deliberately-fixed elements. No code change.
- [ ] (b) Make `ODPalette` adaptive (recommended): replace each `static let` at lines 49–53 with a dynamic color, e.g. `static let paper = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x0B/255, green: 0x0F/255, blue: 0x12/255, alpha: 1) : UIColor(red: 0xFB/255, green: 0xFA/255, blue: 0xF7/255, alpha: 1) })` and analogous light-ink values for `ink`/`ink2`/`ink3` in dark. Requires item 1 first so the logo lettering stays visible on the dark paper.

### 3. `Views/ComposerView.swift:726-743` (fixes MEDIUM #3)
- [ ] Change the unselected swatch stroke from `Color(.systemGray4)` to `Color.primary.opacity(0.3)` (line 736), keeping the 3 pt `Color.accentColor` selected ring; or wrap the `LazyVGrid` in a `RoundedRectangle` chip filled with `Color(.secondarySystemBackground)` with 8 pt padding so all swatches sit on a mid-tone surface in both modes.

### 4. `Views/BLETesterView.swift:244-250` (fixes LOW #4)
- [ ] Raise tint opacities: `.sent → Color.blue.opacity(0.12)`, `.received → Color.green.opacity(0.12)`, `.system → Color.orange.opacity(0.14)`; or return `Color(.secondarySystemGroupedBackground)` blended with the tint. Verify against both `systemGroupedBackground` variants.

### 5. `Views/DisplayCanvasView.swift:132-142` (fixes LOW #5)
- [ ] Pin placeholder colors to fixed values: line 136 `Color(.systemGray3)` → `Color(white: 0.72)`, line 139 `Color(.systemGray2)` → `Color(white: 0.62)`; or apply `.environment(\.colorScheme, .light)` once on the canvas `ZStack` (after line 107) to force light-mode resolution for everything rendered "on paper".

### 6. Cross-cutting hygiene (INFO #6)
- [ ] When adding any `@Environment(\.colorScheme)`, write `@Environment(\.colorScheme) private var appearance: SwiftUI.ColorScheme` in files importing `BLE/ODConstants.swift`'s `ColorScheme`.
- [ ] QA pass in both modes on device/simulator: home list, add-display sheet, composer (all seven tool panels), preview sheet, upload overlay, Advanced → Toolbox / BLE Tester / BLE Log, splash.

## Deliberately-fixed-appearance elements

These simulate physical e-paper output and must **not** adapt to dark mode:

| Element | Location | Rationale |
|---|---|---|
| Canvas background `Color.white` | `DisplayCanvasView.swift:89` | Represents the physical panel's white substrate; the composed image is device output, not app UI. |
| Composite render white fill `UIColor.white` | `ComposerView.swift:1149` | The actual bitmap sent to the panel; must match hardware, never the phone theme. |
| QR code white background | `DisplayCanvasView.swift:533` (`tint.color1 = CIColor(color: .white)`) | Scannability on the physical panel requires light modules regardless of app theme. |
| Selection-chrome white button backing | `DisplayCanvasView.swift:216-217, 235-236` | Sits on the fixed-white canvas; adapting it would reduce contrast against the paper surface. |
| Preview sheet dithered image | `ComposerView.swift:763-767` | Simulated panel output; pixel-exact by design. |
| Palette swatch fills | `ComposerView.swift:732` | Wire-format ink colors of the target hardware; only their *surround* (finding #3) should adapt. |
| Splash "paper" background | `SplashView.swift:43` | *Optional*: fixed light is defensible as a paper-brand moment (see finding #2); if kept fixed, document the decision. |
