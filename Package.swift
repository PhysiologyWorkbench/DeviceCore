// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeviceCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "DeviceCore", targets: ["DeviceCore"])
    ],
    targets: [
        .target(
            name: "DeviceCore"
        ),
        .testTarget(
            name: "DeviceCoreTests",
            dependencies: ["DeviceCore"]
        )
    ]
)
