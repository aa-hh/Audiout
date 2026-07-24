// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
// POSIX process enumeration (sysctl / kinfo_proc). This is NOT AppKit — the
// `AudiouterCore` rule bars `NSRunningApplication`/`NSWorkspace` specifically,
// not process enumeration in general, so the whole process-tree walk lives in
// Core with no injected AppKit seam (see the type doc below).
import Darwin
// AudioObjectID + the whole-system process-object-list HAL reads. Intrinsic to
// this file's public contract (it returns `Set<AudioObjectID>`), so — unlike
// ``PerAppCaptureCoordinator``, whose AudioToolbox-FREE state machine motivates
// its `#if canImport(AudioToolbox)` guard — this import is unconditional. The
// package is macOS-only (`Package.swift` `platforms: [.macOS(.v14)]`, and it
// links the macOS-only `AirPlayEngine`), so AudioToolbox is always available.
import AudioToolbox

// MARK: - Value types (pure — no Core Audio, no syscalls)

/// One live Core Audio process object paired with the OS `pid` it represents.
/// The pairing is the whole point of this file: Core Audio hands out opaque
/// ``AudioObjectID``s for "client processes currently connected to the audio
/// system", and `kAudioProcessPropertyPID` is the documented read that maps one
/// back to a pid (the reverse of `kAudioHardwarePropertyTranslatePIDToProcessObject`,
/// which the capture coordinators use to go pid → object). Value type so tests
/// can hand the resolver an arbitrary fake object list with no real HAL.
public struct AudioProcessObject: Sendable, Equatable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public init(objectID: AudioObjectID, pid: pid_t) {
        self.objectID = objectID
        self.pid = pid
    }
}

/// An immutable snapshot of the system's live process hierarchy: which pids are
/// the direct children of which. A value type — tests substitute an arbitrary
/// (even malformed or cyclic) tree with zero real processes involved, which is
/// how the transitive-walk cap and cycle-safety are exercised hermetically.
public struct ProcessTreeSnapshot: Sendable {
    /// ppid → its direct child pids. A pid absent as a key simply has no known
    /// children (returns `[]`).
    private let childrenByParent: [pid_t: [pid_t]]

    /// Build directly from a parent → children adjacency (the shape tests
    /// script, including deliberately cyclic ones).
    public init(childrenByParent: [pid_t: [pid_t]]) {
        self.childrenByParent = childrenByParent
    }

    /// Build from the `(pid, ppid)` pairs a process enumeration naturally
    /// yields (one row per live process). A self-parented row (`pid == ppid`,
    /// which the kernel uses for a couple of degenerate/kernel entries) is
    /// dropped so it can never seed a one-node self-cycle.
    public init(parentPairs: [(pid: pid_t, ppid: pid_t)]) {
        var adjacency: [pid_t: [pid_t]] = [:]
        for pair in parentPairs where pair.pid != pair.ppid {
            adjacency[pair.ppid, default: []].append(pair.pid)
        }
        self.childrenByParent = adjacency
    }

    /// The direct child pids of `pid` (empty if it has none / isn't known).
    public func children(of pid: pid_t) -> [pid_t] {
        childrenByParent[pid] ?? []
    }
}

// MARK: - AudioProcessResolver

