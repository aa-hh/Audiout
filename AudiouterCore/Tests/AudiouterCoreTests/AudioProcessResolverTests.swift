import XCTest
@testable import AudiouterCore

#if canImport(CoreAudio)
import CoreAudio
#endif

/// Hermetic tests for ``AudioProcessResolver``'s pure resolution logic (T1).
/// Every input is plain data — a `RawAudioProcess` array, a scripted parent-pid
/// map, and a scripted `bundleIDForPID` closure — so the "given raw process
/// data, compute the resolved set" logic runs with no live Core Audio and no
/// `NSRunningApplication`. The HAL-backed `CoreAudioProcessEnumerator` is not
/// exercised here (it needs live Core Audio); the seam exists precisely so this
/// logic is testable without it.
final class AudioProcessResolverTests: XCTestCase {

    private let firefox = "org.mozilla.firefox"
    private let mainPID: pid_t = 100
    private let childPID: pid_t = 200

    /// Convenience over the pure static entry point.
    private func resolve(
        bundleID: String,
        processes: [RawAudioProcess],
        parents: [pid_t: pid_t] = [:],
        bundleIDForPID: [pid_t: String] = [:],
        maxParentHops: Int = 5
    ) -> Set<AudioProcess> {
        AudioProcessResolver.resolve(
            bundleID: bundleID,
            processes: processes,
            parentPID: { parents[$0] },
            bundleIDForPID: { bundleIDForPID[$0] },
            maxParentHops: maxParentHops)
    }

    // A bundle's main process alone (it reports its own bundle id).
    func testMainProcessOnly() {
        let processes = [
            RawAudioProcess(objectID: 1, pid: mainPID, bundleID: firefox)
        ]
        let resolved = resolve(bundleID: firefox, processes: processes)
        XCTAssertEqual(resolved, [AudioProcess(objectID: 1, pid: mainPID)])
    }

    // Main process + a nil-bundle-id child whose parent chain resolves to the
    // target (the Firefox media/RDD child case). Both must be returned.
    func testNilBundleChildAttributedToParent() {
        let processes = [
            RawAudioProcess(objectID: 1, pid: mainPID, bundleID: firefox),
            RawAudioProcess(objectID: 2, pid: childPID, bundleID: nil)
        ]
        let resolved = resolve(
            bundleID: firefox,
            processes: processes,
            parents: [childPID: mainPID])
        XCTAssertEqual(resolved, [
            AudioProcess(objectID: 1, pid: mainPID),
            AudioProcess(objectID: 2, pid: childPID)
        ])
    }

    // The Firefox-shaped case the primitive exists for: ONLY the silent child
    // has a Core Audio process object (the main process never opened an audio
    // stream, so it isn't in the list). The child's own bundle id is nil, and
    // its parent is attributed via the injected AppKit closure — NOT via a
    // sibling process object. The child must still be returned.
    func testChildResolvedViaInjectedBundleIDForPID() {
        let processes = [
            RawAudioProcess(objectID: 2, pid: childPID, bundleID: nil)
        ]
        let resolved = resolve(
            bundleID: firefox,
            processes: processes,
            parents: [childPID: mainPID],
            bundleIDForPID: [mainPID: firefox])
        XCTAssertEqual(resolved, [AudioProcess(objectID: 2, pid: childPID)])
    }

    // Nothing matches: a running, audible, unrelated app and no target process
    // at all yields an empty set (the "not running / not yet audible" signal),
    // never an error.
    func testEmptyWhenNothingMatches() {
        let processes = [
            RawAudioProcess(objectID: 9, pid: 900, bundleID: "com.apple.Music")
        ]
        let resolved = resolve(bundleID: firefox, processes: processes)
        XCTAssertTrue(resolved.isEmpty)
    }

    // A nil-bundle-id process whose parent chain does NOT resolve to the target
    // (it belongs to a different app) is correctly EXCLUDED — resolution never
    // falls back to guessing.
    func testNilBundleChildOfDifferentAppExcluded() {
        let otherMain: pid_t = 300
        let otherChild: pid_t = 400
        let processes = [
            RawAudioProcess(objectID: 1, pid: mainPID, bundleID: firefox),
            RawAudioProcess(objectID: 4, pid: otherChild, bundleID: nil)
        ]
        let resolved = resolve(
            bundleID: firefox,
            processes: processes,
            parents: [otherChild: otherMain],
            bundleIDForPID: [otherMain: "com.google.Chrome"])
        // Only Firefox's own main process; the Chrome child is not attributed to Firefox.
        XCTAssertEqual(resolved, [AudioProcess(objectID: 1, pid: mainPID)])
    }

    // The parent walk climbs more than one hop (helper -> intermediate -> main)
    // and still attributes to the target.
    func testMultiHopParentWalk() {
        let intermediate: pid_t = 150
        let processes = [
            RawAudioProcess(objectID: 1, pid: mainPID, bundleID: firefox),
            RawAudioProcess(objectID: 2, pid: childPID, bundleID: nil)
        ]
        let resolved = resolve(
            bundleID: firefox,
            processes: processes,
            parents: [childPID: intermediate, intermediate: mainPID])
        XCTAssertEqual(resolved, [
            AudioProcess(objectID: 1, pid: mainPID),
            AudioProcess(objectID: 2, pid: childPID)
        ])
    }

    // The walk is capped: a chain longer than maxParentHops does not resolve
    // (and cannot loop forever on a cyclic/pathological parent map).
    func testParentWalkRespectsHopCap() {
        let processes = [
            RawAudioProcess(objectID: 2, pid: childPID, bundleID: nil)
        ]
        // childPID -> 1 more hop reaches mainPID, but cap of 1 stops before the
        // second hop that would read bundleIDForPID[mainPID].
        let resolved = resolve(
            bundleID: firefox,
            processes: processes,
            parents: [childPID: 999, 999: mainPID],
            bundleIDForPID: [mainPID: firefox],
            maxParentHops: 1)
        XCTAssertTrue(resolved.isEmpty)
    }
}
