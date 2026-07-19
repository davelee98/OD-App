// swift-tools-version: 5.9
import PackageDescription

// ODProtocolKit — native Swift implementation of the OpenDisplay BLE wire protocol.
// No CoreBluetooth / JavaScriptCore / app imports: the transport is injected via `ODLink`.
// Depends only on Foundation + libz (Czlib). CryptoSwift is added in the auth/crypto phase.
let package = Package(
    name: "ODProtocolKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "ODProtocolKit", targets: ["ODProtocolKit"]),
    ],
    targets: [
        .systemLibrary(name: "Czlib", path: "Sources/Czlib"),
        .target(name: "ODProtocolKit", dependencies: ["Czlib"]),
        .testTarget(name: "ODProtocolKitTests", dependencies: ["ODProtocolKit"]),
    ]
)