/// Resolves the FULL SET of live Core Audio process objects belonging to an
/// application, given the pid of that application's *main* process (T1 of
/// `docs/plans/PLAN-FIREFOX-ROUTING-LEAK.md`).
///
/// ## The bug this primitive exists to fix
/// The app resolves a bundle ID to exactly ONE pid — the main application
/// process (`AppDelegate.resolveRunningAppPID`, via
/// `NSRunningApplication…first?.processIdentifier`). Multi-process browsers
/// (Firefox, Chrome) emit their audio from a **child** process (a content /
/// GPU / RDD / utility process) whose pid differs from that main pid. So both
/// consumers that only ever knew the single main pid mis-target:
///   - the whole-system tap's exclusion list
///     (``NativeCaptureCoordinator``'s `resolveExcludedPIDs`) excludes the
///     wrong (silent) pid, leaking the browser into the system mix;
///   - the per-app capture (``PerAppCaptureCoordinator``) taps that same
///     silent main pid, so the redirect target hears nothing.
/// This resolver widens "one pid" to "every audio-relevant process object in
/// that app's process tree", which T2/T3/T5 consume.
///
/// ## Why there is NO injected AppKit seam here
/// The task framing worried this would need an injected `NSRunningApplication`
/// closure to stay out of AppKit. It does not — for two independent reasons:
///   1. **The entry point takes a `pid_t`, not a bundle ID.** The bundle-ID →
///      main-pid lookup (the ONLY genuinely `NSRunningApplication`-only step)
///      already happens upstream in the AppKit layer via the existing
///      `resolvePID: (String) -> pid_t?` closure threaded through
///      `NativeBackend`. Consumers compose the two:
///      `resolvePID(bundleID)` → mainPID → `resolveAudioProcessObjects(forPID:)`.
///      This resolver never sees a bundle ID and never needs AppKit.
///   2. **Process-tree walking is POSIX, not AppKit.** The `AudiouterCore`
///      rule bars `NSRunningApplication`/`NSWorkspace` specifically; `sysctl`
///      (`KERN_PROC_ALL`) / `kinfo_proc` ancestry is plain Darwin, allowed in
///      Core. So the transitive parent-chain walk lives entirely in Core.
/// The injected closures below therefore exist ONLY for **test substitution**
/// of the two live-system facts (the Core Audio object list and the process
/// tree), mirroring how ``PerAppCaptureCoordinator`` injects `makeTap` /
/// `resolvePID` so its state machine runs with no real HAL — not for any
/// AppKit boundary.
///
/// ## Algorithm
/// 1. Snapshot the process tree (`snapshotProcessTree`).
/// 2. From `rootPID`, BFS the tree to the full descendant pid set — the main
///    process AND every child/grandchild/… — capped at ``maxDepth`` hops and
///    guarded by a visited-set so any cycle or pathological tree terminates
///    (``descendants(ofPID:in:maxDepth:)``).
/// 3. Enumerate every live Core Audio process object with its pid
///    (`enumerateAudioProcessObjects`).
/// 4. Return the ``AudioObjectID`` of every enumerated object whose pid is in
///    the descendant set.
///
/// ## Scope limitation — XPC/launchd-reparented audio processes (Safari/WebKit)
/// This is a **ppid-ancestry** walk: it finds an app's audio children only when
/// they are UNIX ppid-descendants of the app's main pid. That holds for
/// browsers that `fork()`/`exec()` their helpers — **Firefox and Chrome, the
/// plan's scoped targets** (verified live: Firefox's audio helpers report
/// `ppid == <main firefox pid>`). It does **NOT** hold for apps whose audio
/// child is an **XPC service spawned by launchd** — those carry `ppid == 1`, so
/// a walk from the app's main pid never reaches them. **Safari/WebKit is the
/// known case**: `WebContent`/networking/GPU processes are launchd-reparented
/// XPC services, so this resolver returns only Safari's (silent) main-process
/// object and per-app redirect of Safari does not capture its real audio. This
/// is a documented scope limitation, NOT a regression (Safari per-app redirect
/// never worked), and NO unit test can catch it (the mocked ``ProcessTreeSnapshot``
/// asserts the parent→child edge by fiat; real WebKit simply lacks that edge —
/// only a live Safari test exposes it). Closing it later is possible WITHIN Core
/// (no AppKit): match by `kAudioProcessPropertyBundleID`, or resolve the
/// "responsible pid" via the private libsystem API TCC uses (dlsym — precedent:
/// the `TCCAccessPreflight` shim). Surfaced by the T1 adversarial review,
/// 2026-07-24; see `docs/plans/PLAN-FIREFOX-ROUTING-LEAK.md`.
///
/// A `struct` (not a `class`): it holds only its injected closures + config and
/// carries no mutable state, so it is trivially `Sendable` and cheap to copy
/// into whichever consumer needs it.
public struct AudioProcessResolver: Sendable {

    /// Maximum ancestry hops walked from the target pid before the descendant
    /// walk stops. `5` comfortably covers real multi-process browsers (a
    /// content/GPU/RDD child is 1 hop, a process it in turn spawns 2) while
    /// bounding the worst case against a pathological tree. The visited-set in
    /// ``descendants(ofPID:in:maxDepth:)`` already guarantees termination on
    /// its own; this cap is the belt-and-suspenders bound the plan calls for.
    public static let defaultMaxDepth = 5

    /// Injected: every live Core Audio process object with its pid. Production
    /// wiring reads the HAL (``liveAudioProcessObjects()``); tests supply a
    /// fixed list.
    private let enumerateAudioProcessObjects: @Sendable () -> [AudioProcessObject]

    /// Injected: a fresh snapshot of the whole-system process tree. Production
    /// wiring reads `sysctl` (``liveProcessTreeSnapshot()``); tests supply a
    /// fixed (possibly cyclic) tree. Called ONCE per `resolve…` so the whole
    /// descendant walk sees a single consistent snapshot.
    private let snapshotProcessTree: @Sendable () -> ProcessTreeSnapshot

