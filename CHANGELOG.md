# Changelog

All notable changes to the OpenDisplay Utility app. Versions correspond to the app's
`MARKETING_VERSION` and are released as `v<version>` git tags. Releases before 0.1.6 predate this
file — see the `v0.1.0`–`v0.1.5` tags for their history.

## [0.1.7] — 2026-07-18

### Changed
- **Settings → About** and the **startup splash** now display the app version read from the app
  bundle (`CFBundleShortVersionString`) instead of a hardcoded string, so the shown version always
  matches the shipped build. (The splash gains a "Version" line above the copyright footer.)

### Fixed
- The About screen previously showed a stale hardcoded version (`0.1.4`).

## [0.1.6] — 2026-07-18

### Added
- **Rust-powered dithering.** Image dithering now runs on the shared `epaper-dithering` Rust core
  (`RustDither` → `EpaperDithering.xcframework`), matching colors in **OKLab**. Dithered output is
  now byte-for-byte identical to the OpenDisplay website and Python library, replacing the app's
  previous sRGB-Euclidean matcher.

### Changed
- **Composer: Adjust controls moved into the Photo tab.** The separate "Adjust" chip is gone; its
  brightness / contrast / shadows / highlights / saturation / tone-compression controls now live at
  the bottom of the Photo panel.

### Removed
- The legacy pure-Swift dithering path (error-diffusion matcher + fallback) — superseded by the Rust
  core.
- Dead code: unused `CanvasMode` UI metadata, `ImageProcessor.process(image:)`, `pack1bpp`'s unused
  `invert` parameter, and the vestigial `ODConfigModel.deviceLabel` stub.

### Internal
- Documentation refreshed to describe the Rust dithering path (`docs/architecture.md`, `README.md`),
  and a dead-code review recorded in `docs/dead-code-review.md`.

[0.1.7]: https://github.com/davelee98/OD-App/releases/tag/v0.1.7
[0.1.6]: https://github.com/davelee98/OD-App/releases/tag/v0.1.6
