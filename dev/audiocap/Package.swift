// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "audiocap",
    // Core Audio process taps are macOS 14.2+ (publicly usable 14.4). This tool is
    // deliberately SEPARATE from AudiouterCore (which pins .macOS(.v13)).
    platforms: [
        .macOS("14.4")
    ],
    targets: [
        .executableTarget(
            name: "audiocap",
            // Info.plist is embedded into the Mach-O at link time (below), NOT
            // shipped as an SPM resource — exclude it so SPM stops warning.
            exclude: ["Info.plist"],
            linkerSettings: [
                // Bake NSAudioCaptureUsageDescription into the Mach-O so the TCC
                // dialog has a rationale string. A bare SwiftPM executable has no
                // Info.plist, so we -sectcreate it into __TEXT,__info_plist.
                // (0e brief §5.)
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/audiocap/Info.plist"
                ])
            ]
        )
    ]
)
