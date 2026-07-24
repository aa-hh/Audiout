import XCTest
@testable import AudiouterCore

/// Hermetic tests for the W1-T1 process-set resolver. All fully in-memory: a
/// fake process-object list and a scripted responsible-pid walk, no Core Audio,
/// no real processes. Covers the three shapes the plan calls out — a plain
/// single-process app, Chrome-style helpers, and Firefox-style children carrying
/// the parent identity — plus the responsible-pid fallback and ordering.
final class ProcessSetResolverTests: XCTestCase {

    private func desc(_ objectID: UInt32, _ pid: pid_t, _ bundleID: String?) -> AudioProcessDescriptor {
        AudioProcessDescriptor(objectID: objectID, pid: pid, bundleID: bundleID)
    }

    private func resolver(
        _ list: [AudioProcessDescriptor],
        responsiblePID: @escaping @Sendable (pid_t) -> pid_t? = { _ in nil }
    ) -> ProcessSetResolver {
        ProcessSetResolver(enumerate: { list }, responsiblePID: responsiblePID)
    }

    // MARK: (a) plain single-process app

    func testSingleProcessAppResolvesToItsOnePID() {
        let r = resolver([
            desc(10, 501, "com.apple.Music"),
            desc(11, 777, "com.acme.OtherApp"),
        ])
        XCTAssertEqual(r.pids(forBundleID: "com.apple.Music"), [501])
    }

    func testUnknownBundleIDResolvesToEmpty() {
        let r = resolver([desc(10, 501, "com.apple.Music")])
        XCTAssertEqual(r.pids(forBundleID: "com.nope.Missing"), [])
    }

    func testEmptyProcessListResolvesToEmpty() {
        let r = resolver([])
        XCTAssertEqual(r.pids(forBundleID: "com.apple.Music"), [])
    }

    // MARK: (b) Chrome-style helpers (dotted sub-identifiers)

    func testChromeHelpersGroupToParentByPrefix() {
        let r = resolver([
            desc(1, 100, "com.google.Chrome"),
            desc(2, 101, "com.google.Chrome.helper"),
            desc(3, 102, "com.google.Chrome.helper.Renderer"),
            desc(4, 103, "com.google.Chrome.helper.GPU"),
            // A different app that shares a leading token but is NOT a sub-id.
            desc(5, 200, "com.google.ChromeCanary"),
            desc(6, 201, "org.mozilla.firefox"),
        ])
        let pids = r.pids(forBundleID: "com.google.Chrome")
        XCTAssertEqual(pids.first, 100, "main process must sort first")
        XCTAssertEqual(Set(pids), [100, 101, 102, 103])
        XCTAssertFalse(pids.contains(200), "com.google.ChromeCanary must NOT match com.google.Chrome")
        XCTAssertFalse(pids.contains(201))
    }

    func testPrefixMatchRequiresDotBoundaryNotBareStringPrefix() {
        // "com.google.Chrome" is a string-prefix of "com.google.ChromeCanary"
        // but not a bundle-ID ancestor; only the dot-boundary form counts.
        let r = resolver([desc(1, 200, "com.google.ChromeCanary")])
        XCTAssertEqual(r.pids(forBundleID: "com.google.Chrome"), [])
    }

    // MARK: (c) Firefox-style children carrying the parent identity

    func testFirefoxChildrenShareParentBundleID() {
        let r = resolver([
            desc(1, 300, "org.mozilla.firefox"),   // main
            desc(2, 301, "org.mozilla.firefox"),   // content child, same id
            desc(3, 302, "org.mozilla.firefox"),   // another child
            desc(4, 400, "com.apple.Music"),
        ])
        let pids = r.pids(forBundleID: "org.mozilla.firefox")
        XCTAssertEqual(Set(pids), [300, 301, 302])
        XCTAssertFalse(pids.contains(400))
    }

    // MARK: responsible-pid walk for un-prefixed helpers

    func testResponsiblePIDWalkClaimsChildWithNoMatchingBundleID() {
        // A helper reports a bundle ID that neither equals nor sub-IDs the parent
        // (or none at all); only the responsible-pid walk can place it.
        let r = resolver(
            [
                desc(1, 500, "com.electron.app"),   // main
                desc(2, 501, nil),                   // audio child, no bundle ID
                desc(3, 999, "com.unrelated.thing"), // unrelated, owned by itself
            ],
            responsiblePID: { pid in pid == 501 ? 500 : nil })
        let pids = r.pids(forBundleID: "com.electron.app")
        XCTAssertEqual(pids.first, 500)
        XCTAssertEqual(Set(pids), [500, 501])
        XCTAssertFalse(pids.contains(999))
    }

    func testResponsiblePIDWalkIgnoredWhenOwnerIsADifferentApp() {
        let r = resolver(
            [
                desc(1, 500, "com.electron.app"),
                desc(2, 501, nil),
            ],
            responsiblePID: { _ in 4242 }) // owner isn't in the list / not our app
        XCTAssertEqual(r.pids(forBundleID: "com.electron.app"), [500])
    }

    // MARK: ordering + dedup

    func testMainProcessSortsBeforeHelpersAndPIDsDeduped() {
        let r = resolver([
            desc(1, 102, "com.google.Chrome.helper"), // helper listed first
            desc(2, 100, "com.google.Chrome"),        // main listed later
            desc(3, 102, "com.google.Chrome.helper"), // duplicate pid
        ])
        XCTAssertEqual(r.pids(forBundleID: "com.google.Chrome"), [100, 102])
    }

    // MARK: adapter conforms to the injected seam type

    func testAsResolverProducesTheSameResult() {
        let r = resolver([
            desc(1, 100, "com.google.Chrome"),
            desc(2, 101, "com.google.Chrome.helper"),
        ])
        let seam: AppProcessResolver = r.asResolver()
        XCTAssertEqual(Set(seam("com.google.Chrome")), [100, 101])
    }

    func testResolverReflectsLiveEnumerationOnEachCall() {
        // The enumerate closure is invoked per call, so a process appearing
        // between calls is picked up without rebuilding the resolver.
        let box = Box([desc(1, 100, "com.google.Chrome")])
        let r = ProcessSetResolver(enumerate: { box.value }, responsiblePID: { _ in nil })
        XCTAssertEqual(r.pids(forBundleID: "com.google.Chrome"), [100])
        box.value.append(desc(2, 101, "com.google.Chrome.helper"))
        XCTAssertEqual(Set(r.pids(forBundleID: "com.google.Chrome")), [100, 101])
    }

    private final class Box: @unchecked Sendable {
        var value: [AudioProcessDescriptor]
        init(_ value: [AudioProcessDescriptor]) { self.value = value }
    }
}
