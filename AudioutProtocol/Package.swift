// swift-tools-version:6.0
import PackageDescription

// Plain manifest, no shell-outs (unlike AudioutCore/Package.swift, which
// resolves `brew --prefix` for AirPlayEngine's C dependencies) — this package
// must be a Foundation-only graph the iOS app can build without Homebrew.
//
// Tools version 6.0, not 5.10 (AudioutCore's) — `.iOS(.v18)` is only
// available starting with PackageDescription 6.0; SwiftPM allows mixed
// manifest tools-versions across a local dependency graph, so AudioutCore
// staying on 5.10 while depending on this package is fine.
let package = Package(
    name: "AudioutProtocol",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "AudioutProtocol", targets: ["AudioutProtocol"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AudioutProtocol"
        ),
        .testTarget(
            name: "AudioutProtocolTests",
            dependencies: ["AudioutProtocol"]
        ),
    ]
)
