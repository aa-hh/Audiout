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

// Platform floor: macOS 14.4, in the version-STRING form because `.v14` cannot
// express a minor. Two separate things set it, and they land on different
// numbers — the higher one wins.
//
// The link floor is macOS 14. AirPlayEngine (../AirPlayEngine/Package.swift)
// is .macOS(.v14) for its Core Audio process tap capture (T-NB-CAPTURE-1), and
// a SwiftPM package's platform floor cannot be lower than any local dependency
// it links: SwiftPM enforces the dependency's deployment target as a floor on
// any target depending on it, and fails to build or resolve otherwise. Keeping
// .v13 alive would mean fighting per-symbol `@available` annotations for code
// paths that never run on 13 anyway (NativeBackend is opt-in via
// AIRPLAY_BACKEND=native), so the whole package goes to 14. The
// mock/OwnTone-backed paths reference nothing gated above .v13 and are
// unaffected; this only tightens what the app links for and installs on.
//
// The real floor is 14.4, and it comes from the permission, not the API. The
// tap calls themselves are older: Apple's header annotates
// `AudioHardwareCreateProcessTap` `API_AVAILABLE(macos(14.2))`, so they
// compile and run on 14.2 and 14.3. But the app does not merely call the API,
// it reads consent for it through the private TCC framework, and 14.2/14.3
// file audio capture under different TCC categories than the
// `kTCCServiceAudioCapture` bucket `SystemAudioCaptureTCC` preflights. An
// absent bucket does not read as undetermined — per that type's own measured
// note, an unknown service name reads back as denied — so
// `AudioCapturePermissionProbe.runProbe()` short-circuits on `.denied` before
// the tone probe can recover. Below 14.4 a buyer would install, pay, and land
// on a Setup row pointing at a permission they cannot grant. Nothing here has
// ever been measured below 14.4.1, so that path is untested as well as
// unsupported, and 14.4 is what README, PRODUCT.md, docs/SPEC.md and the
// website all advertise. `scripts/make-app.sh` stamps the matching
// `LSMinimumSystemVersion`; keep the two in step.
let package = Package(
    name: "AudioutCore",
    platforms: [.macOS("14.4")],
    products: [
        // The core library the AppKit app links against. It knows nothing about
        // AppKit — it's the seam between "the UI" and "wherever audio actually goes."
        .library(name: "AudioutCore", targets: ["AudioutCore"]),
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
        // Opens the real first-open licence gate and nothing else — no
        // backend, no permissions, no network. The one surface a snapshot
        // tool CANNOT stand in for: its ground is a live Metal shader, and
        // Metal is off under `HeadlessRuntime`, so an offscreen render of this
        // window is a flat colour. Run: `swift run license-gate-preview`.
        .executable(name: "license-gate-preview", targets: ["license-gate-preview"]),
        // Silent read-only Core Audio diagnostic for enumerating process objects and
        // their PIDs/bundle IDs, useful for diagnosing per-app routing (T7).
        .executable(name: "core-audio-diagnostic", targets: ["core-audio-diagnostic"]),
        // Tiny, short-lived TCC-preflight probe (T14): `TCCProbeRunner` spawns this
        // fresh, on demand, to get an un-cached `TCCAccessPreflight` read — see
        // Sources/tcc-probe/main.swift for the full finding and output contract. No
        // dependency on AudioutCore by design: it must stay minimal, entitlement-free,
        // and fast to spawn.
        .executable(name: "tcc-probe", targets: ["tcc-probe"]),
        // The pure-AppKit menu-bar app. `swift build` produces a loose binary;
        // scripts/make-app.sh wraps it into a real double-clickable `.app`
        // (RESOLVED Q1 — SwiftPM executable + bundle script, no Xcode project).
        .executable(name: "AudioutApp", targets: ["AudioutApp"]),
        // T7 (PLAN-FIREFOX-ROUTING-LEAK.md): silent, no-audio diagnostic —
        // dumps every live Core Audio process object (pid, command, parent,
        // whether it independently resolves as an NSRunningApplication) so
        // the owner can confirm on their own machine whether a multi-process
        // browser's actual audio producer is a child process our single-PID
        // resolver can never find. Run: `swift run process-audio-dump`.
        .executable(name: "process-audio-dump", targets: ["process-audio-dump"]),
        // Roadmap 006 Phase 0: the hardware-free Google Cast sender spike —
        // browse, launch, stream, time it. Not linked by the app.
        .executable(name: "cast-spike", targets: ["cast-spike"]),
        // Mic-probe calibration hardware spike (roadmap 064): dual-sweep
        // playback + built-in-mic capture + matched filter, with the A2DP/HFP
        // survival check. Run from a terminal; never linked by the app.
        .executable(name: "mic-probe-spike", targets: ["mic-probe-spike"]),
    ],
    dependencies: [
        // The native AirPlay 2 sender engine (PLAN-PHASE-2b T-NB-PKGDEP-1).
        // Local path dependency, sibling package — NativeBackend
        // (T-NB-BACKEND-1) and NativeCaptureCoordinator (T-NB-CAPTURE-1) are
        // the consumers; the Mock/OwnTone backends do not import it.
        .package(path: "../AirPlayEngine"),
        // Shared code with the iPhone companion, three products: ProbeKit (the
        // sync-probe DSP — sweep synthesis and the matched filter behind
        // mic-probe calibration), AudioutProtocol (the companion wire
        // protocol — CompanionServer / CompanionSnapshotBuilder /
        // CompanionCommandDispatcher are the consumers) and AudioutField (the
        // emitter field's numbers, which the marketing site's shader reads
        // from the same file — `EmitterFieldView` is its consumer here). MIT,
        // so the closed-source iPhone companion can link the same code, and a
        // repository of its own because SwiftPM cannot depend on a package
        // that lives inside a subdirectory of another repo — and the phone
        // now lives in `aa-hh/audiout-remote`. Pinned by range: this app
        // chooses when to follow the shared package, and `Package.resolved`
        // records which tag it is actually on. 0.6.0 is the floor because
        // that is the tag `CompanionMessage.alignmentApplied` landed in, and
        // the companion server sends it on every applied measurement.
        .package(url: "https://github.com/aa-hh/audiout-shared.git", from: "0.8.1"),
        // Sparkle 2 (MIT) — in-app updates for the paid, notarised build only.
        // Scoped to the `AudioutApp` executable target so no library, test or
        // harness target ever links it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
        // PostHog product analytics SDK for the app lifecycle and UI.
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.59.3"),
    ],
    targets: [
        // Block-based Objective-C exception catcher. Swift's `catch` cannot
        // see NSException at all (AVFAudio's
        // play/scheduleBuffer/connect and NSThread.start raise it, not
        // NSError — a confirmed crash class here). This is the one
        // ObjC-language target allowed to @try/@catch; `AudioutCore`
        // wraps it in `catchingObjCException` for normal Swift call sites.
        .target(
            name: "ObjCExceptionShim"
        ),
        .target(
            name: "AudioutCore",
            dependencies: [
                .product(name: "AirPlayEngine", package: "AirPlayEngine"),
                .product(name: "ProbeKit", package: "audiout-shared"),
                .product(name: "AudioutProtocol", package: "audiout-shared"),
                "CastSender",
                "ObjCExceptionShim",
            ],
            swiftSettings: [
                .unsafeFlags(swiftClangImporterFlags),
            ]
        ),
        .executableTarget(
            name: "mock-speakers-demo",
            dependencies: ["AudioutCore"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // The shared `DeviceRowView` (SPEC §9 "Device row (shared by the popover
        // and the window)"). A library both `AudioutPopoverUI` and
        // `AudioutWindowUI` link, so the row is ONE implementation with
        // ONE test surface, correct in both hosts (it paints the menu highlight
        // only when parented in an `NSMenuItem`; in the popover/window it lets the
        // standard appearance show). It hosts the primary "send audio here" ON/OFF
        // switch + secondary mute. Talks only to `OutputBackend` / its
        // `Delegate` — no backend knowledge.
        .target(
            name: "AudioutSharedUI",
            dependencies: ["AudioutCore"],
            // `Resources/Symbols.xcassets` is EXCLUDED, not declared. SwiftPM
            // never runs `actool`, so a resource rule would copy the directory
            // in verbatim and every custom symbol would resolve to nil at
            // runtime with no build error to notice. `scripts/make-app.sh`
            // compiles it into `Contents/Resources/Assets.car` instead, beside
            // the wordmark font, and the app reads it through `Bundle.main`.
            exclude: ["Resources/Symbols.xcassets"],
            resources: [.copy("Resources/Audiout-Hero-1024.svg")],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // The pure-AppKit popover dropdown (SPEC §9 revised — NSMenu → NSPopover):
        // `PopoverController`, a Control-Center-style panel
        // hosted in an `NSPopover`. A *library* (not folded into the executable)
        // so both the app AND the headless `popover-harness` / tests can link it
        // and assert the built panel structure. Reuses the shared `DeviceRowView`.
        //
        // Since U3 (one-surface app) this target also hosts
        // `AppSurfaceController`, which composes ALL THREE screens — hence the
        // deps on AudioutWindowUI (Groups content) and AudioutSettingsUI
        // (Settings screen). One-directional on purpose: neither of those
        // targets may ever depend back on this one.
        .target(
            name: "AudioutPopoverUI",
            dependencies: ["AudioutCore", "AudioutSharedUI",
                           "AudioutWindowUI", "AudioutSettingsUI"],
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
            name: "AudioutWindowUI",
            dependencies: ["AudioutCore", "AudioutSharedUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // The pure-AppKit Settings content: a `SettingsRootViewController`
        // (an `NSTabViewController`, one pane per tab — General, Appearance, …)
        // hosted on the one-surface shell. A *library* so the app AND tests can
        // link it and assert the built structure, exactly like the popover/mixer
        // UI libs. Only needs Core (the `AppSettings` scalar store +
        // appearance/density enums) — no shared rows yet.
        .target(
            name: "AudioutSettingsUI",
            // AudioutSharedUI: the Tokens design-token layer (Wave 2 of the
            // Warm Signal redesign) — Settings styles through Tokens.* now.
            dependencies: ["AudioutCore", "AudioutSharedUI"],
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
            name: "AudioutOnboardingUI",
            // AudioutSharedUI: the Tokens design-token layer (Wave 2 of the
            // Warm Signal redesign) — onboarding styles through Tokens.* now.
            // AudioutField: the emitter field's shared numbers, which
            // `EmitterFieldView` generates its Metal shader from rather than
            // retyping them (the licence gate's ground).
            dependencies: [
                "AudioutCore", "AudioutSharedUI",
                .product(name: "AudioutField", package: "audiout-shared"),
            ],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Pure AppKit (SPEC §9). The app shell (status item, backend wiring,
        // lifecycle); the popover dropdown lives in AudioutPopoverUI,
        // the mixer window in AudioutWindowUI, the Settings window in
        // AudioutSettingsUI, the first-run onboarding in AudioutOnboardingUI.
        .executableTarget(
            name: "AudioutApp",
            dependencies: [
                "AudioutCore",
                "AudioutSharedUI",
                "AudioutPopoverUI",
                "AudioutWindowUI",
                "AudioutSettingsUI",
                "AudioutOnboardingUI",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "PostHog", package: "posthog-ios"),
            ],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Programmatic popover-structure verification for T-U6 (the popover isn't
        // visible to an agent shell) — see the product comment above.
        .executableTarget(
            name: "popover-harness",
            dependencies: ["AudioutCore", "AudioutPopoverUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Programmatic window-structure verification for T-U4 (the window isn't
        // visible to an agent shell) — see the product comment above.
        .executableTarget(
            name: "window-harness",
            dependencies: ["AudioutCore", "AudioutWindowUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Offscreen PNG renderer for the popover panel (layout overhaul visual
        // verification) — see the product comment above.
        .executableTarget(
            name: "popover-snapshot",
            dependencies: ["AudioutCore", "AudioutPopoverUI", "AudioutSharedUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Offscreen PNG renderer for the Settings window — see the product
        // comment above.
        .executableTarget(
            name: "settings-snapshot",
            dependencies: ["AudioutCore", "AudioutSettingsUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Offscreen PNG renderer for the onboarding window — see the product
        // comment above.
        .executableTarget(
            name: "onboarding-snapshot",
            dependencies: ["AudioutCore", "AudioutOnboardingUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Offscreen PNG renderer for the alignment-wizard window — see the
        // product comment above.
        .executableTarget(
            name: "wizard-snapshot",
            dependencies: ["AudioutCore", "AudioutPopoverUI", "AudioutSharedUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // On-screen preview of the licence gate — see the product comment
        // above.
        .executableTarget(
            name: "license-gate-preview",
            dependencies: ["AudioutCore", "AudioutOnboardingUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Offscreen PNG renderer for the mixer window (group-creation design
        // review) — see the product comment in window-snapshot/main.swift.
        .executableTarget(
            name: "window-snapshot",
            // AudioutPopoverUI + AudioutSettingsUI: state 5 renders the
            // REAL one-surface host (toolbar header + shell), not a bare shell.
            dependencies: ["AudioutCore", "AudioutPopoverUI", "AudioutSettingsUI",
                           "AudioutWindowUI", "AudioutSharedUI"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
        // Silent read-only diagnostic for enumerating Core Audio process objects
        // and their associated PIDs and bundle IDs, useful for diagnosing per-app
        // audio routing issues (T7). Run with: AUDIOUT_CORE_AUDIO_DIAGNOSTIC=1 swift run core-audio-diagnostic
        .executableTarget(
            name: "core-audio-diagnostic",
            dependencies: ["AudioutCore"]
        ),
        // Mic-probe hardware spike — see the product comment above.
        .executableTarget(
            name: "mic-probe-spike",
            dependencies: ["AudioutCore", .product(name: "ProbeKit", package: "audiout-shared")],
            // Info.plist is embedded into the Mach-O at link time (below), NOT
            // shipped as an SPM resource — exclude it so SPM stops warning.
            exclude: ["Info.plist"],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)],
            linkerSettings: [
                // A bare SwiftPM executable has no Info.plist, so
                // AVCaptureDevice.requestAccess has no NSMicrophoneUsageDescription
                // to show — and without one, macOS never surfaces the TCC prompt
                // at all (no crash, no dialog, no callback: exactly the silent
                // hang this tool hit live against a Sonos Move). Same
                // -sectcreate fix dev/audiocap uses for its own usage string.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/mic-probe-spike/Info.plist"
                ])
            ]
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
        // AudioToolbox; no dependency on AudioutCore itself (it's a
        // standalone read-only probe, not exercising any app code path).
        .executableTarget(
            name: "process-audio-dump"
        ),
        // Roadmap 006 Phase 0: the clean-room Google Cast (CASTV2) sender —
        // wire protocol, discovery, and the live-audio HTTP server. Not linked
        // by the app: Phase 1 wires it into NativeBackend behind a Device.Kind.
        // No dependency on AudioutCore or AirPlayEngine by design (hence no
        // Homebrew importer flags) — it is Foundation + Network + Security only.
        .target(
            name: "CastSender"
        ),
        // Roadmap 006 Phase 0: an in-process fake Cast receiver, so the whole
        // launch/load/play loop is exercised offline. Not linked by the app.
        .target(
            name: "CastFakeReceiver",
            dependencies: ["CastSender"]
        ),
        // Roadmap 006 Phase 0: the measurement CLI — see Sources/cast-spike.
        // Not linked by the app.
        .executableTarget(
            name: "cast-spike",
            dependencies: ["CastSender", "CastFakeReceiver"]
        ),
        .testTarget(
            name: "AudioutCoreTests",
            dependencies: [
                "AudioutCore",
                "AudioutSharedUI",
                "AudioutPopoverUI",
                "AudioutWindowUI",
                "AudioutSettingsUI",
                "AudioutOnboardingUI",
                "CastSender",
                "CastFakeReceiver",
                .product(name: "ProbeKit", package: "audiout-shared"),
                // EmitterFieldTests reads the same defaults the shader is
                // generated from, so a change to field.json fails a test here
                // instead of silently forking the brand's one moving image.
                .product(name: "AudioutField", package: "audiout-shared"),
            ],
            swiftSettings: [.unsafeFlags(swiftClangImporterFlags)]
        ),
    ]
)
