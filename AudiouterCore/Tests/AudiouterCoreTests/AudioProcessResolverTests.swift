import XCTest
@testable import AudiouterCore

#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// Hermetic tests for ``AudioProcessResolver`` (T1). Both live-system facts are
/// injected — a fixed Core Audio object list and a fixed (possibly cyclic)
/// ``ProcessTreeSnapshot`` — so the whole resolution runs with no real HAL and
/// no real process tree. Pure logic + injected fakes, so plain `XCTestCase`
/// (no `UserDefaults`/temp-dir shared state → no `IsolatedTestCase`), matching
/// ``PerAppCaptureCoordinatorTests`` / ``NativeCaptureCoordinatorTests``.
final class AudioProcessResolverTests: XCTestCase {

    // MARK: Helpers

    /// Build a resolver over a fixed object list + fixed tree.
    private func makeResolver(
        objects: [AudioProcessObject],
        tree: ProcessTreeSnapshot,
        maxDepth: Int = AudioProcessResolver.defaultMaxDepth
    ) -> AudioProcessResolver {
        AudioProcessResolver(
            enumerateAudioProcessObjects: { objects },
            snapshotProcessTree: { tree },
            maxDepth: maxDepth)
    }

    private func object(_ objectID: AudioObjectID, pid: pid_t) -> AudioProcessObject {
        AudioProcessObject(objectID: objectID, pid: pid)
    }

    // MARK: - Single-process app: no children, exactly its own object.

    func testSingleProcessReturnsExactlyItsOwnObject() {
        // No children anywhere; the app is one process, pid 1000, with one
        // audio object. An unrelated process (9999) also has an object and must
        // NOT be returned.
        let resolver = makeResolver(
            objects: [object(501, pid: 1000), object(999, pid: 9999)],
            tree: ProcessTreeSnapshot(childrenByParent: [:]))

        XCTAssertEqual(resolver.resolveAudioProcessObjects(forPID: 1000), [501])
        // The descendant set of a childless pid is just itself.
        XCTAssertEqual(resolver.descendantPIDs(ofPID: 1000), [1000])
    }

    // MARK: - The Firefox bug: parent + 2 children, only ONE child is audible.

    func testMultiProcessReturnsOnlyTheAudibleChildObject() {
        // Main process 1000 has NO audio object (it never opened a stream — the
        // exact Firefox/Chrome shape). Its two children are 2000 and 3000; only
        // 3000 is actually playing audio, so only 3000 has an object.
        let resolver = makeResolver(
            objects: [object(777, pid: 3000)],
            tree: ProcessTreeSnapshot(childrenByParent: [1000: [2000, 3000]]))

        // The single-pid resolver would have targeted 1000 (silent) and found
        // nothing. This returns the child's object instead — the fix.
        XCTAssertEqual(resolver.resolveAudioProcessObjects(forPID: 1000), [777])
        XCTAssertEqual(resolver.descendantPIDs(ofPID: 1000), [1000, 2000, 3000])
    }

    func testMultiProcessReturnsBothMainAndChildWhenBothAudible() {
        // Main AND a child both have objects → both come back.
        let resolver = makeResolver(
            objects: [object(800, pid: 1000), object(777, pid: 3000)],
            tree: ProcessTreeSnapshot(childrenByParent: [1000: [2000, 3000]]))

        XCTAssertEqual(resolver.resolveAudioProcessObjects(forPID: 1000), [800, 777])
    }

    // MARK: - Non-app rootPID guard (F4, T1 adversarial review 2026-07-24).

