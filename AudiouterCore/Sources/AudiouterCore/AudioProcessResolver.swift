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
/// ## Consumers (later tasks — this file does not wire them)
/// Both consumers ultimately feed a `CATapDescription` that takes
/// `[AudioObjectID]`:
/// - the per-app capture path (`PerAppCaptureCoordinator`) builds a
///   `stereoMixdownOfProcesses:` from these object ids, and
/// - the whole-system exclusion path (`NativeCaptureCoordinator`) builds a
///   `stereoGlobalTapButExcludeProcesses:` from them.
/// So the resolved value carries `AudioObjectID` (the object each consumer
/// hands to Core Audio); the pid rides along for logging/diagnostics.
///
/// ## Empty set is a valid, non-error result
/// If no process object resolves to the bundle id — the app isn't running, or
/// hasn't opened an audio stream yet — this returns an EMPTY set, never an
/// error. A caller distinguishes "no processes yet" (retryable, the
/// `.processNotYetAudible` situation) from a genuine failure by that emptiness.
///
/// ## AppKit stays out of Core
/// Mapping a bare pid to a bundle id in the general case needs
/// `NSRunningApplication`, which lives in AppKit — a framework `AudiouterCore`
/// must never import. That one step is an injected closure (`bundleIDForPID`),
/// supplied by an AppKit-importing layer, exactly as
/// `PerAppCaptureCoordinator`/`NativeCaptureCoordinator` inject `resolvePID`.
/// Everything else (enumerating process objects, reading their pid/bundle id,
/// walking parent pids via libproc) is pure Core Audio + Darwin and lives here.
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

    /// How many parent-pid hops to follow before giving up attributing a
    /// nil-bundle-id process. Capped so a pathological/cyclic chain can never
    /// loop; a browser helper sits one or two hops under its main process.
    private let maxParentHops: Int

    public init(
        enumerator: AudioProcessEnumerating,
        bundleIDForPID: @escaping @Sendable (pid_t) -> String? = { _ in nil },
        maxParentHops: Int = 5
    ) {
        self.enumerator = enumerator
        self.bundleIDForPID = bundleIDForPID
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
            maxParentHops: maxParentHops)
    }

    // MARK: - Pure resolution logic (no Core Audio, no AppKit — unit-tested directly)

    /// Compute the resolved set from already-enumerated raw process data.
    /// Split out from the HAL call so it can be tested with plain arrays and
    /// closures. A process object matches `bundleID` when its EFFECTIVE bundle
    /// id equals it: its own reported bundle id if it has one, otherwise the
    /// first bundle id found walking its parent-pid chain (via a sibling
    /// process object's own bundle id, or the injected `bundleIDForPID`).
    static func resolve(
        bundleID target: String,
        processes: [RawAudioProcess],
        parentPID: (pid_t) -> pid_t?,
        bundleIDForPID: (pid_t) -> String?,
        maxParentHops: Int
    ) -> Set<AudioProcess> {
        // pid → bundle id for every process that reports one of its own, so a
        // parent walk can resolve without AppKit when the parent itself is in
        // the audio process list.
        var pidToOwnBundle: [pid_t: String] = [:]
        for process in processes {
            if let bundle = process.bundleID, !bundle.isEmpty {
                pidToOwnBundle[process.pid] = bundle
            }
        }

        var resolved: Set<AudioProcess> = []
        for process in processes {
            let effective = effectiveBundleID(
                ownBundleID: process.bundleID,
                pid: process.pid,
                pidToOwnBundle: pidToOwnBundle,
                parentPID: parentPID,
                bundleIDForPID: bundleIDForPID,
                maxParentHops: maxParentHops)
            if effective == target {
                resolved.insert(AudioProcess(objectID: process.objectID, pid: process.pid))
            }
        }
        return resolved
    }

    /// The bundle id a process object should be attributed to: its own if it
    /// reports one, else the first resolvable bundle id up its parent chain.
    /// Returns nil if the chain never resolves within `maxParentHops`.
    private static func effectiveBundleID(
        ownBundleID: String?,
        pid: pid_t,
        pidToOwnBundle: [pid_t: String],
        parentPID: (pid_t) -> pid_t?,
        bundleIDForPID: (pid_t) -> String?,
        maxParentHops: Int
    ) -> String? {
        if let own = ownBundleID, !own.isEmpty { return own }

        var current = pid
        for _ in 0..<maxParentHops {
            guard let parent = parentPID(current), parent > 1 else { return nil }
            if let bundle = pidToOwnBundle[parent], !bundle.isEmpty { return bundle }
            if let bundle = bundleIDForPID(parent), !bundle.isEmpty { return bundle }
            current = parent
        }
        return nil
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
