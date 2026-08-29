// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ProbeKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ProbeKit", targets: ["ProbeKit"])
    ],
    targets: [
        .target(name: "ProbeKit"),
        .testTarget(name: "ProbeKitTests", dependencies: ["ProbeKit"])
    ]
)
