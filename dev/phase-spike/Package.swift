// swift-tools-version:5.10
import PackageDescription

// phase-spike — THROWAWAY feasibility harness for T-SPIKE-PHASE (see
// dev/notes/phase-lock-spike-findings.md and docs/plans/synced-local-airplay-plan.md).
//
// Measures the achievable phase-lock precision of the kind of AVAudioEngine
// graph SyncedLocalSink builds, and the behaviour of candidate rate-correction
// nodes (AVAudioUnitTimePitch / AVAudioUnitVarispeed) — all with SILENT,
// headless, offline manual rendering (never routes audio to a real device),
// plus one guarded real-device probe that emits pure digital silence.
//
// Deliberately SEPARATE from AudioutCore (does not link it): this is a
// disposable measurement tool, not shipping code, and re-derives the timing
// math independently so it is an INDEPENDENT check of SyncedLocalSink's plan().
let package = Package(
    name: "phase-spike",
    platforms: [
        // Matches dev/audiocap: process-tap-era macOS. AVAudioEngine manual
        // rendering is 10.15+, but we pin high to match the app's real floor.
        .macOS("14.4")
    ],
    targets: [
        .executableTarget(
            name: "phase-spike"
        )
    ]
)
