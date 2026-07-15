// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShakeTree",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ShakeTree",
            path: "Sources/ShakeTree"
        )
    ]
)
