// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Darwin

#if canImport(CoreAudio)
import CoreAudio
#endif

/// Resolves a bundle identifier to the FULL set of live Core Audio process
/// objects that belong to it — the main process AND every child/helper
/// (media/RDD/utility) process a multi-process browser (Firefox, Chrome)
/// actually emits audio from.
///
/// ## Why this exists
/// A multi-process browser plays audio from a CHILD process whose pid differs
/// from the main app's, and Core Audio reports NO bundle id of its own for that
/// child. Resolving a bundle id to a single pid (the old
/// `NSRunningApplication...first?.processIdentifier` path) therefore names the
/// SILENT main process: the per-app capture taps nothing, and the whole-system
/// tap's exclusion misses the real audio child, so the routed app leaks into the
/// system mix. This primitive returns every process object the bundle owns so a
/// consumer can tap or exclude all of them.
///
/// ## Consumers (wired in the two coordinators, not here)
/// Both consumers ultimately feed a `CATapDescription` that takes
/// `[AudioObjectID]`:
/// - the per-app capture path (`PerAppCaptureCoordinator`) builds a
///   `stereoMixdownOfProcesses:` from these object ids, and
/// - the whole-system exclusion path (`NativeCaptureCoordinator`) builds a
///   `stereoGlobalTapButExcludeProcesses:` from them.
/// So the resolved value carries `AudioObjectID` (the object each consumer
/// hands to Core Audio); the pid rides along for logging/diagnostics.
///
/// ## Diagnosability (T2)
/// The catch-all fix above closed the leak but left no record of WHICH layer
/// actually attributed a given process — the 2026-07-26 live diagnosis had to
/// manually correlate `ps` against telemetry that showed only exclusion
/// INTENT (bundle ids), never the resolved processes or how they matched.
/// ``resolveWithAttribution(bundleID:)`` is the same resolution as
/// ``resolve(bundleID:)`` with that detail attached per process
/// (``AttributedProcess.layer``); both coordinators log it at their
/// resolution choke points via `Telemetry`.
///
/// ## Empty set is a valid, non-error result
/// If no process object resolves to the bundle id — the app isn't running, or
/// hasn't opened an audio stream yet — this returns an EMPTY set, never an
/// error. A caller distinguishes "no processes yet" (retryable, the
/// `.processNotYetAudible` situation) from a genuine failure by that emptiness.
///
/// ## Catch-all attribution — FOUR layers, ANY-of, no per-app knowledge
/// Proven live 2026-07-26: Spotify plays from "Spotify Helper" processes that
/// macOS has REPARENTED to launchd (pid 953, ppid **1**), and that report a
/// bundle id of their OWN (`com.spotify.client.helper`). Both of the original
/// layers therefore missed them — the parent walk dies instantly at `ppid == 1`,
/// and the own-bundle id is present but !=  `com.spotify.client`. Net effect: an
/// app marked as a routing exception still leaked into the whole-system mix.
/// Same class as the earlier Firefox multi-process leak, but the parent walk
/// alone cannot cover it.
///
/// A process object now matches target bundle id X when **ANY** of these holds
/// (evaluated cheapest-first, but semantically an ANY-of union — a helper's own
/// distinct bundle id must NOT short-circuit and mask the later layers, which is
/// exactly how the Spotify case escaped):
/// 1. its own reported bundle id == X;
/// 2. **responsibility** — the bundle id of its *responsible process* == X.
///    That's the same attribution macOS TCC uses to blame a helper on its app,
///    read through the private-but-stable libsystem symbol
///    `responsibility_get_pid_responsible_for_pid`, resolved defensively via
///    `dlsym` (the in-repo precedent is `SystemAudioCaptureTCC.preflight`). It
///    answered 953 → 739 (Spotify) live where the parent walk answered nothing.
///    Unavailable symbol / non-positive answer / the pid itself ⇒ this layer
///    contributes nothing, never a crash;
/// 3. **bundle-path containment** — a public-API fallback that independently
///    catches the same class: the process's executable path lies inside the
///    target app's bundle directory. Component-safe, so `/Applications/Spotify.app`
///    never swallows `/Applications/Spotify.app 2/…`;
/// 4. the original parent-pid walk, unchanged, still gated on the process
///    reporting no bundle id of its own — the last resort, and deliberately NOT
///    widened to own-bundle'd processes (a shell-launched app would otherwise be
///    attributed to Terminal).
///
/// ## AppKit stays out of Core
/// Mapping a bare pid to a bundle id — and a bundle id to its on-disk bundle
/// path — needs `NSRunningApplication`/`NSWorkspace`, which live in AppKit, a
/// framework `AudiouterCore` must never import. Those two steps are injected
/// closures (`bundleIDForPID`, `bundlePathForBundleID`), supplied by an
/// AppKit-importing layer, exactly as
/// `PerAppCaptureCoordinator`/`NativeCaptureCoordinator` inject `resolvePID`.
/// Everything else (enumerating process objects, reading their pid/bundle id,
/// walking parent pids, reading responsible pids and executable paths via
/// libproc/libsystem) is pure Core Audio + Darwin and lives here.
public struct AudioProcessResolver: Sendable {

