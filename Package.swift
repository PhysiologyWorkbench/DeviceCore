// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeviceCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "DeviceCore", targets: ["DeviceCore"]),
        .library(name: "BenchKit", targets: ["BenchKit"])
    ],
    targets: [
        .target(
            name: "DeviceCore"
        ),
        .target(
            name: "BenchKit"
        ),
        .testTarget(
            name: "DeviceCoreTests",
            dependencies: ["DeviceCore"]
        ),
        .testTarget(
            name: "BenchKitTests",
            dependencies: ["BenchKit"]
        )
    ]
)
