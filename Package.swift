// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dustling",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DustlingCore", targets: ["DustlingCore"]),
        .library(name: "DustlingAppModel", targets: ["DustlingAppModel"]),
        .executable(name: "dustling-cli", targets: ["dustling-cli"]),
    ],
    targets: [
        .target(name: "DustlingCore"),
        .target(name: "DustlingAppModel", dependencies: ["DustlingCore"]),
        .executableTarget(name: "dustling-cli", dependencies: ["DustlingCore", "DustlingAppModel"]),
        .testTarget(name: "DustlingCoreTests", dependencies: ["DustlingCore"]),
        .testTarget(name: "DustlingAppModelTests", dependencies: ["DustlingAppModel", "DustlingCore"]),
    ]
)