    /// A `rootPID <= 1` (0 = kernel_task, 1 = launchd) must resolve to the EMPTY
    /// set at BOTH public entry points, EVEN when launchd (pid 1) is the parent
    /// of audible processes — i.e. the guard must fire BEFORE the descendant walk
    /// so a malformed upstream pid can never mass-match launchd's whole tree.
    func testNonAppRootPIDResolvesToEmpty() {
        // pid 1 (launchd) parents 2000 and 3000, both audible. Without the
        // public-entry guard, resolving from pid 1 would return {900, 777} and
        // descendantPIDs would return {1, 2000, 3000} — a mass mis-redirect.
        let resolver = makeResolver(
            objects: [object(900, pid: 2000), object(777, pid: 3000)],
            tree: ProcessTreeSnapshot(childrenByParent: [1: [2000, 3000]]))

        XCTAssertEqual(resolver.resolveAudioProcessObjects(forPID: 1), [],
                       "rootPID 1 (launchd) must resolve to empty, never launchd's audible children")
        XCTAssertEqual(resolver.descendantPIDs(ofPID: 1), [],
                       "descendantPIDs(1) must be empty — the guard fires before the walk")
        XCTAssertEqual(resolver.resolveAudioProcessObjects(forPID: 0), [],
                       "rootPID 0 (kernel_task) must resolve to empty")
        // Sanity: a REAL app pid in the same tree still resolves normally.
        XCTAssertEqual(resolver.resolveAudioProcessObjects(forPID: 2000), [900])
    }

    // MARK: - Deep tree: a grandchild is reached via the transitive walk.

    func testDeepTreeReachesGrandchildObject() {
        // 1000 → 2000 → 3000 (grandchild). Only the main and the grandchild are
        // audible; the intermediate 2000 is silent. A one-level walk would miss
        // 3000 — the transitive walk includes it.
        let resolver = makeResolver(
            objects: [object(800, pid: 1000), object(900, pid: 3000), object(111, pid: 4242)],
            tree: ProcessTreeSnapshot(childrenByParent: [1000: [2000], 2000: [3000]]))

        XCTAssertEqual(resolver.resolveAudioProcessObjects(forPID: 1000), [800, 900])
        XCTAssertEqual(resolver.descendantPIDs(ofPID: 1000), [1000, 2000, 3000])
    }

    // MARK: - Zero matches.

    func testNoMatchingObjectsReturnsEmptySet() {
        // The app's tree (1000 → 2000) exists, but neither pid has an audio
        // object; all live objects belong to unrelated processes.
        let resolver = makeResolver(
            objects: [object(1, pid: 5000), object(2, pid: 6000)],
            tree: ProcessTreeSnapshot(childrenByParent: [1000: [2000]]))

        XCTAssertEqual(resolver.resolveAudioProcessObjects(forPID: 1000), [])
    }

    func testEmptyObjectListReturnsEmptySet() {
        // No live Core Audio process objects at all → empty, not an error.
        let resolver = makeResolver(
            objects: [],
            tree: ProcessTreeSnapshot(childrenByParent: [1000: [2000]]))

        XCTAssertEqual(resolver.resolveAudioProcessObjects(forPID: 1000), [])
    }

    func testUnknownRootPIDReturnsItsOwnObjectIfAny() {
        // A pid absent from the tree entirely (e.g. it just quit) has no known
        // children — it resolves to just its own object if one exists, and to
        // empty if not. Neither path crashes.
        let resolver = makeResolver(
            objects: [object(42, pid: 1000)],
            tree: ProcessTreeSnapshot(childrenByParent: [7: [8]]))
        XCTAssertEqual(resolver.resolveAudioProcessObjects(forPID: 1000), [42])

        let resolverNoObject = makeResolver(
            objects: [object(42, pid: 2000)],
            tree: ProcessTreeSnapshot(childrenByParent: [7: [8]]))
        XCTAssertEqual(resolverNoObject.resolveAudioProcessObjects(forPID: 1000), [])
    }

    // MARK: - Cycle safety: a malformed tree with a cycle terminates.

    func testCycleInTreeDoesNotHangAndReturnsFiniteSet() {
        // 2000 ↔ 3000 form a cycle below the root; without the visited-set this
        // BFS would loop forever. It must terminate and return the finite
        // reachable set.
        let cyclic = ProcessTreeSnapshot(childrenByParent: [
            1000: [2000],
            2000: [3000],
            3000: [2000],   // back-edge → cycle
        ])
        let resolver = makeResolver(
            objects: [object(10, pid: 1000), object(20, pid: 2000), object(30, pid: 3000),
                      object(99, pid: 9999)],
            tree: cyclic)

        // Reaching this assertion at all proves it terminated.
        XCTAssertEqual(resolver.resolveAudioProcessObjects(forPID: 1000), [10, 20, 30])
        XCTAssertEqual(resolver.descendantPIDs(ofPID: 1000), [1000, 2000, 3000])
    }

