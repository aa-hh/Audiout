// swift-tools-version:5.10
import PackageDescription
import Foundation

// Brew include paths for the same Homebrew-keg-only libs AirPlayEngine's C
// target needs (../AirPlayEngine/Package.swift). A C target's cSettings
// .unsafeFlags do NOT propagate to a DOWNSTREAM package's Swift target when it
// imports that C target's headers (transitively, via `import AirPlayEngine` ->
// CAirPlayEngine's umbrella header, which #includes <event2/event.h> etc.) —
// AirPlayEngine/Package.swift's own AirPlayEngine Swift target already has to
// restate these for itself (see its swiftClangImporterFlags), and this
// manifest is one dependency hop further away, so it must restate them again.
// Without this, a normal debug `swift build` still resolves the module (the
// implicit build system tolerates it), but an explicit-module-build release
// config (as newer Xcode toolchains default to) fails to find
// 'event2/thread.h' resolving CAirPlayEngine's module from here.
func resolveBrewPrefix() -> String {
    if let env = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"], !env.isEmpty {
        return env
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["brew", "--prefix"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    if (try? p.run()) != nil {
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty, FileManager.default.fileExists(atPath: s) {
            return s
        }
    }
    if FileManager.default.fileExists(atPath: "/opt/homebrew") { return "/opt/homebrew" }
    return "/usr/local"
}

let brewPrefix = resolveBrewPrefix()

let brewFormulae = ["libevent", "libsodium", "libgcrypt", "libgpg-error", "libplist"]

let swiftClangImporterFlags: [String] =
    brewFormulae.flatMap { ["-Xcc", "-I\(brewPrefix)/opt/\($0)/include"] }

// Platform floor: raised from .v13 to .v14 for T-NB-PKGDEP-1. AirPlayEngine
// (../AirPlayEngine/Package.swift) is .macOS(.v14) — its Core Audio process
// tap capture (T-NB-CAPTURE-1) needs the tap API, which is 14.4+ (ahh runs
// 14.4.1) — and a SwiftPM package's platform floor cannot be lower than any
// local dependency it links (Xcode/SwiftPM enforces the dependency's
// deployment target as a floor on any target that depends on it, and will
// fail to build/resolve otherwise). Rather than fighting per-symbol
// `@available` annotations to keep .v13 alive for code paths that never run
// on 13 anyway (NativeBackend is opt-in via AIRPLAY_BACKEND=native), we take
// the whole package to .v14. The mock/OwnTone-backed paths are unaffected —
// they don't reference anything gated above .v13; this only tightens the
// deployment target the app links for and installs on.
let package = Package(
    name: "AudiouterCore",
    platforms: [.macOS(.v14)],
    products: [
        // The core library the AppKit app links against. It knows nothing about
        // AppKit — it's the seam between "the UI" and "wherever audio actually goes."
        .library(name: "AudiouterCore", targets: ["AudiouterCore"]),
        // A headless demo so you can watch the mock backend behave with no UI.
        .executable(name: "mock-speakers-demo", targets: ["mock-speakers-demo"]),
        // A headless harness that instantiates the AppKit `PopoverController`
        // with a MockBackend-backed `GroupController` and asserts the built
        // SoundSource-style panel (SPEC §9b Main Out model): a Main Out selector
        // with two sections (Selected Devices + groups), selecting a group routes
        // (output set = members), toggles compose the Selected Devices set
        // without routing under a group target, the current-device auto-swap +
        // local-mix block, the Main Out master reflecting the target, and animated
        // group expansion. Prints PASS/FAIL, exits nonzero on failure (the popover
        // isn't visible to an agent shell). Run: `swift run popover-harness`.
        .executable(name: "popover-harness", targets: ["popover-harness"]),
        // The same idea for the mixer window (T-U4): instantiates the real
        // `MixerWindowController` against a MockBackend-backed `GroupController`
        // and asserts its structure (sidebar sections/counts, selecting a group
        // populates the mixer with its member rows, rename → saveGroup, delete →
        // deleteGroup, membership toggle updates the group). The window isn't
        // visible to an agent shell either. Run: `swift run window-harness`.
        .executable(name: "window-harness", targets: ["window-harness"]),
        // Offscreen visual verification for the popover panel (layout overhaul):
        // builds the real `PopoverPanelViewController` with a MockBackend-backed
        // `GroupController` (demo fleet + a group, one expanded), sizes it to the
        // popover width, renders it via `bitmapImageRepForCachingDisplay`+
        // `cacheDisplay` and writes PNGs (light + dark) to
        // `dev/notes/popover-snapshots/`. Run: `swift run popover-snapshot`.
        .executable(name: "popover-snapshot", targets: ["popover-snapshot"]),
        // Offscreen PNG renderer for the Settings window (single-screen General/
        // Appearance/Audio layout, T-2026-07-17 sizing-bug fix + tile-picker
        // redesign) — see the product comment in settings-snapshot/main.swift.
        .executable(name: "settings-snapshot", targets: ["settings-snapshot"]),
        // Offscreen PNG renderer for the first-run onboarding window (permission
        // priming) — the window isn't visible to an agent shell, so this renders
        // it (light + dark, each permission status) for visual verification.
        .executable(name: "onboarding-snapshot", targets: ["onboarding-snapshot"]),
        // Offscreen PNG renderer for the alignment-wizard window (v2 visual
        // verification). Run: `swift run wizard-snapshot [output-dir]`.
        .executable(name: "wizard-snapshot", targets: ["wizard-snapshot"]),
        // Silent read-only Core Audio diagnostic for enumerating process objects and
        // their PIDs/bundle IDs, useful for diagnosing per-app routing (T7).
        .executable(name: "core-audio-diagnostic", targets: ["core-audio-diagnostic"]),
        // Tiny, short-lived TCC-preflight probe (T14): `TCCProbeRunner` spawns this
        // fresh, on demand, to get an un-cached `TCCAccessPreflight` read — see
        // Sources/tcc-probe/main.swift for the full finding and output contract. No
        // dependency on AudiouterCore by design: it must stay minimal, entitlement-free,
        // and fast to spawn.
        .executable(name: "tcc-probe", targets: ["tcc-probe"]),
        // The pure-AppKit menu-bar app. `swift build` produces a loose binary;
        // scripts/make-app.sh wraps it into a real double-clickable `.app`
        // (RESOLVED Q1 — SwiftPM executable + bundle script, no Xcode project).
        .executable(name: "AudiouterApp", targets: ["AudiouterApp"]),
        // T7 (PLAN-FIREFOX-ROUTING-LEAK.md): silent, no-audio diagnostic —
        // dumps every live Core Audio process object (pid, command, parent,
        // whether it independently resolves as an NSRunningApplication) so
        // Alec can confirm on his own machine whether a multi-process
        // browser's actual audio producer is a child process our single-PID
        // resolver can never find. Run: `swift run process-audio-dump`.
        .executable(name: "process-audio-dump", targets: ["process-audio-dump"]),
    ],
    dependencies: [
        // The native AirPlay 2 sender engine (PLAN-PHASE-2b T-NB-PKGDEP-1).
        // Local path dependency, sibling package — NativeBackend
        // (T-NB-BACKEND-1) and NativeCaptureCoordinator (T-NB-CAPTURE-1) are
        // the consumers; the Mock/OwnTone backends do not import it.
        .package(path: "../AirPlayEngine"),
    ],
    targets: [
        // Block-based Objective-C exception catcher. Swift's `catch` cannot
        // see NSException at all (AVFAudio's
        // play/scheduleBuffer/connect and NSThread.start raise it, not
        // NSError — a confirmed crash class here). This is the one
        // ObjC-language target allowed to @try/@catch; `AudiouterCore`
        // wraps it in `catchingObjCException` for normal Swift call sites.
        .target(
            name: "ObjCExceptionShim"
        ),
        .target(
            name: "AudiouterCore",
            dependencies: [
                .product(name: "AirPlayEngine", package: "AirPlayEngine"),
                "ObjCExceptionShim",
            ],
            swiftSettings: [
                .unsafeFlags(swiftClangImporterFlags),
            ]
        ),
        .executableTarget(
            name: "mock-speakers-demo",
            dependencies: ["AudiouterCore"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // The shared `DeviceRowView` (SPEC §9 "Device row (shared by the popover
        // and the window)"). A library both `AudiouterPopoverUI` and
        // `AudiouterWindowUI` link, so the row is ONE implementation with
        // ONE test surface, correct in both hosts (it paints the menu highlight
        // only when parented in an `NSMenuItem`; in the popover/window it lets the
        // standard appearance show). It hosts the primary "send audio here" ON/OFF
        // switch + secondary mute. Talks only to `OutputBackend` / its
        // `Delegate` — no backend knowledge.
        .target(
            name: "AudiouterSharedUI",
            dependencies: ["AudiouterCore"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // The pure-AppKit popover dropdown (SPEC §9 revised — NSMenu → NSPopover):
        // `PopoverController` + `GroupRowView`, a Control-Center-style panel
        // hosted in an `NSPopover`. A *library* (not folded into the executable)
        // so both the app AND the headless `popover-harness` / tests can link it
        // and assert the built panel structure. Reuses the shared `DeviceRowView`.
        //
        // Since U3 (one-surface app) this target also hosts
        // `AppSurfaceController`, which composes ALL THREE screens — hence the
        // deps on AudiouterWindowUI (Groups content) and AudiouterSettingsUI
        // (Settings screen). One-directional on purpose: neither of those
        // targets may ever depend back on this one.
        .target(
            name: "AudiouterPopoverUI",
            dependencies: ["AudiouterCore", "AudiouterSharedUI",
                           "AudiouterWindowUI", "AudiouterSettingsUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // The pure-AppKit mixer window (SPEC §9 "Full window"): a
        // `MixerWindowController` hosting an `NSSplitViewController` (source-list
        // `NSOutlineView` sidebar + `NSStackView` mixer), a `.unified` `NSToolbar`
        // with a master `NSSlider` + presets `NSPopUpButton`, and the group
        // editor (rename / membership checkboxes / delete). A *library* so the
        // app AND the headless `window-harness` / tests can link it and assert
        // the built window structure. Reuses the shared `DeviceRowView`.
        .target(
            name: "AudiouterWindowUI",
            dependencies: ["AudiouterCore", "AudiouterSharedUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // The pure-AppKit Settings content: a `SettingsRootViewController`
        // (an `NSTabViewController`, one pane per tab — General, Appearance, …)
        // hosted on the one-surface shell. A *library* so the app AND tests can
        // link it and assert the built structure, exactly like the popover/mixer
        // UI libs. Only needs Core (the `AppSettings` scalar store +
        // appearance/density enums) — no shared rows yet.
        .target(
            name: "AudiouterSettingsUI",
            // AudiouterSharedUI: the Tokens design-token layer (Wave 2 of the
            // Warm Signal redesign) — Settings styles through Tokens.* now.
            dependencies: ["AudiouterCore", "AudiouterSharedUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // The pure-AppKit first-run onboarding window (permission priming): an
        // `OnboardingWindowController` hosting a single-screen explanation + a
        // "System Audio" and a "Local Network" permission row, each with a Grant
        // button and live status, driven by Core's `SetupModel`. A *library* (like
        // the popover/mixer/settings UI) so the app AND the headless
        // `onboarding-snapshot` / tests can link it and assert the built window.
        // Only needs Core (`SetupModel` + the permission seams).
        .target(
            name: "AudiouterOnboardingUI",
            // AudiouterSharedUI: the Tokens design-token layer (Wave 2 of the
            // Warm Signal redesign) — onboarding styles through Tokens.* now.
            dependencies: ["AudiouterCore", "AudiouterSharedUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Pure AppKit (SPEC §9). The app shell (status item, backend wiring,
        // lifecycle); the popover dropdown lives in AudiouterPopoverUI,
        // the mixer window in AudiouterWindowUI, the Settings window in
        // AudiouterSettingsUI, the first-run onboarding in AudiouterOnboardingUI.
        .executableTarget(
            name: "AudiouterApp",
            dependencies: [
                "AudiouterCore",
                "AudiouterSharedUI",
                "AudiouterPopoverUI",
                "AudiouterWindowUI",
                "AudiouterSettingsUI",
                "AudiouterOnboardingUI",
            ],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Programmatic popover-structure verification for T-U6 (the popover isn't
        // visible to an agent shell) — see the product comment above.
        .executableTarget(
            name: "popover-harness",
            dependencies: ["AudiouterCore", "AudiouterPopoverUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Programmatic window-structure verification for T-U4 (the window isn't
        // visible to an agent shell) — see the product comment above.
        .executableTarget(
            name: "window-harness",
            dependencies: ["AudiouterCore", "AudiouterWindowUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Offscreen PNG renderer for the popover panel (layout overhaul visual
        // verification) — see the product comment above.
        .executableTarget(
            name: "popover-snapshot",
            dependencies: ["AudiouterCore", "AudiouterPopoverUI", "AudiouterSharedUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Offscreen PNG renderer for the Settings window — see the product
        // comment above.
        .executableTarget(
            name: "settings-snapshot",
            dependencies: ["AudiouterCore", "AudiouterSettingsUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Offscreen PNG renderer for the onboarding window — see the product
        // comment above.
        .executableTarget(
            name: "onboarding-snapshot",
            dependencies: ["AudiouterCore", "AudiouterOnboardingUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Offscreen PNG renderer for the alignment-wizard window — see the
        // product comment above.
        .executableTarget(
            name: "wizard-snapshot",
            dependencies: ["AudiouterCore", "AudiouterPopoverUI", "AudiouterSharedUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Offscreen PNG renderer for the mixer window (group-creation design
        // review) — see the product comment in window-snapshot/main.swift.
        .executableTarget(
            name: "window-snapshot",
            // AudiouterPopoverUI + AudiouterSettingsUI: state 5 renders the
            // REAL one-surface host (toolbar header + shell), not a bare shell.
            dependencies: ["AudiouterCore", "AudiouterPopoverUI", "AudiouterSettingsUI",
                           "AudiouterWindowUI", "AudiouterSharedUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Silent read-only diagnostic for enumerating Core Audio process objects
        // and their associated PIDs and bundle IDs, useful for diagnosing per-app
        // audio routing issues (T7). Run with: AUDIOUTER_CORE_AUDIO_DIAGNOSTIC=1 swift run core-audio-diagnostic
        .executableTarget(
            name: "core-audio-diagnostic",
            dependencies: ["AudiouterCore"]
        ),
        // Tiny, short-lived TCC-preflight probe (T14) — see Sources/tcc-probe/main.swift
        // for the output contract `TCCProbeRunner` parses. Run directly with:
        // swift run tcc-probe   (reports the invoking TERMINAL's own TCC identity when
        // run this way — a format check only, not the real attribution test, which
        // needs the packaged .app to spawn it via TCCProbeRunner).
        .executableTarget(
            name: "tcc-probe"
        ),
        // T7 diagnostic (PLAN-FIREFOX-ROUTING-LEAK.md) — see the product
        // comment above. Only needs AppKit (`NSRunningApplication`) and
        // AudioToolbox; no dependency on AudiouterCore itself (it's a
        // standalone read-only probe, not exercising any app code path).
        .executableTarget(
            name: "process-audio-dump"
        ),
        .testTarget(
            name: "AudiouterCoreTests",
            dependencies: [
                "AudiouterCore",
                "AudiouterSharedUI",
                "AudiouterPopoverUI",
                "AudiouterWindowUI",
                "AudiouterSettingsUI",
                "AudiouterOnboardingUI",
            ],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
    ]
)
