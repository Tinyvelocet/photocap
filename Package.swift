// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "photocap",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared engine: safe read-only parser + pruning logic (rebuildable caches only).
        .target(name: "PhotocapEngine", path: "Sources/PhotocapEngine"),

        // CLI wrapper around the engine.
        .executableTarget(
            name: "photocap",
            dependencies: ["PhotocapEngine"],
            path: "Sources/photocap"
        ),

        // Menu-bar GUI wrapper around the engine.
        .executableTarget(
            name: "photocap-gui",
            dependencies: ["PhotocapEngine"],
            path: "Sources/photocap-gui"
        ),
    ]
)