    /// The HAL/Darwin seam: enumerate process objects and walk parent pids.
    /// Injectable so the pure resolution logic can be unit-tested without live
    /// Core Audio.
    private let enumerator: AudioProcessEnumerating

    /// The AppKit-supplied pid → bundle-id resolver (`NSRunningApplication`).
    /// Defaults to always-nil so Core-only callers still compile and run; an
    /// AppKit layer supplies the real closure. Without it, a child process
    /// whose parent has no Core Audio process object of its own cannot be
    /// attributed — the very Firefox case this primitive exists for — so the
    /// real closure is not optional in practice.
    private let bundleIDForPID: @Sendable (pid_t) -> String?

    /// Layer 2's seam: pid → the pid macOS holds *responsible* for it. Defaults
    /// to the real `responsibility_get_pid_responsible_for_pid` read, which is
    /// pure libsystem (no AppKit), so production needs no injection; tests
    /// script it. Returns nil when the symbol is unresolvable or the answer
    /// carries no information — see ``responsiblePID(of:)``.
    private let responsiblePID: @Sendable (pid_t) -> pid_t?

    /// Layer 3's first seam: pid → its executable's absolute path. Defaults to
    /// the real `proc_pidpath` — libproc, same layer as the existing parent-pid
    /// read, so again no injection needed in production.
    private let executablePath: @Sendable (pid_t) -> String?

    /// Layer 3's second seam: bundle id → that app's on-disk `.app` directory.
    /// The ONLY genuinely AppKit-bound step of the new layers
    /// (`NSWorkspace.urlForApplication(withBundleIdentifier:)`), so it defaults
    /// to always-nil — layer 3 simply contributes nothing — and the
    /// AppKit-importing layer (`AppDelegate`) supplies the real closure, exactly
    /// as it already does for ``bundleIDForPID``.
    private let bundlePathForBundleID: @Sendable (String) -> String?

    /// How many parent-pid hops to follow before giving up attributing a
    /// nil-bundle-id process. Capped so a pathological/cyclic chain can never
    /// loop; a browser helper sits one or two hops under its main process.
    private let maxParentHops: Int

    public init(
        enumerator: AudioProcessEnumerating,
        bundleIDForPID: @escaping @Sendable (pid_t) -> String? = { _ in nil },
        // `nil` (the default) means "use the real Darwin read below" — the
        // production wiring for these two layers needs no injection at all. It
        // cannot be spelled as a default closure expression because the real
        // reads are private, and a public initializer's default argument may
        // only name public API; tests pass their own closure explicitly.
        responsiblePID: (@Sendable (pid_t) -> pid_t?)? = nil,
        executablePath: (@Sendable (pid_t) -> String?)? = nil,
        bundlePathForBundleID: @escaping @Sendable (String) -> String? = { _ in nil },
        maxParentHops: Int = 5
    ) {
        self.enumerator = enumerator
        self.bundleIDForPID = bundleIDForPID
        self.responsiblePID = responsiblePID ?? { Self.responsiblePID(of: $0) }
        self.executablePath = executablePath ?? { Self.executablePath(of: $0) }
        self.bundlePathForBundleID = bundlePathForBundleID
        self.maxParentHops = maxParentHops
    }

