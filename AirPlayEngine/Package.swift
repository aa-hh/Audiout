// swift-tools-version:5.10
import PackageDescription

// AirPlayEngine — a standalone SwiftPM package (PLAN-PHASE-2.md Q3(a),
// RESOLVED) that vendors + shims OwnTone's AirPlay 2 sender cluster into an
// engine we own and name neutrally (SPEC.md §4: zero OwnTone references in
// the shipped product). See docs/seam-map.md for the extraction blueprint
// this Package.swift follows, and README.md for the package-level status.
//
// STATUS (T-PKG-1 — scaffold only): this package defines the target/module
// layout and vendors the source files, but the C target does NOT compile
// yet. That's intentional — see the TODO markers below for where T-BUILD-1
// (make CAirPlayEngine compile + link) and T-SHIM-1 (implement the shim .c
// bodies) continue.
//
// ONE C TARGET, LICENSE-LABELED SUBDIRECTORIES (not one SwiftPM target per
// license). Rationale: GPL/MIT/BSD compliance rides on per-file license
// headers + the NOTICE file + legible subdirectory organization (see
// docs/license-inventory.md), not on SwiftPM target boundaries — and the
// vendored sources #include each other directly across those boundaries
// (e.g. airplay.c includes "evrtsp/evrtsp.h" and "pair_ap/pair.h" — see
// docs/seam-map.md §1), which a multi-target split would fight rather than
// help. Layout:
//   Sources/CAirPlayEngine/sender/      GPL-2.0-or-later (the sender core)
//   Sources/CAirPlayEngine/evrtsp/      BSD-3-Clause (Provos/Blaché)
//   Sources/CAirPlayEngine/pair_ap/     MIT (AirPlay 2 pairing)
//   Sources/CAirPlayEngine/libairptp/   MIT (PTP clock library)
//   Sources/CAirPlayEngine/shims/       GPL-2.0-or-later (new code we own)
//
// Platform: .macOS(.v14). Per T-PKG-1 instructions this matches the
// capture-side deployment target used elsewhere in this project's Phase-2
// planning; it is intentionally HIGHER than AudioutedCore's
// .macOS(.v13) (AudioutedCore/Package.swift) — that package's
// deployment target is NOT touched by this task. AudioutedCore
// depends on AirPlayEngine only via NativeBackend (T-BACKEND-1, later),
// at which point the core app's effective minimum OS follows this
// package's floor for that one backend.

import Foundation

// Brew include/lib paths. Homebrew installs these keg-only libs off the
// default clang search path, so the C target supplies explicit -I/-L flags.
//
// T-BUILD-1: resolve the brew prefix portably rather than hardcoding the
// Apple-Silicon path. Order: (1) $HOMEBREW_PREFIX if exported, (2) `brew
// --prefix`, (3) fall back to /opt/homebrew (arm64) or /usr/local (Intel).
// This makes the package build on both Apple-Silicon (/opt/homebrew) and
// Intel (/usr/local) brew layouts without editing Package.swift.
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
    // Static fallbacks per arch.
    if FileManager.default.fileExists(atPath: "/opt/homebrew") { return "/opt/homebrew" }
    return "/usr/local"
}

let brewPrefix = resolveBrewPrefix()

// The keg-only brew formulae the vendored cluster needs (seam-map §7 +
// Appendix A). Each contributes an -I<prefix>/opt/<name>/include and a
// matching -L for the linker.
let brewFormulae = [
    "libevent",       // event loop + evrtsp transport
    "libsodium",      // pair_ap crypto (always)
    "libgcrypt",      // airplay.c/rtp_common.c + pair_ap (CONFIG_GCRYPT)
    "libgpg-error",   // libgcrypt's own dependency
    "libplist",       // AirPlay plist RTSP payloads
    "ffmpeg",         // libavcodec ALAC encoder (T-SHIM-1; harmless to have -I now)
]

let brewIncludeFlags: [String] = brewFormulae.map { "-I\(brewPrefix)/opt/\($0)/include" }
let brewLibFlags: [String]     = brewFormulae.map { "-L\(brewPrefix)/opt/\($0)/lib" }

