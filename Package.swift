// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexCurrent",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexCurrent", targets: ["CodexCurrent"])],
    targets: [
        .executableTarget(name: "CodexCurrent"),
        .testTarget(name: "CodexCurrentTests", dependencies: ["CodexCurrent"])
    ]
)
