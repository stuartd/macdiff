// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDiff",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDiff", targets: ["MacDiff"]),
        .library(name: "DiffCore", targets: ["DiffCore"])
    ],
    targets: [
        .target(name: "DiffCore"),
        .executableTarget(name: "MacDiff", dependencies: ["DiffCore"]),
        .testTarget(name: "DiffCoreTests", dependencies: ["DiffCore"])
    ]
)
