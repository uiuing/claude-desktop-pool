// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeDesktopPool",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ClaudePool", targets: ["ClaudePool"])],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
        .package(url: "https://github.com/nalexn/ViewInspector.git", exact: "0.10.5"),
    ],
    targets: [
        .target(name: "PoolCore", resources: [.copy("Localizations")]),
        .target(name: "CPTY", publicHeadersPath: "include"),
        .target(name: "CStackProbe", publicHeadersPath: "include"),
        .target(name: "PoolRuntime", dependencies: ["PoolCore", "CPTY"]),
        .target(name: "PoolGateway", dependencies: ["PoolCore"]),
        .target(name: "PoolEngine", dependencies: ["PoolCore", "PoolRuntime"]),
        .target(name: "PoolPrivacy", dependencies: ["PoolCore", "PoolRuntime",
            .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")]),
        .executableTarget(name: "ClaudePool", dependencies: ["PoolCore", "PoolRuntime", "PoolGateway", "PoolEngine", "PoolPrivacy", "CStackProbe"]),
        .testTarget(name: "PoolCoreTests", dependencies: ["PoolCore"]),
        .testTarget(name: "PoolRuntimeTests", dependencies: ["PoolRuntime"]),
        .testTarget(name: "PoolGatewayTests", dependencies: ["PoolGateway"]),
        .testTarget(name: "PoolEngineTests", dependencies: ["PoolEngine", "PoolGateway"]),
        .testTarget(name: "PoolPrivacyTests", dependencies: ["PoolPrivacy"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ScreenshotTests", dependencies: ["ClaudePool",
            .product(name: "ViewInspector", package: "ViewInspector")]),
    ],
    swiftLanguageModes: [.v5]
)
