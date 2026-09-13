// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexCurrent",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexCurrent", targets: ["CodexCurrent"])],
    targets: [
        .executableTarget(
            name: "CodexCurrent",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "CodexCurrentTests", dependencies: ["CodexCurrent"])
    ]
)