// The same include flags handed to the Swift target's clang importer via -Xcc,
// so `import CAirPlayEngine` can parse the umbrella header (which pulls in shim
// headers that #include <event2/event.h>, <plist/plist.h> etc.). Without this,
// the module builds for the C target but not for Swift consumers (T-API-1).
let swiftClangImporterFlags: [String] =
    brewIncludeFlags.flatMap { ["-Xcc", $0] }
    + ["-Xcc", "-I\(brewPrefix)/opt/libgpg-error/include"]

let package = Package(
    name: "AirPlayEngine",
    platforms: [.macOS(.v14)],
    products: [
        // The Swift-facing library the app (via NativeBackend, T-BACKEND-1)
        // and the probe CLI (T-CLI-1) link against.
        .library(name: "AirPlayEngine", targets: ["AirPlayEngine"]),
        // The gated one-device probe CLI (T-API-1). Builds green; it only
        // opens a real session when run with --i-have-a-receiver-and-owntone-is-stopped.
        .executable(name: "engine-probe", targets: ["engine-probe"]),
    ],
    targets: [
        // The vendored + shimmed C cluster — see header comment above for
        // why this is one target with license-labeled subdirectories
        // rather than one SwiftPM target per license.
        .target(
            name: "CAirPlayEngine",
            path: "Sources/CAirPlayEngine",
            exclude: [
                // Not a source file — SwiftPM would otherwise try to treat
                // it as one since it has no recognized extension to skip.
                "libairptp/LICENSE",
            ],
            sources: [
                "sender",
                "evrtsp",
                "pair_ap",
                "libairptp",
                "shims",
            ],
            publicHeadersPath: "include",
            cSettings: [
                // --- Header search paths so the vendored sources' relative
                // #includes resolve (e.g. airplay.c -> "evrtsp/evrtsp.h",
                // "pair_ap/pair.h", "rtp_common.h", and every shims/*.h).
                // "." (the CAirPlayEngine root) is needed for the
                // subdir-qualified includes like "evrtsp/evrtsp.h" and
                // "pair_ap/pair.h"; the per-subdir paths below are for the
                // bare-filename includes within each cluster (e.g.
                // rtp_common.c's own "rtp_common.h"). ---
                .headerSearchPath("."),
                .headerSearchPath("sender"),
                .headerSearchPath("evrtsp"),
                .headerSearchPath("pair_ap"),
                .headerSearchPath("libairptp"),
                .headerSearchPath("libairptp/src"),
                .headerSearchPath("shims"),
                // compat/ holds the hand-written config.h (replacing OwnTone's
                // autotools-generated one) and endian_compat.h (macOS
                // <libkern/OSByteOrder.h> mapping for glibc htobe*/be*toh).
                // Both are resolved by name via this search path (T-BUILD-1).
                .headerSearchPath("compat"),

                // --- Force-include the hand-written config.h into every
                // translation unit (T-BUILD-1). This mirrors what autotools
                // does (`-include config.h`) and is more robust than editing
                // each vendored .c to add the include: it guarantees
                // PACKAGE_NAME (airplay_events.c:218), HAVE_LIBKERN_OSBYTEORDER_H
                // (libairptp/src/utils.h endian branch), and HAVE_DECL_PLIST_NEW_INT
                // (plist_wrap.h) are defined everywhere they're read, without
                // touching the GPL/MIT vendored sources. Also defines
                // HAVE_CONFIG_H so the `#ifdef HAVE_CONFIG_H #include <config.h>`
                // guards in misc.h/utils.h/rtp_common.c activate cleanly. ---
                .unsafeFlags(["-include", "config.h", "-DHAVE_CONFIG_H"]),

                // --- pair_ap crypto backend selection (seam-map §7.3):
                // airplay.c + rtp_common.c already use libgcrypt directly,
                // so pair_ap is built with CONFIG_GCRYPT (+ libsodium
                // always), NOT CONFIG_OPENSSL. Avoids an openssl dep. ---
                .define("CONFIG_GCRYPT"),
                // libairptp per-packet tx/rx logging (log_sent/log_received are
                // compiled-out no-ops without these). Enabled for the gated
                // first-light bring-up (2026-07-16) to watch the PTP exchange;
                // cheap (E_DBG level) and gated by AIRPLAYENGINE_LOG_LEVEL at
                // runtime, so safe to leave on during bring-up.
                .define("AIRPTP_LOG_SENT", to: "1"),
                .define("AIRPTP_LOG_RECEIVED", to: "1"),

                // --- Brew include paths for the deps the cluster needs
                // (seam-map §7 + Appendix A): libevent, libsodium, libgcrypt
                // (+ its libgpg-error dep), libplist, and ffmpeg headers (for
                // the T-SHIM-1 ALAC encoder; harmless to include now). Prefix
                // is resolved portably (Apple Silicon /opt/homebrew OR Intel
                // /usr/local) at the top of this file. ---
                .unsafeFlags(brewIncludeFlags),
            ],
            linkerSettings: [
                // Brew lib search paths (portable prefix). T-BUILD-1 resolved
                // the link set below by driving the test-executable link and
                // clearing undefined symbols one by one. ffmpeg/avcodec is NOT
                // linked yet — shims/transcode.c is a link-only stub that
                // references no ffmpeg symbols (T-SHIM-1 adds avcodec/avutil/
                // swresample when it implements the real ALAC encoder).
                .unsafeFlags(brewLibFlags),
                .linkedLibrary("event"),
                // libevent's pthreads support lives in a separate library.
                // evthread_use_pthreads() (EngineThread) needs it so that
                // cross-thread event_base_once() wakes a kevent-blocked loop —
                // without it the engine's first live start() deadlocked
                // (gated first-light, 2026-07-16).
                .linkedLibrary("event_pthreads"),
                .linkedLibrary("sodium"),
                .linkedLibrary("gcrypt"),
                .linkedLibrary("gpg-error"),
                // libplist ships its dylib/pc as "plist-2.0" (confirmed via
                // `pkg-config --libs libplist-2.0` at T-BUILD-1).
                .linkedLibrary("plist-2.0"),
                // ffmpeg — the T-SHIM-2 ALAC encoder (Q2a "first light",
                // shims/transcode.c) links libavcodec (AV_CODEC_ID_ALAC),
                // libavutil (AVFrame / channel layout / sample fmt), and
                // libswresample (interleaved S16 -> planar S16P). TODO(seam-map
                // §5.3, R-C): drop these three once the uncompressed-ALAC swap
                // sheds ffmpeg.
                .linkedLibrary("avcodec"),
                .linkedLibrary("avutil"),
                .linkedLibrary("swresample"),
            ]
        ),

        // The neutral Swift wrapper (T-API-1 fills this in). SPEC.md §4:
        // no OwnTone naming in any public symbol here.
        .target(
            name: "AirPlayEngine",
            dependencies: ["CAirPlayEngine"],
            path: "Sources/AirPlayEngine",
            swiftSettings: [
                // Hand the brew include paths to the clang importer (via -Xcc)
                // so `import CAirPlayEngine` can parse the umbrella header,
                // which transitively #includes <event2/event.h>,
                // <plist/plist.h>, etc. A C target's cSettings .unsafeFlags do
                // NOT propagate to a dependent Swift target's module import, so
                // these must be restated here (T-BUILD-1).
                .unsafeFlags(swiftClangImporterFlags),
            ]
        ),

        // The probe CLI's argument grammar, split out of the executable so
        // the test target can import and unit-test it. Motivated by the
        // first gated multi-room run (2026-07-17), which was burned by an
        // untested parser footgun that silently split one device into two —
        // see Sources/EngineProbeParsing/ProbeArgParsing.swift. Pure Swift,
        // no C/engine dependency.
        .target(
            name: "EngineProbeParsing",
            path: "Sources/EngineProbeParsing"
        ),

        // The gated probe CLI (T-API-1). WOULD drive a one-device session
        // (parse device ip/port/name + a PCM file, start the engine, addOutput,
        // pump PCM), but is guarded behind an explicit
        // --i-have-a-receiver-and-owntone-is-stopped flag and is NOT run by this
        // task — it's the artifact for a later gated live session (real receiver,
        // OwnTone stopped for PTP 319/320, human present). See README.md.
        .executableTarget(
            name: "engine-probe",
            dependencies: ["AirPlayEngine", "EngineProbeParsing"],
            path: "Sources/engine-probe"
        ),

        .testTarget(
            name: "AirPlayEngineTests",
            dependencies: ["AirPlayEngine", "EngineProbeParsing"],
            path: "Tests/AirPlayEngineTests"
        ),
    ]
)
