// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlcoveKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AlcoveDisplayProtocol", targets: ["AlcoveDisplayProtocol"]),
        .library(name: "AlcoveQMP", targets: ["AlcoveQMP"]),
        .library(name: "AlcoveEngine", targets: ["AlcoveEngine"]),
    ],
    targets: [
        // Wire format shared with the QEMU `alcove` display backend (docs/display-protocol.md).
        .target(name: "AlcoveDisplayProtocol"),
        // QEMU Machine Protocol client over a unix socket.
        .target(name: "AlcoveQMP"),
        // VM bundles, QEMU process lifecycle, VM controller. Depends on the two above.
        .target(name: "AlcoveEngine", dependencies: ["AlcoveDisplayProtocol", "AlcoveQMP"]),
        .testTarget(name: "AlcoveDisplayProtocolTests", dependencies: ["AlcoveDisplayProtocol"]),
        .testTarget(name: "AlcoveQMPTests", dependencies: ["AlcoveQMP"]),
        .testTarget(name: "AlcoveEngineTests", dependencies: ["AlcoveEngine"]),
    ],
    swiftLanguageModes: [.v6]
)
