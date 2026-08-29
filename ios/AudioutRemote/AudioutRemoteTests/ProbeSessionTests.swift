// Copyright (c) 2026 ahh. All rights reserved.

import Foundation
import Testing
@testable import AudioutRemote

/// `ProbeSession`'s ambient boundary — the one piece of the run's timing that
/// is pure arithmetic and can be checked without a microphone. Getting it
/// wrong is quiet: too late a boundary feeds the analyzer a slice with the
/// sweeps already in it, which is no longer a description of the room.
@Suite struct ProbeSessionTests {

    @Test("The boundary sits a guard interval before the sweeps entered the feed")
    func subtractsTheGuardInterval() {
        // Sweeps entered 1.0 s into the tape, so the ambient slice ends at
        // 0.75 s: 36_000 samples at 48 kHz.
        let end = ProbeSession.ambientEndSample(startedAfter: 1.0, sampleRate: 48_000,
                                                captureCount: 480_000)
        #expect(end == 36_000)
    }

    @Test("No reported start means no ambient slice")
    func unknownStartYieldsZero() {
        // 0 is the analyzer's documented "boundary unknown" — it measures
        // unweighted, which is a normal outcome, not a failure.
        let end = ProbeSession.ambientEndSample(startedAfter: nil, sampleRate: 48_000,
                                                captureCount: 480_000)
        #expect(end == 0)
    }

    @Test("The boundary never runs past the end of the tape")
    func clampsToCaptureLength() {
        let end = ProbeSession.ambientEndSample(startedAfter: 10, sampleRate: 48_000,
                                                captureCount: 24_000)
        #expect(end == 24_000)
    }

    @Test("A start inside the guard interval leaves nothing probe-free")
    func startBeforeGuardYieldsZero() {
        let end = ProbeSession.ambientEndSample(startedAfter: 0.1, sampleRate: 48_000,
                                                captureCount: 480_000)
        #expect(end == 0)
    }
}