    /// Every live Core Audio process object whose owning app resolves to
    /// `bundleID` — the main process plus any child/helper processes. Empty if
    /// none match (not running yet, or not yet audible); never throws.
    public func resolve(bundleID: String) -> Set<AudioProcess> {
        Self.resolve(
            bundleID: bundleID,
            processes: enumerator.enumerateProcesses(),
            parentPID: enumerator.parentPID(of:),
            bundleIDForPID: bundleIDForPID,
            responsiblePID: responsiblePID,
            executablePath: executablePath,
            bundlePathForBundleID: bundlePathForBundleID,
            maxParentHops: maxParentHops)
    }

    /// T2 diagnostic surface: same resolution as ``resolve(bundleID:)``, but
    /// each returned process also carries WHICH of the four attribution layers
    /// matched it. Exists because a live leak (2026-07-26, catch-all
    /// attribution) could only be diagnosed by manually correlating `ps`
    /// against telemetry that showed exclusion INTENT (`exclusion_changed`'s
    /// bundle-id list) but never which concrete processes an excluded bundle
    /// id actually resolved to, nor how. Never changes WHICH processes match —
    /// that stays the ANY-of union ``resolve(bundleID:)`` computes — this only
    /// reports, per process, the cheapest layer that fired (see
    /// ``matchingLayer(process:target:pidToOwnBundle:parentPID:bundleIDForPID:responsiblePID:executablePath:targetBundlePath:maxParentHops:)``).
    public func resolveWithAttribution(bundleID: String) -> Set<AttributedProcess> {
        Self.resolveWithAttribution(
            bundleID: bundleID,
            processes: enumerator.enumerateProcesses(),
            parentPID: enumerator.parentPID(of:),
            bundleIDForPID: bundleIDForPID,
            responsiblePID: responsiblePID,
            executablePath: executablePath,
            bundlePathForBundleID: bundlePathForBundleID,
            maxParentHops: maxParentHops)
    }

    /// The Core Audio process object(s) for an EXACT pid — no bundle id, no
    /// parent-chain walk. Used to self-exclude a process we already identify by
    /// pid directly (the synced local sink's own in-process `AVAudioEngine`
    /// render, T-FANOUT), rather than by bundle attribution. Normally a single
    /// object per pid; a `Set` in case Core Audio ever reports more than one.
    public func resolve(pid target: pid_t) -> Set<AudioProcess> {
        Set(enumerator.enumerateProcesses()
            .filter { $0.pid == target }
            .map { AudioProcess(objectID: $0.objectID, pid: $0.pid) })
    }

    // MARK: - Pure resolution logic (no Core Audio, no AppKit — unit-tested directly)

    /// Compute the resolved set from already-enumerated raw process data.
    /// Split out from the HAL call so it can be tested with plain arrays and
    /// closures. A process object matches `bundleID` when ANY of the four
    /// attribution layers documented on the type matches — own bundle id,
    /// responsible process, bundle-path containment, parent-pid walk. The
    /// layers are tried cheapest-first purely as an optimisation; a failure on
    /// one NEVER decides the answer, which is the whole point of the catch-all
    /// fix (a Spotify helper's own `…client.helper` bundle id used to
    /// short-circuit the match to "no" and the exception leaked).
    static func resolve(
        bundleID target: String,
        processes: [RawAudioProcess],
        parentPID: (pid_t) -> pid_t?,
        bundleIDForPID: (pid_t) -> String?,
        responsiblePID: (pid_t) -> pid_t? = { _ in nil },
        executablePath: (pid_t) -> String? = { _ in nil },
        bundlePathForBundleID: (String) -> String? = { _ in nil },
        maxParentHops: Int
    ) -> Set<AudioProcess> {
        Set(resolveWithAttribution(
            bundleID: target,
            processes: processes,
            parentPID: parentPID,
            bundleIDForPID: bundleIDForPID,
            responsiblePID: responsiblePID,
            executablePath: executablePath,
            bundlePathForBundleID: bundlePathForBundleID,
            maxParentHops: maxParentHops
        ).map(\.process))
    }

