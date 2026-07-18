# Vendored frameworks

## EpaperDithering.xcframework

Static-library XCFramework wrapping the Rust `epaper-dithering-core` dithering engine
(OKLab palette matching + error diffusion). Consumed by `Models/RustDither.swift`, which
`ImageProcessor` calls in place of the former pure-Swift sRGB-Euclidean matcher — so the app's
dithered output is now byte-for-byte identical to the website / Python / firmware reference.

**This is a build artifact — do not hand-edit.** It is produced from the FFI wrapper crate in the
`epaper-dithering` repo:

- Source crate: `epaper-dithering/packages/rust/ios`
- Core version at last sync: **epaper-dithering-core 4.0.1**
- Slices: `ios-arm64` (device) + `ios-arm64_x86_64-simulator` (arm64 + x86_64)

### Regenerating / updating

```sh
# In the epaper-dithering repo (needs Rust + iOS targets + Xcode):
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
packages/rust/ios/build-xcframework.sh

# Then re-vendor into this app:
scripts/sync-dither-xcframework.sh /path/to/epaper-dithering
```

Parity with the reference is pinned by `Tests/RustDitherParityTests.swift`, which dithers a stored
fixture and asserts byte-equality against the core's `floyd_steinberg_mono_raw` reference output.
Keep that test green when updating the framework.