    /// The hop cap for the descendant walk (see ``defaultMaxDepth``).
    private let maxDepth: Int

    // MARK: Init

    /// Injectable designated initializer (internal — tests pass fakes for both
    /// live-system facts so the resolution logic runs with no real HAL and no
    /// real process tree). Mirrors ``PerAppCaptureCoordinator``'s internal
    /// designated init taking injected closures.
    init(
        enumerateAudioProcessObjects: @escaping @Sendable () -> [AudioProcessObject],
        snapshotProcessTree: @escaping @Sendable () -> ProcessTreeSnapshot,
        maxDepth: Int = AudioProcessResolver.defaultMaxDepth
    ) {
        self.enumerateAudioProcessObjects = enumerateAudioProcessObjects
        self.snapshotProcessTree = snapshotProcessTree
        self.maxDepth = maxDepth
    }

    /// Production initializer: wires the real `sysctl` process-tree snapshot and
    /// the real Core Audio process-object enumeration. The analogue of
    /// ``PerAppCaptureCoordinator/init(resolvePID:name:muteBehavior:)`` — the
    /// public, real-calls entry point every non-test consumer uses.
    public init(maxDepth: Int = AudioProcessResolver.defaultMaxDepth) {
        self.init(
            enumerateAudioProcessObjects: { AudioProcessResolver.liveAudioProcessObjects() },
            snapshotProcessTree: { AudioProcessResolver.liveProcessTreeSnapshot() },
            maxDepth: maxDepth)
    }

    // MARK: Public entry point

    /// Every live Core Audio process object belonging to `rootPID` OR any of
    /// its descendant processes.
    ///
    /// Behaviour across the edge cases the plan enumerates:
    ///   - **Single-process app (no children):** the descendant set is just
    ///     `{rootPID}`, so this returns `rootPID`'s own object if it has one —
    ///     exactly the pre-existing single-pid behaviour, leaving single-process
    ///     apps unaffected.
    ///   - **Main pid has no object yet but a child does (the Firefox bug):**
    ///     `rootPID` is still in the descendant set, and so is the child; the
    ///     child's object is returned even though the main pid has none.
    ///   - **A process quit between enumeration and the pid read:** that object
    ///     is skipped in ``liveAudioProcessObjects()`` (its pid read fails),
    ///     never crashing the resolve.
    ///   - **No live process objects at all:** returns the empty set (not an
    ///     error).
    ///   - **A non-app `rootPID` (`<= 1`): returns the empty set.** `0` is
    ///     `kernel_task`, `1` is `launchd`; neither is ever a routed app, and
    ///     walking launchd's tree would mass-match hundreds of unrelated
    ///     processes. This hardens against an upstream bundle-ID→pid resolver
    ///     returning `0`/`1`/`-1` — the malformed pid resolves to "no audio
    ///     objects" (harmlessly retryable upstream) rather than a mass
    ///     mis-redirect. (Surfaced by the T1 adversarial review, 2026-07-24.)
    public func resolveAudioProcessObjects(forPID rootPID: pid_t) -> Set<AudioObjectID> {
        guard rootPID > 1 else { return [] }
        let tree = snapshotProcessTree()
        let family = AudioProcessResolver.descendants(ofPID: rootPID, in: tree, maxDepth: maxDepth)
        var result: Set<AudioObjectID> = []
        for object in enumerateAudioProcessObjects() where family.contains(object.pid) {
            result.insert(object.objectID)
        }
        return result
    }

    /// The full descendant pid set (`rootPID` + every descendant, capped) for
    /// the current live process tree. Exposed for the consumers that want the
    /// pids themselves (e.g. an exclusion list keyed on pids) and for tests.
    /// Same non-app-`rootPID` (`<= 1`) guard as ``resolveAudioProcessObjects(forPID:)``.
    func descendantPIDs(ofPID rootPID: pid_t) -> Set<pid_t> {
        guard rootPID > 1 else { return [] }
        return AudioProcessResolver.descendants(ofPID: rootPID, in: snapshotProcessTree(), maxDepth: maxDepth)
    }

    // MARK: Transitive descendant walk (pure — the cap + cycle-safety live here)