    /// T2: the same ANY-of resolution as ``resolve(bundleID:processes:parentPID:bundleIDForPID:responsiblePID:executablePath:bundlePathForBundleID:maxParentHops:)``,
    /// except each match also carries the ``AttributionLayer`` that fired —
    /// `resolve` is now expressed in terms of this (map away `.layer`) so the
    /// two entry points can never disagree on which processes match.
    static func resolveWithAttribution(
        bundleID target: String,
        processes: [RawAudioProcess],
        parentPID: (pid_t) -> pid_t?,
        bundleIDForPID: (pid_t) -> String?,
        responsiblePID: (pid_t) -> pid_t? = { _ in nil },
        executablePath: (pid_t) -> String? = { _ in nil },
        bundlePathForBundleID: (String) -> String? = { _ in nil },
        maxParentHops: Int
    ) -> Set<AttributedProcess> {
        // pid → bundle id for every process that reports one of its own, so the
        // responsibility and parent-walk layers can resolve a pid without AppKit
        // when that pid is itself in the audio process list.
        var pidToOwnBundle: [pid_t: String] = [:]
        for process in processes {
            if let bundle = process.bundleID, !bundle.isEmpty {
                pidToOwnBundle[process.pid] = bundle
            }
        }

        // Resolved once, not per process: the target's `.app` directory, used by
        // layer 3. Absent (no AppKit closure injected, app not installed) simply
        // disables that layer.
        let targetBundlePath = bundlePathForBundleID(target)

        var resolved: Set<AttributedProcess> = []
        for process in processes {
            guard let layer = matchingLayer(
                process: process,
                target: target,
                pidToOwnBundle: pidToOwnBundle,
                parentPID: parentPID,
                bundleIDForPID: bundleIDForPID,
                responsiblePID: responsiblePID,
                executablePath: executablePath,
                targetBundlePath: targetBundlePath,
                maxParentHops: maxParentHops
            ) else { continue }
            resolved.insert(AttributedProcess(
                process: AudioProcess(objectID: process.objectID, pid: process.pid),
                layer: layer))
        }
        return resolved
    }

    /// The first (cheapest) of the four attribution layers that matches
    /// `process` against `target`, or nil if none does. ANY-of, not
    /// first-non-nil-wins — evaluation order here is purely an optimisation
    /// (see the type's doc comment); which layer is *reported* when several
    /// would independently match is therefore an implementation detail, never
    /// something a caller should branch on.
    private static func matchingLayer(
        process: RawAudioProcess,
        target: String,
        pidToOwnBundle: [pid_t: String],
        parentPID: (pid_t) -> pid_t?,
        bundleIDForPID: (pid_t) -> String?,
        responsiblePID: (pid_t) -> pid_t?,
        executablePath: (pid_t) -> String?,
        targetBundlePath: String?,
        maxParentHops: Int
    ) -> AttributionLayer? {
        // Layer 1 — the process reports the target's bundle id itself.
        if isTarget(process.bundleID, target) { return .own }
        // Layer 2 — responsibility: what TCC would blame this pid on.
        if isTarget(
            responsibleBundleID(
                pid: process.pid,
                pidToOwnBundle: pidToOwnBundle,
                responsiblePID: responsiblePID,
                bundleIDForPID: bundleIDForPID),
            target) { return .responsible }
        // Layer 3 — the executable lives inside the target's bundle.
        if isInside(bundlePath: targetBundlePath, executablePath: executablePath(process.pid)) { return .bundlePath }
        // Layer 4 — parent walk, only for a process with no bundle id of its
        // own (see the type's doc comment for why it stays gated).
        if isTarget(
            inheritedBundleID(
                ownBundleID: process.bundleID,
                pid: process.pid,
                pidToOwnBundle: pidToOwnBundle,
                parentPID: parentPID,
                bundleIDForPID: bundleIDForPID,
                maxParentHops: maxParentHops),
            target) { return .parentWalk }
        return nil
    }

    /// A layer matches only on a non-empty, exactly-equal bundle id — an empty
    /// string is "no answer", never a match against an (equally empty) target.
    private static func isTarget(_ candidate: String?, _ target: String) -> Bool {
        guard let candidate, !candidate.isEmpty else { return false }
        return candidate == target
    }

