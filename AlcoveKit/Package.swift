// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlcoveKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AlcoveDisplayProtocol", targets: ["AlcoveDisplayProtocol"]),
        .library(name: "AlcoveQMP", targets: ["AlcoveQMP"]),
        .library(name: "AlcoveEngine", targets: ["AlcoveEngine"]),
        .executable(name: "alcovectl", targets: ["alcovectl"]),
        .library(name: "AlcoveAgent", targets: ["AlcoveAgent"]),
        .library(name: "AlcoveControl", targets: ["AlcoveControl"]),
    ],
    targets: [
        // Wire format shared with the QEMU `alcove` display backend (docs/display-protocol.md).
        .target(name: "AlcoveDisplayProtocol"),
        // QEMU Machine Protocol client over a unix socket.
        .target(name: "AlcoveQMP"),
        // VM bundles, QEMU process lifecycle, VM controller. Depends on the two above.
        .target(name: "AlcoveEngine", dependencies: ["AlcoveDisplayProtocol", "AlcoveQMP"]),
        // Host side of the guest agent protocol (docs/agent-protocol.md).
        .target(name: "AlcoveAgent", dependencies: ["AlcoveQMP"]),
        // Fakes shared by the test targets.
        .target(name: "AlcoveTestSupport", dependencies: ["AlcoveQMP"], path: "Tests/AlcoveTestSupport"),
        .testTarget(name: "AlcoveAgentTests", dependencies: ["AlcoveAgent", "AlcoveTestSupport"]),
        // Automation API over a unix socket (docs/control-protocol.md): screenshots, input, exec.
        .target(name: "AlcoveControl", dependencies: ["AlcoveEngine", "AlcoveAgent", "AlcoveDisplayProtocol", "AlcoveQMP"]),
        .testTarget(name: "AlcoveControlTests", dependencies: ["AlcoveControl", "AlcoveTestSupport"]),
        // Command-line front end used by scripts and the test harness.
        .executableTarget(name: "alcovectl", dependencies: ["AlcoveEngine", "AlcoveDisplayProtocol", "AlcoveControl", "AlcoveAgent"]),
        .testTarget(name: "AlcoveDisplayProtocolTests", dependencies: ["AlcoveDisplayProtocol"]),
        .testTarget(name: "AlcoveQMPTests", dependencies: ["AlcoveQMP"]),
        .testTarget(name: "AlcoveEngineTests", dependencies: ["AlcoveEngine"]),
    ],
    swiftLanguageModes: [.v6]
)