    func testSelfLoopDoesNotHang() {
        // A pid that is its own child (a degenerate self-cycle). Terminates,
        // returns just itself.
        let selfLoop = ProcessTreeSnapshot(childrenByParent: [1000: [1000]])
        XCTAssertEqual(
            AudioProcessResolver.descendants(ofPID: 1000, in: selfLoop, maxDepth: 5),
            [1000])
    }

    func testTwoNodeCycleAtRootTerminates() {
        // 1000 ↔ 2000 mutual-parent cycle. BFS from 1000 visits 2000, whose
        // only child (1000) is already visited → stop.
        let mutual = ProcessTreeSnapshot(childrenByParent: [1000: [2000], 2000: [1000]])
        XCTAssertEqual(
            AudioProcessResolver.descendants(ofPID: 1000, in: mutual, maxDepth: 5),
            [1000, 2000])
    }

    // MARK: - Hop cap: the walk stops after maxDepth levels.

    func testHopCapTruncatesDeepChain() {
        // A straight chain deeper than the cap: 1 → 2 → 3 → 4 → 5 → 6.
        let chain = ProcessTreeSnapshot(childrenByParent: [
            1: [2], 2: [3], 3: [4], 4: [5], 5: [6],
        ])
        // maxDepth 2 ⇒ root + 2 hops ⇒ {1, 2, 3}; 4/5/6 are beyond the cap.
        XCTAssertEqual(
            AudioProcessResolver.descendants(ofPID: 1, in: chain, maxDepth: 2),
            [1, 2, 3])
        // The full default depth (5) reaches the whole chain.
        XCTAssertEqual(
            AudioProcessResolver.descendants(ofPID: 1, in: chain, maxDepth: 5),
            [1, 2, 3, 4, 5, 6])
    }

    func testHopCapAppliesThroughResolver() {
        // The cap is honoured end-to-end: an object on a pid beyond the cap is
        // excluded; one within it is included. (Real app pids 1001…1004 — the
        // public entry point guards rootPID <= 1, so the chain root must be a
        // real pid; the hop-cap behaviour under test is independent of the
        // specific pid values.)
        let chain = ProcessTreeSnapshot(childrenByParent: [1001: [1002], 1002: [1003], 1003: [1004]])
        let resolver = makeResolver(
            objects: [object(300, pid: 1003), object(400, pid: 1004)],
            tree: chain,
            maxDepth: 2)   // reaches pid 1003 (2 hops), not pid 1004 (3 hops)

        XCTAssertEqual(resolver.resolveAudioProcessObjects(forPID: 1001), [300])
    }

    func testZeroMaxDepthReturnsRootOnly() {
        let tree = ProcessTreeSnapshot(childrenByParent: [1000: [2000]])
        XCTAssertEqual(
            AudioProcessResolver.descendants(ofPID: 1000, in: tree, maxDepth: 0),
            [1000])
    }

    // MARK: - ProcessTreeSnapshot construction.

    func testSnapshotFromParentPairsBuildsAdjacencyAndDropsSelfParent() {
        // pid 1 is self-parented (kernel/degenerate) — it must not seed a
        // self-cycle; every other row becomes a child edge.
        let tree = ProcessTreeSnapshot(parentPairs: [
            (pid: 1, ppid: 1),        // self-parent → dropped
            (pid: 100, ppid: 1),
            (pid: 200, ppid: 100),
            (pid: 300, ppid: 100),
        ])
        XCTAssertEqual(Set(tree.children(of: 1)), [100])
        XCTAssertEqual(Set(tree.children(of: 100)), [200, 300])
        XCTAssertEqual(tree.children(of: 999), [])   // unknown pid → no children
        // Self-parent dropped ⇒ walking from 1 doesn't loop on itself.
        XCTAssertEqual(
            AudioProcessResolver.descendants(ofPID: 1, in: tree, maxDepth: 5),
            [1, 100, 200, 300])
    }
}
