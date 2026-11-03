// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lsfg-metal",
    platforms: [.macOS(.v15)],
    products: [
        // LSFG 3.1 frame generation on Metal: shader translation from the user's Lossless.dll, kernels, pass graph.
        .library(name: "LSFGCore", targets: ["LSFGCore"]),
        // The same as a C API (lsfg_bridge_*), for hosts that aren't Swift; built for x86_64 too.
        .library(name: "LSFGBridge", type: .dynamic, targets: ["LSFGBridge"]),
        // Command-line tool: locate, translate, check, generate, eval, profile, bench, bake.
        .executable(name: "lsfg-metal", targets: ["lsfg-metal"]),
    ],
    targets: [
        .target(name: "LSFGCore"),
        .target(name: "LSFGBridge", dependencies: ["LSFGCore"]),
        .executableTarget(name: "lsfg-metal", dependencies: ["LSFGCore"]),
        .testTarget(name: "LSFGCoreTests", dependencies: ["LSFGCore"]),
    ]
)
