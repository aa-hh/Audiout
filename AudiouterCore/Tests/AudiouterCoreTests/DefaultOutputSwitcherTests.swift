// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// Hermetic tests for ``DefaultOutputSwitcher`` (T5, PLAN-AIRPLAY-COEXISTENCE.md):
/// the connect-time switch-away that moves the Mac's default output off an
/// AirPlay receiver so macOS releases UDP 319/320 for our PTP helper.
///
/// **Every case below drives a fake ``SystemDefaultOutputControlling``. Nothing
/// here may ever construct ``CoreAudioDefaultOutputControl`` or otherwise reach
/// the HAL** — a human is using this Mac, and a test that moved their audio
/// output would be a bug in the test, not a flake. That is also why
/// `NativeBackend`'s `defaultOutputSwitcher` is `nil` (inert) on the designated
/// initializer and only wired on the shipping convenience init: no
/// backend-level test can reach the real write either.
@Suite struct DefaultOutputSwitcherTests {

    // MARK: Double

    /// Scripted HAL. Records every write attempt so a test can assert not just
    /// the outcome but that NOTHING was written on the no-op paths — the
    /// property that actually protects the user's selection.
    private final class FakeControl: SystemDefaultOutputControlling, @unchecked Sendable {
        let isAirPlay: Bool
        let builtIn: UInt32?
        let writeSucceeds: Bool
        private(set) var writes: [UInt32] = []

        init(isAirPlay: Bool, builtIn: UInt32? = 42, writeSucceeds: Bool = true) {
            self.isAirPlay = isAirPlay
            self.builtIn = builtIn
            self.writeSucceeds = writeSucceeds
        }

        func defaultOutputIsAirPlayClass() -> Bool { isAirPlay }
        func builtInOutputDevice() -> UInt32? { builtIn }
        func setDefaultOutputDevice(_ device: UInt32) -> Bool {
            writes.append(device)
            return writeSucceeds
        }
    }

    // MARK: - The guard that protects the user's own selection

    /// The overwhelmingly common case: the Mac's output is speakers/headphones/
    /// a USB DAC, which hold no PTP ports. There is nothing to take over, so the
    /// default output must not be touched AT ALL.
    @Test func nonAirPlayDefaultIsLeftCompletelyUntouched() {
        let control = FakeControl(isAirPlay: false)
        let outcome = DefaultOutputSwitcher(control: control).switchAwayFromAirPlay()

        #expect(outcome == .notAirPlay)
        #expect(control.writes.isEmpty, "wrote the default output device with no AirPlay session to take over")
    }

    /// The detection guard runs BEFORE anything else, so a machine with no
    /// built-in output still never sees a write on the non-AirPlay path.
    @Test func nonAirPlayDefaultDoesNotWriteEvenWithNoBuiltIn() {
        let control = FakeControl(isAirPlay: false, builtIn: nil)
        #expect(DefaultOutputSwitcher(control: control).switchAwayFromAirPlay() == .notAirPlay)
        #expect(control.writes.isEmpty)
    }

    // MARK: - The takeover itself

    /// The whole point: an AirPlay-class default output is moved to the
    /// built-in speakers (locked decision Q4=A — one predictable destination,
    /// never "the previous device", which could itself be a second AirPlay
    /// receiver holding the same ports).
    @Test func airPlayDefaultIsMovedToTheBuiltInDevice() {
        let control = FakeControl(isAirPlay: true, builtIn: 7)
        let outcome = DefaultOutputSwitcher(control: control).switchAwayFromAirPlay()

        #expect(outcome == .switched)
        #expect(control.writes == [7], "expected exactly one write, to the built-in device")
    }

    // MARK: - Failure paths (the connect proceeds regardless; T4's retry may still win)

    /// No built-in output to move to (headless / aggregate-only Mac). There is
    /// no safe destination, so nothing is written rather than guessing at one.
    @Test func noBuiltInDeviceWritesNothing() {
        let control = FakeControl(isAirPlay: true, builtIn: nil)
        let outcome = DefaultOutputSwitcher(control: control).switchAwayFromAirPlay()

        #expect(outcome == .noBuiltInDevice)
        #expect(control.writes.isEmpty)
    }

    /// The HAL refused the write (unsettable property or an error). Reported
    /// distinctly from `.noBuiltInDevice` — the write WAS attempted, which is
    /// what a live diagnosis needs to tell those two apart.
    @Test func refusedWriteReportsWriteFailed() {
        let control = FakeControl(isAirPlay: true, builtIn: 7, writeSucceeds: false)
        let outcome = DefaultOutputSwitcher(control: control).switchAwayFromAirPlay()

        #expect(outcome == .writeFailed)
        #expect(control.writes == [7])
    }
}
