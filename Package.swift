// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ESPIDE",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ESPIDE", targets: ["ESPIDE"]),
        .library(name: "ESPIDECore", targets: ["ESPIDECore"]),
    ],
    targets: [
        // UI-independent pieces: LSP client, Go highlighter, text/position math, file tree.
        .target(name: "ESPIDECore"),
        // SwiftUI/AppKit application shell.
        .executableTarget(name: "ESPIDE", dependencies: ["ESPIDECore"]),
        .testTarget(name: "ESPIDECoreTests", dependencies: ["ESPIDECore"]),
    ]
)
