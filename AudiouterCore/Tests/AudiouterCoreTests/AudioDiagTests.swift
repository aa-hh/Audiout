// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import XCTest
@testable import AudiouterCore

/// Focused unit tests for ``AudioDiag``'s live-handle counter API:
/// ``AudioDiag/HandleCounter``, ``AudioDiag/handleCreated(_:)``,
/// ``AudioDiag/handleDestroyed(_:)``, and ``AudioDiag/dumpLiveHandles()``.
/// `AudioDiag` had zero test coverage before this file.
///
/// ## Why the mechanism is tested via a fresh `HandleCounter`, not the gated API
/// `AudioDiag.isEnabled` is a `static let` read once from `$AIRPLAY_AUDIO_DIAG`
/// and frozen for the life of the process (see `AudioDiag.swift`) — no test can
/// flip it back, and no suite in this package ever sets that env var, so it is
/// reliably `false` for the whole `swift test` process, parallel or not. The
/// counting mechanism (`AudioDiag.HandleCounter`) is deliberately ungated so a
/// test can construct its own instance and exercise increment/decrement/dump
/// directly, independent of that process-wide gate and of test ordering. The
/// last test below then confirms the real gated entry points
/// (`handleCreated`/`handleDestroyed`/`dumpLiveHandles`) are a true no-op
/// against the shared process-wide counters under the ambient `isEnabled ==
/// false` every `swift test` run actually has.
final class AudioDiagTests: XCTestCase {

    // MARK: HandleCounter mechanism — construction

    func test_construction_freshCounterDumpsEmptySentinel() {
        let counter = AudioDiag.HandleCounter()
        XCTAssertEqual(counter.dump(), "(no live handles)")
    }

    // MARK: increment

    func test_increment_addsToNamedKind() {
        let counter = AudioDiag.HandleCounter()
        counter.increment("processTap")
        XCTAssertEqual(counter.dump(), "processTap=1")
        counter.increment("processTap")
        XCTAssertEqual(counter.dump(), "processTap=2")
    }

    func test_increment_tracksDistinctKindsIndependently() {
        let counter = AudioDiag.HandleCounter()
        counter.increment("processTap")
        counter.increment("aggregateDevice")
        counter.increment("aggregateDevice")
        counter.increment("ioProc")
        XCTAssertEqual(counter.dump(), "aggregateDevice=2 ioProc=1 processTap=1")
    }

    // MARK: decrement

    func test_decrement_netsAgainstIncrement() {
        let counter = AudioDiag.HandleCounter()
        counter.increment("processTap")
        counter.increment("processTap")
        counter.decrement("processTap")
        XCTAssertEqual(counter.dump(), "processTap=1")
    }

    func test_decrement_toZero_staysVisibleInDump() {
        // A kind that nets back to 0 (created, then cleanly destroyed) is
        // still reported explicitly — "0 outstanding" is meaningful signal,
        // distinct from "this kind was never tracked at all" (the empty-dump
        // sentinel case above).
        let counter = AudioDiag.HandleCounter()
        counter.increment("ioProc")
        counter.decrement("ioProc")
        XCTAssertEqual(counter.dump(), "ioProc=0")
    }

    func test_decrement_withoutMatchingIncrement_goesNegativeUnclamped() {
        // Deliberately unclamped at zero: an unmatched decrement is itself a
        // bookkeeping bug worth surfacing (e.g. double-teardown), not one to
        // hide by flooring at 0.
        let counter = AudioDiag.HandleCounter()
        counter.decrement("aggregateDevice")
        XCTAssertEqual(counter.dump(), "aggregateDevice=-1")
    }

    // MARK: dump-format

    func test_dump_sortsKindsAlphabetically() {
        let counter = AudioDiag.HandleCounter()
        counter.increment("processTap")
        counter.increment("aggregateDevice")
        counter.increment("ioProc")
        XCTAssertEqual(counter.dump(), "aggregateDevice=1 ioProc=1 processTap=1")
    }

    // MARK: isEnabled == false no-op case (the real gated API, ambient default)

    func test_gatedAPI_isNoOpWhenDiagnosticsDisabled() {
        // No suite in this package sets $AIRPLAY_AUDIO_DIAG, so this is the
        // real ambient state `swift test` runs under — not a mock.
        XCTAssertFalse(AudioDiag.isEnabled, "test assumes diagnostics are off in the test process")

        let before = AudioDiag.dumpLiveHandles()
        XCTAssertEqual(before, "(no live handles)", "nothing in this package calls handleCreated/handleDestroyed outside the live Core Audio path, which hermetic tests never exercise")

        AudioDiag.handleCreated("processTap")
        AudioDiag.handleCreated("aggregateDevice")
        AudioDiag.handleCreated("ioProc")
        AudioDiag.handleDestroyed("processTap")

        // A true no-op: the shared process-wide counters are byte-for-byte
        // unchanged by calls made while disabled — no lock taken, no
        // dictionary write, on the hot audio path this models.
        XCTAssertEqual(AudioDiag.dumpLiveHandles(), before)
    }
}
