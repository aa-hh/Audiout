// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AirPlayControllerCore",
    platforms: [.macOS(.v13)],
    products: [
        // The core library the AppKit app links against. It knows nothing about
        // AppKit — it's the seam between "the UI" and "wherever audio actually goes."
        .library(name: "AirPlayControllerCore", targets: ["AirPlayControllerCore"]),
        // A headless demo so you can watch the mock backend behave with no UI.
        .executable(name: "mock-speakers-demo", targets: ["mock-speakers-demo"]),
    ],
    targets: [
        .target(name: "AirPlayControllerCore"),
        .executableTarget(
            name: "mock-speakers-demo",
            dependencies: ["AirPlayControllerCore"]
        ),
        .testTarget(
            name: "AirPlayControllerCoreTests",
            dependencies: ["AirPlayControllerCore"]
        ),
    ]
)
