# Vendored frameworks

## EpaperDithering.xcframework

Static-library XCFramework wrapping the Rust `epaper-dithering-core` dithering engine
(OKLab palette matching + error diffusion). Consumed by `Models/RustDither.swift`, which
`ImageProcessor` calls in place of the former pure-Swift sRGB-Euclidean matcher — so the app's
dithered output is now byte-for-byte identical to the website / Python / firmware reference.

**This is a build artifact — do not hand-edit.** It is the `epaper-dithering-ios` release
artifact from the `epaper-dithering` repo (source crate `packages/rust/ios`), downloaded and
checksum-verified by `scripts/sync-dither-xcframework.sh`.

- Vendored release: see [`EpaperDithering.release`](EpaperDithering.release) (version, release
  URL and SwiftPM checksum; written by the sync script).
- Built from: **epaper-dithering-core 6.0.0**, FFI ABI 2 (`ed_dither_options` struct + DBS).
- Slices: `ios-arm64` (device) + `ios-arm64_x86_64-simulator` (arm64 + x86_64).

### Updating

```sh
# Vendor a published release (normal path; needs only curl + Xcode's swift):
scripts/sync-dither-xcframework.sh 1.0.1
```

Releases are cut by release-please in `epaper-dithering` from `feat(ios)` / `fix(ios)` commits;
CI builds the XCFramework and attaches `EpaperDithering.xcframework.zip` plus its `.checksum`
(see https://github.com/OpenDisplay/epaper-dithering/releases). The script refuses a zip whose
checksum doesn't match, or whose header isn't FFI ABI 2 (what `Models/RustDither.swift` calls).

To test an unreleased FFI change, build from a local checkout instead (needs Rust, the iOS
targets and `llvm-tools`). It is recorded as an unreleased build, so re-vendor from a release
before merging:

```sh
scripts/sync-dither-xcframework.sh --from-source /path/to/epaper-dithering
```

Parity with the reference is pinned by `Tests/RustDitherParityTests.swift`, which dithers a stored
fixture and asserts byte-equality against the core's `floyd_steinberg_mono_raw` reference output.
Keep that test green when updating the framework.