    /// BFS `tree` from `rootPID`, returning `rootPID` together with every
    /// descendant reachable within `maxDepth` hops.
    ///
    /// Termination is guaranteed two ways, independently:
    ///   - the `visited` set means each pid is expanded at most once, so even a
    ///     cyclic adjacency (`a → b → a`) or a self-loop (`a → a`) converges —
    ///     pids are finite and none is revisited;
    ///   - `hop < cap` additionally bounds the walk to `maxDepth` levels, the
    ///     explicit "stop after N hops" guard the plan asks for.
    /// `rootPID` is always included, so a pid with no children resolves to just
    /// itself. A non-positive `maxDepth` yields `{rootPID}` (root only, no
    /// descendants). This is the PURE graph walk — it trusts its `rootPID`; the
    /// "is this a real app pid" guard lives at the public entry points
    /// (``resolveAudioProcessObjects(forPID:)`` / ``descendantPIDs(ofPID:)``),
    /// so this stays a clean, arbitrary-root-testable BFS.
    static func descendants(ofPID rootPID: pid_t, in tree: ProcessTreeSnapshot, maxDepth: Int) -> Set<pid_t> {
        var visited: Set<pid_t> = [rootPID]
        var frontier: [pid_t] = [rootPID]
        let cap = max(0, maxDepth)
        var hop = 0
        while !frontier.isEmpty && hop < cap {
            var next: [pid_t] = []
            for pid in frontier {
                for child in tree.children(of: pid) where !visited.contains(child) {
                    visited.insert(child)
                    next.append(child)
                }
            }
            frontier = next
            hop += 1
        }
        return visited
    }

    // MARK: Production system reads
    //
    // These are the two live-system facts the injected closures stand in for in
    // tests. They are pure reads — no audio is played or captured, no process
    // is signalled — so they are safe to call at any time.

    /// Every live Core Audio process object on the system, each paired with the
    /// pid it represents. Reads `kAudioHardwarePropertyProcessObjectList` off
    /// the system object (the same list ``PerAppCaptureCoordinator`` and
    /// ``NativeCaptureCoordinator`` enumerate, and the T7 `process-audio-dump`
    /// diagnostic dumps), then reads `kAudioProcessPropertyPID` off each object.
    ///
    /// Best-effort and non-throwing: a failed list read yields `[]` (an empty
    /// resolve, never a crash), and any single object whose pid read fails —
    /// most plausibly because that process quit between enumeration and the
    /// read — is skipped rather than aborting the whole scan.
    static func liveAudioProcessObjects() -> [AudioProcessObject] {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        let sizeErr = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize)
        guard sizeErr == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let listErr = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize, &objectIDs)
        guard listErr == noErr else { return [] }

        var pidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var result: [AudioProcessObject] = []
        result.reserveCapacity(objectIDs.count)
        for objectID in objectIDs where objectID != kAudioObjectUnknown {
            var pid: pid_t = -1
            var size = UInt32(MemoryLayout<pid_t>.size)
            let err = AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &size, &pid)
            // A process that exited between the list read and this read fails
            // here (or reports a non-positive pid) — skip it, don't crash the
            // whole resolve over one dead object.
            guard err == noErr, pid > 0 else { continue }
            result.append(AudioProcessObject(objectID: objectID, pid: pid))
        }
        return result
    }

    /// A fresh snapshot of the whole-system process tree via
    /// `sysctl(KERN_PROC_ALL)` — one atomic read of every live process's pid +
    /// parent pid, from which ``ProcessTreeSnapshot`` builds the child
    /// adjacency. POSIX only (no AppKit); this is why the ancestry walk can
    /// live entirely in Core.
    ///
    /// Best-effort and non-throwing: any `sysctl` failure yields an empty tree
    /// (the resolve then degrades to "main pid only", never a crash). The set
    /// of live processes can grow between the size query and the fetch, which
    /// surfaces as `ENOMEM`; that case re-queries and retries a few times before
    /// giving up on an empty tree.
    static func liveProcessTreeSnapshot() -> ProcessTreeSnapshot {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let empty = ProcessTreeSnapshot(childrenByParent: [:])

        for _ in 0..<4 {
            var length = 0
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
                return empty
            }
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: length, alignment: MemoryLayout<kinfo_proc>.alignment)
            defer { buffer.deallocate() }

            var filled = length
            let err = sysctl(&mib, u_int(mib.count), buffer, &filled, nil, 0)
            if err != 0 {
                if errno == ENOMEM { continue }   // process set grew — re-query and retry
                return empty
            }

            let actual = filled / MemoryLayout<kinfo_proc>.stride
            let procs = buffer.bindMemory(to: kinfo_proc.self, capacity: actual)
            var pairs: [(pid: pid_t, ppid: pid_t)] = []
            pairs.reserveCapacity(actual)
            for i in 0..<actual {
                let entry = procs[i]
                let pid = entry.kp_proc.p_pid
                let ppid = entry.kp_eproc.e_ppid
                if pid > 0 { pairs.append((pid, ppid)) }
            }
            return ProcessTreeSnapshot(parentPairs: pairs)
        }
        return empty
    }
}
