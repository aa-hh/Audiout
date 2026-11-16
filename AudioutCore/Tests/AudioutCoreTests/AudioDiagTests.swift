// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation
import Testing
@testable import AudioutCore

/// Focused unit tests for ``AudioDiag``'s live-handle counter API:
/// ``AudioDiag/HandleCounter``, ``AudioDiag/handleCreated(_:)``,
/// ``AudioDiag/handleDestroyed(_:)``, and ``AudioDiag/dumpLiveHandles()``.
///
/// ## Why the mechanism is tested via a fresh `HandleCounter`, not the gated API
/// `AudioDiag.isEnabled` is a `static let` read once from `$AIRPLAY_AUDIO_DIAG`
/// and frozen for the life of the process (see `AudioDiag.swift`) — no test can
/// flip it back. No suite in this package sets that env var, but a Mac that
/// exported it hands it to `swift test` as well, so the gated test below skips
/// itself when it is on. The
/// counting mechanism (`AudioDiag.HandleCounter`) is deliberately ungated so a
/// test can construct its own instance and exercise increment/decrement/dump
/// directly, independent of that process-wide gate and of test ordering. The
/// last test below then confirms the real gated entry points
/// (`handleCreated`/`handleDestroyed`/`dumpLiveHandles`) are a true no-op
/// against the shared process-wide counters while `isEnabled == false`.
@Suite struct AudioDiagTests {

    // MARK: HandleCounter mechanism — construction

    @Test func construction_freshCounterDumpsEmptySentinel() {
        let counter = AudioDiag.HandleCounter()
        #expect(counter.dump() == "(no live handles)")
    }

    // MARK: increment

    @Test func increment_addsToNamedKind() {
        let counter = AudioDiag.HandleCounter()
        counter.increment("processTap")
        #expect(counter.dump() == "processTap=1")
        counter.increment("processTap")
        #expect(counter.dump() == "processTap=2")
    }

    @Test func increment_tracksDistinctKindsIndependently() {
        let counter = AudioDiag.HandleCounter()
        counter.increment("processTap")
        counter.increment("aggregateDevice")
        counter.increment("aggregateDevice")
        counter.increment("ioProc")
        #expect(counter.dump() == "aggregateDevice=2 ioProc=1 processTap=1")
    }

    // MARK: decrement

    @Test func decrement_netsAgainstIncrement() {
        let counter = AudioDiag.HandleCounter()
        counter.increment("processTap")
        counter.increment("processTap")
        counter.decrement("processTap")
        #expect(counter.dump() == "processTap=1")
    }

    @Test func decrement_toZero_staysVisibleInDump() {
        // A kind that nets back to 0 (created, then cleanly destroyed) is
        // still reported explicitly — "0 outstanding" is meaningful signal,
        // distinct from "this kind was never tracked at all" (the empty-dump
        // sentinel case above).
        let counter = AudioDiag.HandleCounter()
        counter.increment("ioProc")
        counter.decrement("ioProc")
        #expect(counter.dump() == "ioProc=0")
    }

    @Test func decrement_withoutMatchingIncrement_goesNegativeUnclamped() {
        // Deliberately unclamped at zero: an unmatched decrement is itself a
        // bookkeeping bug worth surfacing (e.g. double-teardown), not one to
        // hide by flooring at 0.
        let counter = AudioDiag.HandleCounter()
        counter.decrement("aggregateDevice")
        #expect(counter.dump() == "aggregateDevice=-1")
    }

    // MARK: dump-format

    @Test func dump_sortsKindsAlphabetically() {
        let counter = AudioDiag.HandleCounter()
        counter.increment("processTap")
        counter.increment("aggregateDevice")
        counter.increment("ioProc")
        #expect(counter.dump() == "aggregateDevice=1 ioProc=1 processTap=1")
    }

    // MARK: isEnabled == false no-op case (the real gated API, ambient default)

    // A Mac that exported $AIRPLAY_AUDIO_DIAG (`launchctl setenv`, for a
    // diagnostic build) hands it to the test process too, and `isEnabled`
    // cannot be switched back off, so the disabled path is unreachable there.
    // The skip reads the variable itself, the way `isEnabled` does, so
    // `isEnabled` turning on with the variable unset turns it red instead of
    // skipping it, as does a gated call writing the shared counters.
    @Test(.disabled(if: ProcessInfo.processInfo.environment["AIRPLAY_AUDIO_DIAG"] != nil,
                    "$AIRPLAY_AUDIO_DIAG is set in the test process's environment"))
    func gatedAPI_isNoOpWhenDiagnosticsDisabled() {
        #expect(!AudioDiag.isEnabled, "$AIRPLAY_AUDIO_DIAG is unset, so diagnostics must be off")

        let before = AudioDiag.dumpLiveHandles()
        #expect(before == "(no live handles)", "nothing in this package calls handleCreated/handleDestroyed outside the live Core Audio path, which hermetic tests never exercise")

        AudioDiag.handleCreated("processTap")
        AudioDiag.handleCreated("aggregateDevice")
        AudioDiag.handleCreated("ioProc")
        AudioDiag.handleDestroyed("processTap")

        // A true no-op: the shared process-wide counters are byte-for-byte
        // unchanged by calls made while disabled — no lock taken, no
        // dictionary write, on the hot audio path this models.
        #expect(AudioDiag.dumpLiveHandles() == before)
    }
}
