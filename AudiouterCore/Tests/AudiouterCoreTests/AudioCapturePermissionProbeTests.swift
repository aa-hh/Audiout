// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// Coverage for the fast-path gate `CoreAudioTonePermissionProbe.runProbe()`
/// uses to decide whether it can trust a fast `.granted` TCC read or must run
/// the audible functional probe again (T8).
///
/// WHY THIS EXISTS: a stale, cdhash-pinned TCC grant can read `.granted` for a
/// rebuilt binary that macOS will actually refuse to honor — Settings shows
/// "on," capture silently fails. `functionalGrantProbe()` is the self-test
/// that catches this for real, but it plays an audible ~440 Hz tone, so it
/// can't run on every check. `shouldRunFunctionalProbe(tccStatus:storedIdentity:currentIdentity:)`
/// is the pure decision the fast path is gated on — asserted directly here,
/// with no Core Audio, no TCC, no tone, mirroring how
/// `SystemAudioCaptureTCCTests` covers `combine(audio:screen:)` in isolation.
///
/// `@available` sits on each `@Test` (not the `@Suite` type) because the
/// `Suite` macro rejects a type-level `@available` — the same convention
/// `NativeCaptureCoordinatorTests` uses for its own 14.2+ cases.
@Suite struct AudioCapturePermissionProbeTests {

    // MARK: - .denied is out of scope (short-circuited by the caller)

    /// `.denied` never reaches this function in `runProbe()` — it's handled
    /// before the identity comparison — but the function's own contract still
    /// says "run the probe" for it, so a caller that mistakenly routed denied
    /// through here fails safe rather than trusting a denial as a skip signal.
    @available(macOS 14.2, *)
    @Test func deniedStatus_stillSaysRunTheProbe() {
        #expect(CoreAudioTonePermissionProbe.shouldRunFunctionalProbe(
            tccStatus: .denied, storedIdentity: "same", currentIdentity: "same"))
    }

    // MARK: - .undetermined / nil always need the functional probe

    @available(macOS 14.2, *)
    @Test func undeterminedStatus_alwaysRunsTheFunctionalProbe() {
        #expect(CoreAudioTonePermissionProbe.shouldRunFunctionalProbe(
            tccStatus: .undetermined, storedIdentity: "same", currentIdentity: "same"))
    }

    @available(macOS 14.2, *)
    @Test func noTCCReadAtAll_alwaysRunsTheFunctionalProbe() {
        #expect(CoreAudioTonePermissionProbe.shouldRunFunctionalProbe(
            tccStatus: nil, storedIdentity: "same", currentIdentity: "same"))
    }

    // MARK: - .granted: gated on identity match — the actual bug fix

    /// The fast path: TCC says granted AND the running binary is the exact one
    /// that already proved it out loud. No tone plays.
    @available(macOS 14.2, *)
    @Test func granted_unchangedIdentity_takesTheFastPath() {
        #expect(!CoreAudioTonePermissionProbe.shouldRunFunctionalProbe(
            tccStatus: .granted, storedIdentity: "cdhash-abc", currentIdentity: "cdhash-abc"))
    }

    /// The bug this task fixes: TCC says granted, but the binary running now
    /// is NOT the one that proved it (a rebuild). Must re-run the functional
    /// probe rather than trusting the stale grant.
    @available(macOS 14.2, *)
    @Test func granted_changedIdentity_runsTheFunctionalProbe() {
        #expect(CoreAudioTonePermissionProbe.shouldRunFunctionalProbe(
            tccStatus: .granted, storedIdentity: "cdhash-old", currentIdentity: "cdhash-new"))
    }

    /// No fingerprint has ever been proven yet (first launch after this fix
    /// ships, or a `.granted` reached from some path that never latched one).
    /// Must not trust the fast path on an absent proof.
    @available(macOS 14.2, *)
    @Test func granted_noStoredIdentity_runsTheFunctionalProbe() {
        #expect(CoreAudioTonePermissionProbe.shouldRunFunctionalProbe(
            tccStatus: .granted, storedIdentity: nil, currentIdentity: "cdhash-new"))
    }

    /// The mirror case: a stored identity exists but the CURRENT read failed
    /// (unsigned build, API error). Can't prove a match against nothing, so
    /// this must not silently take the fast path.
    @available(macOS 14.2, *)
    @Test func granted_noCurrentIdentity_runsTheFunctionalProbe() {
        #expect(CoreAudioTonePermissionProbe.shouldRunFunctionalProbe(
            tccStatus: .granted, storedIdentity: "cdhash-old", currentIdentity: nil))
    }

    @available(macOS 14.2, *)
    @Test func granted_bothIdentitiesNil_runsTheFunctionalProbe() {
        #expect(CoreAudioTonePermissionProbe.shouldRunFunctionalProbe(
            tccStatus: .granted, storedIdentity: nil, currentIdentity: nil))
    }
}