    /// Layer 2: the bundle id of `pid`'s *responsible process*, mapped through
    /// the SAME seams every other layer uses (a sibling audio process object's
    /// own bundle id first, then the injected AppKit closure). A responsible pid
    /// that is absent, non-positive, or the process itself carries no
    /// information about a parent app, so it yields nil.
    private static func responsibleBundleID(
        pid: pid_t,
        pidToOwnBundle: [pid_t: String],
        responsiblePID: (pid_t) -> pid_t?,
        bundleIDForPID: (pid_t) -> String?
    ) -> String? {
        guard let responsible = responsiblePID(pid), responsible > 0, responsible != pid else {
            return nil
        }
        if let bundle = pidToOwnBundle[responsible], !bundle.isEmpty { return bundle }
        return bundleIDForPID(responsible)
    }

    /// Layer 3: is `executablePath` inside the `.app` directory `bundlePath`?
    /// Compared component-wise, not as a naive string prefix, so
    /// `/Applications/Spotify.app` cannot claim `/Applications/Spotify.app 2/…`
    /// (a second copy of an app is a routinely-present neighbour on a real Mac,
    /// and mis-attributing it would exclude the WRONG app's audio).
    private static func isInside(bundlePath: String?, executablePath: String?) -> Bool {
        guard var bundlePath, !bundlePath.isEmpty,
              let executablePath, !executablePath.isEmpty else { return false }
        while bundlePath.count > 1 && bundlePath.hasSuffix("/") { bundlePath.removeLast() }
        return executablePath == bundlePath || executablePath.hasPrefix(bundlePath + "/")
    }

    /// Layer 4 (original behaviour): for a process reporting NO bundle id of its
    /// own, the first resolvable bundle id up its parent chain. Returns nil for
    /// a process that has its own id, or if the chain never resolves within
    /// `maxParentHops` (also the cycle guard).
    private static func inheritedBundleID(
        ownBundleID: String?,
        pid: pid_t,
        pidToOwnBundle: [pid_t: String],
        parentPID: (pid_t) -> pid_t?,
        bundleIDForPID: (pid_t) -> String?,
        maxParentHops: Int
    ) -> String? {
        if let own = ownBundleID, !own.isEmpty { return nil }

        var current = pid
        for _ in 0..<maxParentHops {
            guard let parent = parentPID(current), parent > 1 else { return nil }
            if let bundle = pidToOwnBundle[parent], !bundle.isEmpty { return bundle }
            if let bundle = bundleIDForPID(parent), !bundle.isEmpty { return bundle }
            current = parent
        }
        return nil
    }

    // MARK: - Production reads for the new layers (Darwin only — no AppKit)

