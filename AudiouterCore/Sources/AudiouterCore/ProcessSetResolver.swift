import Foundation

#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// The Wave-1 capture seam (W1-T1). Maps a bundle ID to the FULL set of
/// process identifiers that make up that logical app — its main process AND
/// any audio-playing helper/child processes.
///
/// ## Why a set, not a single pid
/// The pre-Wave-1 seam was `(_ bundleID: String) -> pid_t?`: resolve a bundle
/// ID to the *first* running instance's pid. That silently broke routing and
/// exclusion for every multi-process app — browsers and Electron/Chromium apps
/// (Firefox, Chrome, Spotify, Discord…) render audio from a **child** process,
/// not their main pid, so tapping/excluding the main pid did nothing (findings
/// R1, R2, R9, R14 in `docs/plans/PLAN-RELIABILITY.md`). A resolver that returns
/// every owned pid lets the per-app tap capture all of them and the
/// whole-system tap exclude all of them.
///
/// ## Pids, not process objects
/// The resolver returns `pid_t`s, not Core Audio process `AudioObjectID`s, so it
/// composes with the existing tap-building code unchanged: both coordinators
/// already translate a pid to its process object at tap-creation time
/// (`translateProcessObject(pid:)`), and the tap APIs
/// (`CATapDescription(stereoMixdownOfProcesses:)`, `stereoGlobalTapButExcludeProcesses`)
/// consume process objects derived from those pids. Widening the *seam* to a set
/// is this task (W1-T1); teaching the coordinators to tap/exclude the whole set
/// (rather than the first pid) is W1-T2 / W1-T3.
///
/// The returned array is ordered **main-process-first** and deduplicated, so a
/// caller that still needs a single pid can take `.first` and get the app's
/// main process (today's behaviour) while the full set stays available.
public typealias AppProcessResolver = @Sendable (_ bundleID: String) -> [pid_t]

/// One Core Audio audio-process object (an entry of
/// `kAudioHardwarePropertyProcessObjectList`), reduced to the two fields the
/// resolver groups on. A value type so the grouping logic is pure and hermetic:
/// tests build a fake list; production reads it from Core Audio.
public struct AudioProcessDescriptor: Sendable, Equatable {
    /// The Core Audio process `AudioObjectID` (a `UInt32`; typed as `UInt32`
    /// here so the descriptor and its tests need no `AudioToolbox`).
    public let objectID: UInt32
    /// The owning Unix process id.
    public let pid: pid_t
    /// The process's bundle identifier, or `nil` when it reports none.
    /// Chrome renderer/GPU helpers carry `com.google.Chrome.helper…`; Firefox
    /// content children carry the parent's identity (`org.mozilla.firefox`).
    public let bundleID: String?

    public init(objectID: UInt32, pid: pid_t, bundleID: String?) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// Resolves a bundle ID to its full process set by enumerating the live audio
/// process-object list and grouping helpers/children to their owning app.
///
/// Both AppKit-touching and Core-Audio-touching bits are behind injected
/// closures so the grouping stays unit-testable with no real hardware, matching
/// the existing coordinator seams (`AudiouterCore` never imports AppKit).
public struct ProcessSetResolver: Sendable {

    /// Live snapshot of every current audio process object. Injected: tests
    /// supply a fake list; production wires ``systemEnumerator()``. Re-invoked
    /// on every ``pids(forBundleID:)`` call, so the result always reflects the
    /// current process list (browsers spawn/kill audio children per tab).
    private let enumerate: @Sendable () -> [AudioProcessDescriptor]

    /// Walk a pid to its "responsible" (owning) pid — the app process a helper
    /// or child belongs to when prefix matching can't place it. This needs
    /// private/AppKit API (`responsibility_get_pid_for_pid`, or an
    /// `NSRunningApplication` lookup), so it is injected and stays out of Core.
    /// Returns `nil` when unknown (the common case, and the safe default).
    private let responsiblePID: @Sendable (pid_t) -> pid_t?

    /// - Parameters:
    ///   - enumerate: live audio-process-object snapshot (see ``systemEnumerator()``).
    ///   - responsiblePID: pid → owning-app pid, for helpers whose own bundle ID
    ///     doesn't prefix-match the target. Defaults to "unknown" (prefix-match
    ///     only), which already covers Chrome helpers and Firefox children.
    public init(
        enumerate: @escaping @Sendable () -> [AudioProcessDescriptor],
        responsiblePID: @escaping @Sendable (pid_t) -> pid_t? = { _ in nil }
    ) {
        self.enumerate = enumerate
        self.responsiblePID = responsiblePID
    }

