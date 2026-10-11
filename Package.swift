// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SneakPeek",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SneakPeek", targets: ["SneakPeek"])],
    targets: [
        .target(name: "SneakPeekCore"),
        .executableTarget(name: "SneakPeek", dependencies: ["SneakPeekCore"]),
        .testTarget(name: "SneakPeekCoreTests", dependencies: ["SneakPeekCore"])
    ]
)
