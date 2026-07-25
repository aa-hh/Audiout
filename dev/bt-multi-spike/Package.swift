// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "bt-multi-spike",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "bt-multi-spike"
        )
    ]
)
