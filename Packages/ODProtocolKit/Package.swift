// swift-tools-version: 5.9
import PackageDescription

// ODProtocolKit — native Swift implementation of the OpenDisplay BLE wire protocol.
// No CoreBluetooth / JavaScriptCore / app imports: the transport is injected via `ODLink`.
// Depends on Foundation + libz (Czlib) + CryptoSwift (AES-CMAC / AES-ECB / AES-CCM for the
// auth handshake and the session AEAD envelope). CryptoSwift is pinned to the same 1.10.0 the
// app already resolves, so the app links a single shared copy.
let package = Package(
    name: "ODProtocolKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "ODProtocolKit", targets: ["ODProtocolKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift", exact: "1.10.0"),
    ],
    targets: [
        .systemLibrary(name: "Czlib", path: "Sources/Czlib"),
        .target(name: "ODProtocolKit", dependencies: ["Czlib", "CryptoSwift"]),
        .testTarget(name: "ODProtocolKitTests", dependencies: ["ODProtocolKit"]),
    ]
)