    /// The pid macOS holds responsible for `pid` — the attribution TCC uses to
    /// blame a helper process on the app that spawned it, and the ONLY signal
    /// that survives a helper being reparented to launchd (`ppid == 1`), which
    /// is what broke exception routing for Spotify.
    ///
    /// `responsibility_get_pid_responsible_for_pid` is private-but-stable
    /// libsystem API, resolved through `dlsym` exactly like
    /// ``SystemAudioCaptureTCC/preflight(service:)`` resolves `TCCAccessPreflight`
    /// — see that file's header for why private-symbol use is an accepted,
    /// owner-approved cost on this Developer-ID-only app. `RTLD_DEFAULT`
    /// suffices here (unlike TCC.framework, libsystem is always already loaded),
    /// and an unresolvable symbol degrades to nil: layer 2 goes quiet, the other
    /// three still run. It returns the pid itself for an ordinary
    /// single-process app, and a negative value on error; both are filtered by
    /// the caller as "no information".
    private static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let responsibility = responsibilitySymbol else { return nil }
        let responsible = responsibility(pid)
        return responsible > 0 ? responsible : nil
    }

    /// Resolved once per process, not per call: `dlsym` is a lookup through
    /// every loaded image, and this runs for every audio process object on
    /// every resolve.
    private static let responsibilitySymbol: (@convention(c) (pid_t) -> pid_t)? = {
        // RTLD_DEFAULT — search every image already loaded in this process.
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// The absolute path of `pid`'s executable, via libproc — the same layer as
    /// the existing `proc_pidinfo` parent-pid read, so no new dependency.
    private static func executablePath(of pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` is a C macro the Swift SDK does not
        // re-export; it is defined as `4 * MAXPATHLEN`, spelled out here.
        var buffer = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - Value types

/// One resolved Core Audio process object: the `AudioObjectID` a consumer hands
/// to `CATapDescription`, plus the pid it represents (for logging/diagnostics).
public struct AudioProcess: Hashable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t

    public init(objectID: AudioObjectID, pid: pid_t) {
        self.objectID = objectID
        self.pid = pid
    }
}

/// Which of the four ANY-of attribution layers (see the type's doc comment)
/// matched a process — T2 diagnostic detail only, never a factor in matching
/// itself. `rawValue`s are the exact strings Telemetry writes to disk.
public enum AttributionLayer: String, Sendable {
    case own, responsible, bundlePath, parentWalk
}

/// One resolved process plus the layer that attributed it — the
/// ``resolveWithAttribution(bundleID:)`` companion to plain ``AudioProcess``,
/// for the T2 diagnostic path only.
public struct AttributedProcess: Hashable, Sendable {
    public let process: AudioProcess
    public let layer: AttributionLayer

    public init(process: AudioProcess, layer: AttributionLayer) {
        self.process = process
        self.layer = layer
    }
}

/// Raw, unresolved per-process-object data read straight from the HAL: the
/// process object id, its pid, and the bundle id Core Audio reports for it
/// (`nil` for a child/helper process that has none of its own — the case the
/// parent-pid walk exists to attribute).
public struct RawAudioProcess: Hashable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String?) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
    }
}

// MARK: - HAL seam (protocol)

/// The `AudioProcessResolver` hardware/OS seam: enumerate live Core Audio
/// process objects and walk a pid's parent chain. The production impl
/// (`CoreAudioProcessEnumerator`) reads the real HAL; tests inject a fake that
/// hands back scripted `RawAudioProcess` values and a scripted parent map, so
/// the resolution logic runs with no live Core Audio.
public protocol AudioProcessEnumerating: Sendable {
    /// Every live Core Audio process object, each with its pid and the bundle
    /// id Core Audio reports (nil when it reports none).
    func enumerateProcesses() -> [RawAudioProcess]

    /// The parent pid of `pid`, or nil at the top of the tree (or on error).
    func parentPID(of pid: pid_t) -> pid_t?
}

// MARK: - Production seam (Core Audio + libproc)

#if canImport(CoreAudio)

/// The real HAL-backed enumerator: reads
/// `kAudioHardwarePropertyProcessObjectList` off the system object, then
/// `kAudioProcessPropertyPID` / `kAudioProcessPropertyBundleID` per process
/// object, and walks parent pids via `proc_pidinfo(_:PROC_PIDTBSDINFO:...)`.
/// Read-only: it only reads process metadata, never opens a tap or plays audio.
public struct CoreAudioProcessEnumerator: AudioProcessEnumerating {

    public init() {}

    public func enumerateProcesses() -> [RawAudioProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        let sizeErr = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard sizeErr == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let dataErr = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs)
        guard dataErr == noErr else { return [] }

        var result: [RawAudioProcess] = []
        result.reserveCapacity(count)
        for objectID in objectIDs where objectID != kAudioObjectUnknown {
            guard let pid = Self.readPID(objectID) else { continue }
            let bundleID = Self.readBundleID(objectID)
            result.append(RawAudioProcess(objectID: objectID, pid: pid, bundleID: bundleID))
        }
        return result
    }

    public func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected)
        guard written == expected else { return nil }
        let ppid = pid_t(bitPattern: info.pbi_ppid)
        return ppid > 0 ? ppid : nil
    }

    // MARK: Per-process property reads

    private static func readPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let err = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
        guard err == noErr else { return nil }
        return pid
    }

    private static func readBundleID(_ objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        let sizeErr = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard sizeErr == noErr, size > 0 else { return nil }

        var cfString: CFString?
        let err = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr, let cfString else { return nil }
        let bundleID = cfString as String
        return bundleID.isEmpty ? nil : bundleID
    }
}

#endif
