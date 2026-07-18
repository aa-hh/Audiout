// swift-tools-version:5.10
import PackageDescription

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
    name: "AudioutedCore",
    platforms: [.macOS(.v14)],
    products: [
        // The core library the AppKit app links against. It knows nothing about
        // AppKit — it's the seam between "the UI" and "wherever audio actually goes."
        .library(name: "AudioutedCore", targets: ["AudioutedCore"]),
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
        // The pure-AppKit menu-bar app. `swift build` produces a loose binary;
        // scripts/make-app.sh wraps it into a real double-clickable `.app`
        // (RESOLVED Q1 — SwiftPM executable + bundle script, no Xcode project).
        .executable(name: "AudioutedApp", targets: ["AudioutedApp"]),
    ],
    dependencies: [
        // The native AirPlay 2 sender engine (PLAN-PHASE-2b T-NB-PKGDEP-1).
        // Local path dependency, sibling package — NativeBackend
        // (T-NB-BACKEND-1) and NativeCaptureCoordinator (T-NB-CAPTURE-1) are
        // the consumers; the Mock/OwnTone backends do not import it.
        .package(path: "../AirPlayEngine"),
    ],
    targets: [
        .target(
            name: "AudioutedCore",
            dependencies: [
                .product(name: "AirPlayEngine", package: "AirPlayEngine"),
            ]
        ),
        .executableTarget(
            name: "mock-speakers-demo",
            dependencies: ["AudioutedCore"]
        ),
        // The shared `DeviceRowView` (SPEC §9 "Device row (shared by the popover
        // and the window)"). A library both `AudioutedPopoverUI` and
        // `AudioutedWindowUI` link, so the row is ONE implementation with
        // ONE test surface, correct in both hosts (it paints the menu highlight
        // only when parented in an `NSMenuItem`; in the popover/window it lets the
        // standard appearance show). It hosts the primary "send audio here" ON/OFF
        // switch + secondary mute. Talks only to `OutputBackend` / its
        // `Delegate` — no backend knowledge.
        .target(
            name: "AudioutedSharedUI",
            dependencies: ["AudioutedCore"]
        ),
        // The pure-AppKit popover dropdown (SPEC §9 revised — NSMenu → NSPopover):
        // `PopoverController` + `GroupRowView`, a Control-Center-style panel
        // hosted in an `NSPopover`. A *library* (not folded into the executable)
        // so both the app AND the headless `popover-harness` / tests can link it
        // and assert the built panel structure. Reuses the shared `DeviceRowView`.
        .target(
            name: "AudioutedPopoverUI",
            dependencies: ["AudioutedCore", "AudioutedSharedUI"]
        ),
        // The pure-AppKit mixer window (SPEC §9 "Full window"): a
        // `MixerWindowController` hosting an `NSSplitViewController` (source-list
        // `NSOutlineView` sidebar + `NSStackView` mixer), a `.unified` `NSToolbar`
        // with a master `NSSlider` + presets `NSPopUpButton`, and the group
        // editor (rename / membership checkboxes / delete). A *library* so the
        // app AND the headless `window-harness` / tests can link it and assert
        // the built window structure. Reuses the shared `DeviceRowView`.
        .target(
            name: "AudioutedWindowUI",
            dependencies: ["AudioutedCore", "AudioutedSharedUI"]
        ),
        // The pure-AppKit Settings window (the header gear's destination): a
        // `SettingsWindowController` hosting a `.toolbar`-style
        // `NSTabViewController`, one pane per tab (General, Appearance, …). A
        // *library* so the app AND tests can link it and assert the built window
        // structure, exactly like the popover/mixer UI libs. Only needs Core (the
        // `AppSettings` scalar store + appearance/density enums) — no shared rows
        // yet.
        .target(
            name: "AudioutedSettingsUI",
            dependencies: ["AudioutedCore"]
        ),
        // Pure AppKit (SPEC §9). The app shell (status item, backend wiring,
        // lifecycle); the popover dropdown lives in AudioutedPopoverUI,
        // the mixer window in AudioutedWindowUI, the Settings window in
        // AudioutedSettingsUI.
        .executableTarget(
            name: "AudioutedApp",
            dependencies: [
                "AudioutedCore",
                "AudioutedPopoverUI",
                "AudioutedWindowUI",
                "AudioutedSettingsUI",
            ]
        ),
        // Programmatic popover-structure verification for T-U6 (the popover isn't
        // visible to an agent shell) — see the product comment above.
        .executableTarget(
            name: "popover-harness",
            dependencies: ["AudioutedCore", "AudioutedPopoverUI"]
        ),
        // Programmatic window-structure verification for T-U4 (the window isn't
        // visible to an agent shell) — see the product comment above.
        .executableTarget(
            name: "window-harness",
            dependencies: ["AudioutedCore", "AudioutedWindowUI"]
        ),
        // Offscreen PNG renderer for the popover panel (layout overhaul visual
        // verification) — see the product comment above.
        .executableTarget(
            name: "popover-snapshot",
            dependencies: ["AudioutedCore", "AudioutedPopoverUI", "AudioutedSharedUI"]
        ),
        // Offscreen PNG renderer for the Settings window — see the product
        // comment above.
        .executableTarget(
            name: "settings-snapshot",
            dependencies: ["AudioutedCore", "AudioutedSettingsUI"]
        ),
        .testTarget(
            name: "AudioutedCoreTests",
            dependencies: [
                "AudioutedCore",
                "AudioutedSharedUI",
                "AudioutedPopoverUI",
                "AudioutedWindowUI",
                "AudioutedSettingsUI",
            ]
        ),
    ]
)
