// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

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
extension SerializedSharedState {
    @Suite final class SystemAudioCaptureTCCTests: IsolatedSuite {

        deinit {
            // The latch is deliberately one-way and process-global; leaving it set
            // would pin `effectiveStatus()` to `.granted` for every later test in
            // this process. Reset regardless of how the test exited. Same
            // rationale applies to the proven-code-identity fingerprint (T8).
            SystemAudioCaptureTCC._resetLatchForTesting()
            SystemAudioCaptureTCC._resetProvenCodeIdentityForTesting()
        }

        // MARK: - The locked truth table (all nine combinations)

        /// Rule, locked by the owner: **any bucket granted wins**; denied ONLY when
        /// both agree; everything else stays undetermined and must never be
        /// collapsed into a denial.
        @Test func combine_coversTheFullTruthTable() {
            let g = SystemAudioCaptureTCC.Preflight.granted
            let d = SystemAudioCaptureTCC.Preflight.denied
            let u = SystemAudioCaptureTCC.Preflight.undetermined

            // Any granted wins — including when the other bucket explicitly denies.
            // This asymmetry is deliberate: the two lists are independent grants,
            // and holding either one genuinely authorises the tap.
            #expect(SystemAudioCaptureTCC.combine(audio: g, screen: g) == g)
            #expect(SystemAudioCaptureTCC.combine(audio: g, screen: d) == g)
            #expect(SystemAudioCaptureTCC.combine(audio: g, screen: u) == g)
            #expect(SystemAudioCaptureTCC.combine(audio: d, screen: g) == g)
            #expect(SystemAudioCaptureTCC.combine(audio: u, screen: g) == g)

            // Denied ONLY when both agree.
            #expect(SystemAudioCaptureTCC.combine(audio: d, screen: d) == d)

            // Everything else is undetermined — never denied. These three cases are
            // the actual bug: each one used to become `.denied`, producing a false
            // "your permission was turned off" alarm and a refused tap.
            #expect(SystemAudioCaptureTCC.combine(audio: u, screen: u) == u)
            #expect(SystemAudioCaptureTCC.combine(audio: u, screen: d) == u)
            #expect(SystemAudioCaptureTCC.combine(audio: d, screen: u) == u)
        }

        /// Guard against the specific regression this whole batch exists to prevent.
        /// Stated separately from the table above so a failure names the bug rather
        /// than just a mismatched enum case.
        @Test func combine_neverTurnsAnUndeterminedBucketIntoADenial() {
            let d = SystemAudioCaptureTCC.Preflight.denied
            let u = SystemAudioCaptureTCC.Preflight.undetermined
            for (audio, screen) in [(u, u), (u, d), (d, u)] {
                #expect(
                    SystemAudioCaptureTCC.combine(audio: audio, screen: screen) != d,
                    "undetermined must never collapse to denied — that is the false-denial bug")
            }
        }

        // MARK: - The fresh-verdict latch

        @Test func effectiveStatus_withoutLatch_matchesCombinedStatus() {
            SystemAudioCaptureTCC._resetLatchForTesting()
            // Compared to each other rather than to a fixed value: both read real
            // system state, so only their AGREEMENT is machine-independent.
            #expect(SystemAudioCaptureTCC.effectiveStatus() ==
                    SystemAudioCaptureTCC.combinedStatus())
        }

        /// The trap the latch exists to close: a helper process can prove the grant
        /// is live while THIS process's TCC read is permanently stale, so without
        /// the latch the gate would refuse audio forever despite a confirmed grant.
        @Test func recordFreshGrant_makesEffectiveStatusGranted() {
            SystemAudioCaptureTCC._resetLatchForTesting()
            SystemAudioCaptureTCC.recordFreshGrant(source: "unit-test")
            #expect(SystemAudioCaptureTCC.effectiveStatus() == .granted)
            #expect(SystemAudioCaptureTCC.isGranted(),
                    "the tap gate must open once a fresh grant is confirmed")
        }

        @Test func latch_isIdempotent() {
            SystemAudioCaptureTCC._resetLatchForTesting()
            SystemAudioCaptureTCC.recordFreshGrant(source: "unit-test-a")
            SystemAudioCaptureTCC.recordFreshGrant(source: "unit-test-b")
            #expect(SystemAudioCaptureTCC.effectiveStatus() == .granted)
        }

        /// `isGranted()` gates real tap creation, so `.undetermined` MUST read as
        /// false: allowing a tap on an undecided grant lets macOS fire its own
        /// permission dialog cold, with no Setup screen in front of the user.
        @Test func isGranted_isTrueOnlyWhenEffectiveStatusIsGranted() {
            SystemAudioCaptureTCC._resetLatchForTesting()
            #expect(SystemAudioCaptureTCC.isGranted() ==
                    (SystemAudioCaptureTCC.effectiveStatus() == .granted))
        }

        @Test func resetSeam_actuallyClearsTheLatch() {
            SystemAudioCaptureTCC.recordFreshGrant(source: "unit-test")
            #expect(SystemAudioCaptureTCC.effectiveStatus() == .granted)
            SystemAudioCaptureTCC._resetLatchForTesting()
            // Proves the seam works — without which every other test in this file
            // would silently leak a latched grant into the rest of the process.
            #expect(SystemAudioCaptureTCC.effectiveStatus() ==
                    SystemAudioCaptureTCC.combinedStatus())
        }

        // MARK: - Proven code-identity fingerprint (T8)

        @Test func provenCodeIdentity_startsNil() {
            SystemAudioCaptureTCC._resetProvenCodeIdentityForTesting()
            #expect(SystemAudioCaptureTCC.provenCodeIdentity() == nil)
        }

        @Test func recordProvenCodeIdentity_isReadableAfterRecording() {
            SystemAudioCaptureTCC._resetProvenCodeIdentityForTesting()
            SystemAudioCaptureTCC.recordProvenCodeIdentity("cdhash-abc123")
            #expect(SystemAudioCaptureTCC.provenCodeIdentity() == "cdhash-abc123")
        }

        @Test func recordProvenCodeIdentity_overwritesAnEarlierValue() {
            SystemAudioCaptureTCC._resetProvenCodeIdentityForTesting()
            SystemAudioCaptureTCC.recordProvenCodeIdentity("cdhash-old")
            SystemAudioCaptureTCC.recordProvenCodeIdentity("cdhash-new")
            #expect(SystemAudioCaptureTCC.provenCodeIdentity() == "cdhash-new")
        }

        @Test func resetSeam_actuallyClearsTheProvenIdentity() {
            SystemAudioCaptureTCC.recordProvenCodeIdentity("cdhash-abc123")
            SystemAudioCaptureTCC._resetProvenCodeIdentityForTesting()
            #expect(SystemAudioCaptureTCC.provenCodeIdentity() == nil)
        }
    }
}