    /// The ordered, deduplicated set of pids that make up `bundleID`: its main
    /// process first, then helper/child processes. Empty when nothing matches
    /// (the app isn't running, or hasn't opened an audio stream yet).
    public func pids(forBundleID bundleID: String) -> [pid_t] {
        let all = enumerate()
        let helperPrefix = bundleID + "."

        // A process "belongs" to the target if its own bundle ID is the target
        // exactly, or is a dotted sub-identifier of it (Chrome helpers:
        // `com.google.Chrome.helper.Renderer`; Firefox children reuse the parent
        // ID exactly, so they land in the exact-match bucket).
        func belongs(_ candidate: String?) -> Bool {
            guard let candidate else { return false }
            return candidate == bundleID || candidate.hasPrefix(helperPrefix)
        }

        var exactPIDs: [pid_t] = []      // main process(es): bundle ID == target
        var prefixPIDs: [pid_t] = []     // helpers: dotted sub-identifier
        var walkedPIDs: [pid_t] = []     // resolved only via responsible-pid walk
        var seen = Set<pid_t>()

        func take(_ pid: pid_t, into bucket: inout [pid_t]) {
            guard seen.insert(pid).inserted else { return }
            bucket.append(pid)
        }

        // Pass 1: direct + prefix match.
        for descriptor in all {
            guard belongs(descriptor.bundleID) else { continue }
            if descriptor.bundleID == bundleID {
                take(descriptor.pid, into: &exactPIDs)
            } else {
                take(descriptor.pid, into: &prefixPIDs)
            }
        }

        // Pass 2: responsible-pid walk for processes prefix matching couldn't
        // place (no bundle ID of their own, or an unrelated one). Map pid →
        // bundle ID once so the walk is a lookup, not another enumeration.
        var bundleByPID: [pid_t: String] = [:]
        for descriptor in all {
            if let b = descriptor.bundleID { bundleByPID[descriptor.pid] = b }
        }
        for descriptor in all where !seen.contains(descriptor.pid) {
            guard belongs(bundleByPID[descriptor.pid]) == false else { continue }
            guard let owner = responsiblePID(descriptor.pid) else { continue }
            if belongs(bundleByPID[owner]) {
                take(descriptor.pid, into: &walkedPIDs)
            }
        }

        return exactPIDs + prefixPIDs + walkedPIDs
    }

    /// Adapt to the injected ``AppProcessResolver`` seam the coordinators hold.
    public func asResolver() -> AppProcessResolver {
        { self.pids(forBundleID: $0) }
    }
}

#if canImport(AudioToolbox)
extension ProcessSetResolver {

    /// Production enumeration of `kAudioHardwarePropertyProcessObjectList`,
    /// reading each object's pid (`kAudioProcessPropertyPID`) and bundle ID
    /// (`kAudioProcessPropertyBundleID`). Best-effort per object: an object that
    /// can't be read (a process gone between the list read and the per-object
    /// read) is skipped, never fatal.
    ///
    /// This is pure Core Audio — no AppKit — so it lives in Core. The one
    /// AppKit/private-API piece (the responsible-pid walk) stays an injected
    /// closure supplied by the app layer.
    public static func systemEnumerator() -> @Sendable () -> [AudioProcessDescriptor] {
        {
            var listAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)

            var dataSize: UInt32 = 0
            let sizeErr = AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize)
            guard sizeErr == noErr, dataSize > 0 else { return [] }

            let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
            var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
            let listErr = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil,
                &dataSize, &objectIDs)
            guard listErr == noErr else { return [] }

            return objectIDs.compactMap { objectID -> AudioProcessDescriptor? in
                guard let pid = Self.readPID(objectID) else { return nil }
                return AudioProcessDescriptor(
                    objectID: objectID,
                    pid: pid,
                    bundleID: Self.readBundleID(objectID))
            }
        }
    }

    /// Read a process object's owning pid, or `nil` if unreadable.
    private static func readPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let err = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
        guard err == noErr, pid >= 0 else { return nil }
        return pid
    }

    /// Read a process object's bundle ID, or `nil` if it reports none.
    private static func readBundleID(_ objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfString: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr, let value = cfString as String?, value.isEmpty == false else {
            return nil
        }
        return value
    }
}
#endif
