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
    dependencies: [
        .package(url: "https://github.com/kirktools/pkg-logging.git", exact: "0.1.0"),
    ],
    targets: [
        .target(
            name: "ClipboardDiagnostics",
            dependencies: [
                .product(name: "KirkLogging", package: "pkg-logging"),
            ]
        ),
        .target(
            name: "ClipboardCore",
            dependencies: ["ClipboardDiagnostics"]
        ),
        .executableTarget(
            name: "ClipboardApp",
            dependencies: ["ClipboardCore", "ClipboardDiagnostics"]
        ),
        .testTarget(
            name: "ClipboardCoreTests",
            dependencies: ["ClipboardCore", "ClipboardDiagnostics"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
