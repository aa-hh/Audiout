// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation
import Testing

/// Opt-in gate for tests that drive REAL Core Audio against the Mac's actual
/// output hardware.
///
/// WHY — and NOT for the reason you might assume. This gate is about
/// FLAKINESS and hardware dependence, not CPU. Measured on an 8-core M-series
/// with a correct `ps` TIME parse: running these tests costs **0.9 seconds** of
/// `coreaudiod` CPU (0.01s with them skipped), and the entire suite costs about
/// **10 CPU-seconds of `coreaudiod` across an 87-second run — ~11% of ONE core,
/// roughly 1.4% of the machine**. Core Audio is NOT a meaningful part of this
/// suite's cost; the cost is Swift test execution itself. Earlier claims of
/// "coreaudiod at 38-45%" came from instantaneous `ps` %CPU samples, which
/// catch brief spikes and badly overstate sustained load — do not cite them.
///
/// The real justification: these seven tests drive actual output hardware, so
/// their timing depends on a shared, machine-wide daemon and on whatever else
/// the Mac is doing. That is the documented cause of three unrelated timing
/// tests flaking under `--parallel` (`testMuteStashAndRestore`,
/// `testLevelEmissionIsCoalescedToDisplayCadence`,
/// `testCaptureCrashOverBudgetSurfacesError`), which fail on a busy machine
/// with entirely correct code. A gate makes routine verification deterministic
/// and independent of whether the machine has usable audio output at all.
///
/// WHY GATED RATHER THAN FAKED: these tests exist precisely to exercise the
/// CONCRETE `LocalPlaybackEngine` — `LocalPlaybackControlling` is the protocol
/// that fakes already implement, and `NativeBackend`'s own tests use those
/// fakes. Swapping in a spy here would delete the only coverage of the real
/// `AVAudioEngine` graph, which is the thing this file is for. So the real
/// tests are kept, verbatim, and simply do not run in routine verification.
///
/// The standing project rule this implements: audio tests are fine when run
/// DELIBERATELY while working on a feature, and must never be baked into
/// automated/routine build verification.
///
/// HOW IT IS APPLIED (swift-testing). Under XCTest this gate was a
/// `skipUnlessEnabled()` call placed in the ONE helper every hardware test goes
/// through (`makeStartedEngine()`), so a newly added hardware test inherited
/// the gate instead of quietly reintroducing the hardware load. swift-testing
/// evaluates skip conditions as **traits, before the test body runs**, so a
/// call inside a helper can no longer do this. The equivalent single choke
/// point is a **suite-level trait**: put every real-hardware test inside one
/// nested suite that carries `.enabled(if:)`, and a test added to that suite is
/// gated automatically, with nothing to remember per test.
///
/// ```swift
/// @Suite struct LocalPlaybackEngineTests {
///
///     // Pure/static tests that need no hardware stay out here and always run.
///     @Test func isFollowableTransportRejectsAirPlay() { ... }
///
///     /// Everything that drives a real `AVAudioEngine` against the Mac's
///     /// actual output lives in here. The trait is the whole gate — do not
///     /// add per-test `.enabled(if:)`, and do not move a hardware test out of
///     /// this suite.
///     @Suite(AudioHardwareTestGate.trait)
///     struct RealHardware {
///         @Test func startedEngineProducesOutput() throws {
///             let engine = try makeStartedEngine()   // no gate call in the body
///             ...
///         }
///     }
/// }
/// ```
///
/// Notes on the applied shape:
///  - `.enabled(if:)` on a suite applies to every test in it, including tests
///    in suites nested further inside. A per-`@Test` trait does not inherit,
///    which is why the suite-level form is the required shape here.
///  - The gate's skip *reason* still surfaces per test in the output
///    (`Test x() skipped: "Real Core Audio hardware test…"`), so the lost
///    coverage stays legible exactly as it did under `XCTSkipUnless`.
///  - `makeStartedEngine()` (and any other shared helper) moves into the nested
///    suite alongside the tests that use it, and its `try
///    AudioHardwareTestGate.skipUnlessEnabled()` line is deleted — the trait
///    has already made that decision by the time the body runs.
///  - The trait condition is evaluated at discovery time, so it must not depend
///    on per-test state. Reading the environment (all this does) is fine.
///
/// Run them:
/// ```
/// AIRPLAY_AUDIO_HARDWARE_TESTS=1 swift test --filter LocalPlaybackEngineTests
/// ```
/// Without the variable they report as skipped — visibly absent, not silently
/// passing, so the lost coverage is always legible in the test output.
enum AudioHardwareTestGate {

    /// Sibling knob to `AIRPLAY_PERMISSIONS` (`PermissionMode.environmentVariableName`),
    /// which simulates the TCC seams — same idea, same `AIRPLAY_`-prefixed
    /// convention: an environment variable that changes what the test process
    /// is willing to touch on the real machine.
    static let environmentVariableName = "AIRPLAY_AUDIO_HARDWARE_TESTS"

    /// True only when explicitly opted in. Deliberately strict — any value other
    /// than `1` reads as "off", so a stray or empty assignment cannot silently
    /// put hardware-dependent tests back into everyone's routine runs.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[environmentVariableName] == "1"
    }

    /// The reason shown against each skipped test.
    static let skipReason =
        "Real Core Audio hardware test. Set \(environmentVariableName)=1 to run "
        + "(drives actual output hardware; excluded from routine verification "
        + "because its timing depends on the machine, not because it is slow)."

    /// The gate, as a swift-testing suite trait. Apply it to the ONE nested
    /// suite that holds every real-hardware test — see the file comment above
    /// for the exact shape. This is the whole gate; there is nothing left to
    /// call from a test body.
    static var trait: ConditionTrait {
        .enabled(if: isEnabled, Comment(rawValue: skipReason))
    }
}
