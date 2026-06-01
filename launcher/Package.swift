// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GeneralsZHLauncher",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "GeneralsZHLauncher",
            path: "Sources/GeneralsZHLauncher"
        )
    ]
)
