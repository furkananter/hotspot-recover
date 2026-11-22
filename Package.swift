// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "hotspot-recover",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "hotspot-recover", path: "Sources/hotspot-recover")
    ]
)
