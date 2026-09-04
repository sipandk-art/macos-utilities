// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacOSUtilities",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MacOSUtilities", path: "Sources/MacOSUtilities")
    ]
)
