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
// planning; it is intentionally HIGHER than AudiouterCore's
// .macOS(.v13) (AudiouterCore/Package.swift) — that package's
// deployment target is NOT touched by this task. AudiouterCore
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
        // The privileged root PTP helper (T2, ptp-helper-design.md). Links
        // ONLY Clibairptp + libevent - never the GPL sender cluster - so the
        // one process that runs as root stays small enough to read
        // line-by-line (SPEC.md §4.1). A future SMAppService launchd daemon
        // bundles this binary; today it is built + link-tested here and run
        // manually via AUDIOUTER_PTP_PORTS for the unprivileged IPC path.
        .executable(name: "ptp-helper", targets: ["ptp-helper"]),
    ],
    targets: [
        // The MIT PTP clock library, split into its OWN target (T1,
        // ptp-helper-design.md) so a future root SMAppService helper can
        // link ONLY this + libevent — never the GPL sender cluster
        // (ffmpeg/libplist/libgcrypt/RTSP/ALAC). This is the security
        // linchpin: the code that runs privileged must be small enough to
        // read line-by-line. Deliberately NOT relocated on disk — "path"
        // points at the existing Sources/CAirPlayEngine/libairptp
        // directory so libairptp/airptp.h's physical location, and every
        // existing `#include "libairptp/airptp.h"` (shims/ptpd.c), keep
        // resolving unchanged; only the SwiftPM target boundary and the
        // compiled-sources list ("src" only) are new.
        .target(
            name: "Clibairptp",
            path: "Sources/CAirPlayEngine/libairptp",
            exclude: [
                // Not a source file — SwiftPM would otherwise try to treat
                // it as one since it has no recognized extension to skip.
                "LICENSE",
            ],
            sources: [
                "src",
            ],
            // publicHeadersPath "." exposes airptp.h (this target's root)
            // to CAirPlayEngine automatically once it depends on this
            // target, without widening the C-target-boundary of the
            // umbrella header to also include the private src/ headers.
            publicHeadersPath: ".",
            cSettings: [
                // "." (this target's root) resolves airptp_internal.h's
                // own "../airptp.h"; "src" is redundant with same-directory
                // relative includes within libairptp/src/*.c but kept for
                // parity with how CAirPlayEngine listed it before the split.
                .headerSearchPath("."),
                .headerSearchPath("src"),
                // compat/ (config.h + endian_compat.h) stays put as a
                // CAirPlayEngine-level shared resource — both this target
                // and the sender cluster force-include the same config.h.
                // Reached via a relative path across the (sibling) target
                // boundary since the file itself did not move.
                .headerSearchPath("../compat"),

                // --- Force-include the hand-written config.h (same as
                // CAirPlayEngine): guarantees HAVE_LIBKERN_OSBYTEORDER_H
                // (libairptp/src/utils.h endian branch) and HAVE_CONFIG_H
                // (the `#ifdef HAVE_CONFIG_H #include <config.h>` guard in
                // utils.h) are defined here too, without touching the MIT
                // vendored sources. ---
                .unsafeFlags(["-include", "config.h", "-DHAVE_CONFIG_H"]),

                // libairptp per-packet tx/rx logging (log_sent/log_received
                // are compiled-out no-ops without these). Enabled for the
                // gated first-light bring-up (2026-07-16) to watch the PTP
                // exchange; cheap (E_DBG level) and gated by
                // AIRPLAYENGINE_LOG_LEVEL at runtime, so safe to leave on.
                .define("AIRPTP_LOG_SENT", to: "1"),
                .define("AIRPTP_LOG_RECEIVED", to: "1"),

                // libevent headers (airptp_internal.h: <event2/event.h>).
                // Portable brew prefix resolved at the top of this file.
                .unsafeFlags(["-I\(brewPrefix)/opt/libevent/include"]),
            ],
            // NO libevent linkerSettings here on purpose. Clibairptp is a
            // static-library target — it does not resolve its own external
            // symbols; each final executable that links it does. Keeping the
            // libevent link OUT of this shared target is what lets its two
            // consumers link libevent DIFFERENTLY: CAirPlayEngine (the app
            // path) links the Homebrew libevent *dylib* (its own linkerSettings
            // below), while ptp-helper *statically* links libevent_core.a +
            // libevent_pthreads.a. The helper must static-link because it is a
            // hardened-runtime Developer-ID root daemon with Library Validation
            // ON (no disable-library-validation entitlement, unlike the app):
            // dyld refuses to load the ad-hoc-signed Homebrew libevent *dylib*
            // into it ("different Team IDs"), which crashed the launchd daemon
            // at load time (OS_REASON_DYLD) — found in the first Developer-ID
            // live test, 2026-07-21. Static-linking removes the runtime dylib
            // dependency entirely, so there is nothing external to validate.
            linkerSettings: []
        ),

        // The vendored + shimmed C cluster — see header comment above for
        // why this is one target with license-labeled subdirectories
        // rather than one SwiftPM target per license.
        .target(
            name: "CAirPlayEngine",
            dependencies: ["Clibairptp"],
            path: "Sources/CAirPlayEngine",
            exclude: [
                // Not a source file — SwiftPM would otherwise try to treat
                // it as one since it has no recognized extension to skip.
                // Still listed here (rather than only under Clibairptp)
                // because this target's path is the CAirPlayEngine root,
                // which contains the whole libairptp/ subtree on disk.
                "libairptp/LICENSE",
            ],
            sources: [
                "sender",
                "evrtsp",
                "pair_ap",
                // libairptp/src/* now compiles exactly once, in the
                // Clibairptp target above (T1, ptp-helper-design.md).
                // libairptp/airptp.h itself is still reached from here via
                // the "." header search path below, unchanged.
                "shims",
            ],
            publicHeadersPath: "include",
            cSettings: [
                // --- Header search paths so the vendored sources' relative
                // #includes resolve (e.g. airplay.c -> "evrtsp/evrtsp.h",
                // "pair_ap/pair.h", "rtp_common.h", and every shims/*.h).
                // "." (the CAirPlayEngine root) is needed for the
                // subdir-qualified includes like "evrtsp/evrtsp.h",
                // "pair_ap/pair.h", and shims/ptpd.c's own
                // "libairptp/airptp.h"; the per-subdir paths below are for
                // the bare-filename includes within each cluster (e.g.
                // rtp_common.c's own "rtp_common.h"). ---
                .headerSearchPath("."),
                .headerSearchPath("sender"),
                .headerSearchPath("evrtsp"),
                .headerSearchPath("pair_ap"),
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
                // PACKAGE_NAME (airplay_events.c:218) and
                // HAVE_DECL_PLIST_NEW_INT (plist_wrap.h) are defined
                // everywhere they're read, without touching the GPL/MIT
                // vendored sources. Also defines HAVE_CONFIG_H so the
                // `#ifdef HAVE_CONFIG_H #include <config.h>` guards in
                // misc.h/rtp_common.c activate cleanly. ---
                .unsafeFlags(["-include", "config.h", "-DHAVE_CONFIG_H"]),

                // --- pair_ap crypto backend selection (seam-map §7.3):
                // airplay.c + rtp_common.c already use libgcrypt directly,
                // so pair_ap is built with CONFIG_GCRYPT (+ libsodium
                // always), NOT CONFIG_OPENSSL. Avoids an openssl dep. ---
                .define("CONFIG_GCRYPT"),

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

        // The privileged root PTP helper's executable (T2,
        // ptp-helper-design.md §0/§1/§6.1). Depends ONLY on Clibairptp (+
        // libevent, via that target's own linker settings) - deliberately
        // NOT on CAirPlayEngine, so the GPL sender cluster (RTSP/ALAC/
        // pairing/ffmpeg/libplist/libgcrypt) never links into the one binary
        // that runs as root. No extra cSettings needed: airptp.h is a public,
        // config.h-independent header (just <inttypes.h> + a `bool`),
        // reached by bare name via Clibairptp's own publicHeadersPath "."
        // (libairptp/module.modulemap), which SwiftPM adds automatically for
        // a dependent target.
        .executableTarget(
            name: "ptp-helper",
            dependencies: ["Clibairptp"],
            path: "Sources/ptp-helper",
            linkerSettings: [
                // STATIC-link libevent into the root daemon (see the long note
                // on Clibairptp's empty linkerSettings above). Passing the .a
                // archive paths directly to the linker links them statically,
                // so the shipped helper has NO libevent dylib dependency —
                // `otool -L` shows only libSystem — and Library Validation on
                // the hardened Developer-ID daemon has nothing external to
                // reject. libevent_core.a = the event loop; libevent_pthreads.a
                // = evthread_use_pthreads() (needed so cross-thread
                // event_base_once() wakes the kevent-blocked master loop).
                .unsafeFlags([
                    "\(brewPrefix)/opt/libevent/lib/libevent_core.a",
                    "\(brewPrefix)/opt/libevent/lib/libevent_pthreads.a",
                ]),
            ]
        ),

        // TEST-ONLY shim (T7, ptp-helper-design.md §6.2): re-exposes
        // Clibairptp's airptp_* API to Swift. Needed because
        // Clibairptp/module.modulemap declares airptp.h as a `textual
        // header` (opts the vendored header out of Clang's modular
        // self-containment check — see that file's comment), and a
        // textual header is invisible to a Swift `import`. This target's
        // OWN public header is a normal, self-contained modular header
        // that just forwards to airptp_*, so PTPHelperIPCTests can drive
        // the real bind/start/find/peer calls without touching the
        // vendored module map. See Sources/PTPHelperTestSupport/include/
        // ptp_test_support.h for the full rationale.
        .target(
            name: "PTPHelperTestSupport",
            dependencies: ["Clibairptp"],
            path: "Sources/PTPHelperTestSupport",
            publicHeadersPath: "include"
        ),

        .testTarget(
            name: "AirPlayEngineTests",
            dependencies: ["AirPlayEngine", "EngineProbeParsing", "PTPHelperTestSupport"],
            path: "Tests/AirPlayEngineTests"
        ),
    ]
)
