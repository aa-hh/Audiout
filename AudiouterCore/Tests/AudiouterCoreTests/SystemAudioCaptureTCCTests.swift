// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudiouterCore

/// Coverage for the single most correctness-sensitive gate in the app: the read
/// every capture coordinator consults before creating ANY process tap.
///
/// WHY THIS SUITE EXISTS: this type shipped with **zero** tests while carrying
/// the decision that either sprays cold OS permission prompts (if it wrongly
/// says granted) or silently refuses all audio (if it wrongly says denied).
/// A live run proved the second failure mode was real — the app declared the
/// permission lost 55 seconds after functionally proving capture worked.
///
/// The pure `combine(audio:screen:)` truth table is exhaustively covered (all
/// 3×3 inputs) because it encodes the locked product rule and is the one part
/// testable without touching TCC at all. `combinedStatus()` itself is NOT
/// asserted against a fixed value: it reads real system state, so its answer
/// legitimately differs per machine and per grant — pinning it would produce a
/// test that passes or fails based on the developer's own privacy settings.
final class SystemAudioCaptureTCCTests: IsolatedTestCase {

    override func tearDown() {
        // The latch is deliberately one-way and process-global; leaving it set
        // would pin `effectiveStatus()` to `.granted` for every later test in
        // this process. Reset regardless of how the test exited.
        SystemAudioCaptureTCC._resetLatchForTesting()
        super.tearDown()
    }

    // MARK: - The locked truth table (all nine combinations)

    /// Rule, locked by the owner: **any bucket granted wins**; denied ONLY when
    /// both agree; everything else stays undetermined and must never be
    /// collapsed into a denial.
    func test_combine_coversTheFullTruthTable() {
        let g = SystemAudioCaptureTCC.Preflight.granted
        let d = SystemAudioCaptureTCC.Preflight.denied
        let u = SystemAudioCaptureTCC.Preflight.undetermined

        // Any granted wins — including when the other bucket explicitly denies.
        // This asymmetry is deliberate: the two lists are independent grants,
        // and holding either one genuinely authorises the tap.
        XCTAssertEqual(SystemAudioCaptureTCC.combine(audio: g, screen: g), g)
        XCTAssertEqual(SystemAudioCaptureTCC.combine(audio: g, screen: d), g)
        XCTAssertEqual(SystemAudioCaptureTCC.combine(audio: g, screen: u), g)
        XCTAssertEqual(SystemAudioCaptureTCC.combine(audio: d, screen: g), g)
        XCTAssertEqual(SystemAudioCaptureTCC.combine(audio: u, screen: g), g)

        // Denied ONLY when both agree.
        XCTAssertEqual(SystemAudioCaptureTCC.combine(audio: d, screen: d), d)

        // Everything else is undetermined — never denied. These three cases are
        // the actual bug: each one used to become `.denied`, producing a false
        // "your permission was turned off" alarm and a refused tap.
        XCTAssertEqual(SystemAudioCaptureTCC.combine(audio: u, screen: u), u)
        XCTAssertEqual(SystemAudioCaptureTCC.combine(audio: u, screen: d), u)
        XCTAssertEqual(SystemAudioCaptureTCC.combine(audio: d, screen: u), u)
    }

    /// Guard against the specific regression this whole batch exists to prevent.
    /// Stated separately from the table above so a failure names the bug rather
    /// than just a mismatched enum case.
    func test_combine_neverTurnsAnUndeterminedBucketIntoADenial() {
        let d = SystemAudioCaptureTCC.Preflight.denied
        let u = SystemAudioCaptureTCC.Preflight.undetermined
        for (audio, screen) in [(u, u), (u, d), (d, u)] {
            XCTAssertNotEqual(
                SystemAudioCaptureTCC.combine(audio: audio, screen: screen), d,
                "undetermined must never collapse to denied — that is the false-denial bug")
        }
    }

    // MARK: - The fresh-verdict latch

    func test_effectiveStatus_withoutLatch_matchesCombinedStatus() {
        SystemAudioCaptureTCC._resetLatchForTesting()
        // Compared to each other rather than to a fixed value: both read real
        // system state, so only their AGREEMENT is machine-independent.
        XCTAssertEqual(SystemAudioCaptureTCC.effectiveStatus(),
                       SystemAudioCaptureTCC.combinedStatus())
    }

    /// The trap the latch exists to close: a helper process can prove the grant
    /// is live while THIS process's TCC read is permanently stale, so without
    /// the latch the gate would refuse audio forever despite a confirmed grant.
    func test_recordFreshGrant_makesEffectiveStatusGranted() {
        SystemAudioCaptureTCC._resetLatchForTesting()
        SystemAudioCaptureTCC.recordFreshGrant(source: "unit-test")
        XCTAssertEqual(SystemAudioCaptureTCC.effectiveStatus(), .granted)
        XCTAssertTrue(SystemAudioCaptureTCC.isGranted(),
                      "the tap gate must open once a fresh grant is confirmed")
    }

    func test_latch_isIdempotent() {
        SystemAudioCaptureTCC._resetLatchForTesting()
        SystemAudioCaptureTCC.recordFreshGrant(source: "unit-test-a")
        SystemAudioCaptureTCC.recordFreshGrant(source: "unit-test-b")
        XCTAssertEqual(SystemAudioCaptureTCC.effectiveStatus(), .granted)
    }

    /// `isGranted()` gates real tap creation, so `.undetermined` MUST read as
    /// false: allowing a tap on an undecided grant lets macOS fire its own
    /// permission dialog cold, with no Setup screen in front of the user.
    func test_isGranted_isTrueOnlyWhenEffectiveStatusIsGranted() {
        SystemAudioCaptureTCC._resetLatchForTesting()
        XCTAssertEqual(SystemAudioCaptureTCC.isGranted(),
                       SystemAudioCaptureTCC.effectiveStatus() == .granted)
    }

    func test_resetSeam_actuallyClearsTheLatch() {
        SystemAudioCaptureTCC.recordFreshGrant(source: "unit-test")
        XCTAssertEqual(SystemAudioCaptureTCC.effectiveStatus(), .granted)
        SystemAudioCaptureTCC._resetLatchForTesting()
        // Proves the seam works — without which every other test in this file
        // would silently leak a latched grant into the rest of the process.
        XCTAssertEqual(SystemAudioCaptureTCC.effectiveStatus(),
                       SystemAudioCaptureTCC.combinedStatus())
    }
}
