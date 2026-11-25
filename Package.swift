// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clipboard",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipboardCore", targets: ["ClipboardCore"]),
        .executable(name: "Clipboard", targets: ["ClipboardApp"]),
    ],
    targets: [
        .target(name: "ClipboardCore"),
        .executableTarget(
            name: "ClipboardApp",
            dependencies: ["ClipboardCore"]
        ),
        .testTarget(
            name: "ClipboardCoreTests",
            dependencies: ["ClipboardCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
