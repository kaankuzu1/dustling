// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dustling",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DustlingCore", targets: ["DustlingCore"]),
        .executable(name: "dustling-cli", targets: ["dustling-cli"]),
    ],
    targets: [
        .target(name: "DustlingCore"),
        .executableTarget(name: "dustling-cli", dependencies: ["DustlingCore"]),
        .testTarget(name: "DustlingCoreTests", dependencies: ["DustlingCore"]),
    ]
)
