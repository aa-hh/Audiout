// swift-tools-version:6.0
import PackageDescription

// SPIKE STUB — replaced by dsp track at merge
//
// Standalone, dependency-free package (BT auto-cal spike, Track B "dsp"):
// analyzes a phone-recorded alternating-mute tick probe and returns the
// target device's timing offset vs a reference device. This manifest ships
// only the API surface the app target links against; Track B's real
// implementation + self-tests replace everything under Sources/ (and add a
// test target) at reconciliation — see dev/notes/bt-autocal-spike-spec.md.
let package = Package(
    name: "ProbeKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ProbeKit", targets: ["ProbeKit"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ProbeKit"
        ),
    ]
)
