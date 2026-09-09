// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "unplug",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "unplug", path: "Sources/unplug")
    ]
)
