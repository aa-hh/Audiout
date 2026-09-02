// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// The staleness rule behind the phone's speaker row: what makes a stored
/// Bluetooth alignment count as tuned, stale, or never made.
@Suite final class BTAlignmentFreshnessTests: IsolatedSuite {

    private let noon = Date(timeIntervalSince1970: 1_756_000_000)

    // MARK: The pure rule

    @Test func noStoredEntryIsAlwaysNotSet() {
        // Even with a connect and an alignment behind it: "tuned" is decided by
        // whether the store holds an entry, and this one holds none.
        #expect(BTAlignmentFreshness.status(hasStoreEntry: false,
                                            lastConnectedAt: noon,
                                            alignedAt: noon) == .notSet)
    }

    @Test func aReconnectAfterTheAlignmentIsWhatMakesItStale() {
        #expect(BTAlignmentFreshness.status(hasStoreEntry: true,
                                            lastConnectedAt: noon.addingTimeInterval(30),
                                            alignedAt: noon) == .stale)
    }

    @Test func aligningAfterTheReconnectClearsIt() {
        #expect(BTAlignmentFreshness.status(hasStoreEntry: true,
                                            lastConnectedAt: noon,
                                            alignedAt: noon.addingTimeInterval(30)) == .tuned)
    }

    /// The launch case, and the reason the rule is written the way it is: a
    /// speaker tuned in some earlier session has a store entry but no alignment
    /// instant THIS process watched. Reading that as stale would put every
    /// tuned speaker under a stale banner on every launch.
    @Test func aStoredEntryWithNoAlignmentInstantIsTunedNotStale() {
        #expect(BTAlignmentFreshness.status(hasStoreEntry: true,
                                            lastConnectedAt: noon,
                                            alignedAt: nil) == .tuned)
        #expect(BTAlignmentFreshness.status(hasStoreEntry: true,
                                            lastConnectedAt: nil,
                                            alignedAt: nil) == .tuned)
    }

    // MARK: The settling window

    @Test func theSettleWindowCountsDownFromTheConnectAndThenStops() {
        #expect(BTAlignmentFreshness.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon) == 60)
        // Rounded UP, so a phone counting down never reaches zero while the Mac
        // still holds the window open.
        #expect(BTAlignmentFreshness.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon.addingTimeInterval(30.4)) == 30)
        #expect(BTAlignmentFreshness.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon.addingTimeInterval(59.5)) == 1)
        #expect(BTAlignmentFreshness.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon.addingTimeInterval(60)) == nil)
        #expect(BTAlignmentFreshness.settleRemainingSeconds(lastConnectedAt: nil) == nil)
    }

    // MARK: Recording

    @Test func recordingIsPerDeviceAndNotifiesOnEveryChange() {
        let freshness = BTAlignmentFreshness()
        final class Count: @unchecked Sendable {
            let lock = NSLock()
            var value = 0
        }
        let changes = Count()
        freshness.onChange = { changes.lock.withLock { changes.value += 1 } }

        freshness.noteAligned(uid: "speaker-a", at: noon)
        freshness.noteConnected(uid: "speaker-a", at: noon.addingTimeInterval(10))
        // The manual reconnect and the enumerator snapshot both report the SAME
        // link-up, moments apart. The second report must not restart the
        // settling window under a phone that is already counting it down.
        freshness.noteConnected(uid: "speaker-a", at: noon.addingTimeInterval(11))
        #expect(freshness.report(uid: "speaker-a", hasStoreEntry: true,
                                now: noon.addingTimeInterval(10)).settleRemainingSeconds == 60)
        #expect(freshness.report(uid: "speaker-a", hasStoreEntry: true,
                                now: noon.addingTimeInterval(20)).status == .stale)
        // The other speaker saw neither edge, so nothing about it moved.
        #expect(freshness.report(uid: "speaker-b", hasStoreEntry: true,
                                now: noon.addingTimeInterval(20)).status == .tuned)

        // Clearing a tuning removes the instant a later connect would be
        // measured against, so the row cannot come back reading stale.
        freshness.clearAligned(uid: "speaker-a")
        #expect(freshness.report(uid: "speaker-a", hasStoreEntry: false,
                                now: noon.addingTimeInterval(20)).status == .notSet)
        #expect(changes.lock.withLock { changes.value } == 3)
    }

    /// The echo is collapsed, but a speaker that genuinely drops and comes back
    /// is a NEW link-up and must land — otherwise a power-cycled speaker would
    /// never go stale again for the rest of the session.
    @Test func aLinkThatDroppedAndReturnedIsANewConnect() {
        let freshness = BTAlignmentFreshness()
        freshness.noteAligned(uid: "speaker-a", at: noon)
        freshness.noteConnected(uid: "speaker-a", at: noon.addingTimeInterval(-30))
        #expect(freshness.report(uid: "speaker-a", hasStoreEntry: true,
                                now: noon).status == .tuned)

        freshness.noteDisconnected(uid: "speaker-a")
        freshness.noteConnected(uid: "speaker-a", at: noon.addingTimeInterval(30))
        #expect(freshness.report(uid: "speaker-a", hasStoreEntry: true,
                                now: noon.addingTimeInterval(40)).status == .stale)
    }

    // MARK: Decision 5 — what must be true before a run can be staged

    private func room() -> [Device] {
        [
            Device(id: "local", name: "Mac", kind: .localMac, isLocalDevice: true),
            Device(id: "bt-a", name: "Kitchen", kind: .bluetooth),
            Device(id: "bt-b", name: "Study", kind: .bluetooth),
            Device(id: "cast", name: "Nest", kind: .cast),
        ]
    }

    @Test func aTargetThatIsNotPlayingIsRefusedByName() {
        let outcome = CompanionAlignmentPreconditions.evaluate(
            targetID: "bt-a", among: room(), isAudible: { $0 == "local" })
        #expect(outcome == .refused(
            "\u{201C}Kitchen\u{201D} isn't playing right now, so there's nothing to measure."))
    }

    @Test func aPlayingTargetWithNothingElseAudibleIsRefused() {
        let outcome = CompanionAlignmentPreconditions.evaluate(
            targetID: "bt-a", among: room(), isAudible: { $0 == "bt-a" })
        #expect(outcome == .refused("Nothing else is playing to compare \u{201C}Kitchen\u{201D} against."))
    }

    /// A Cast receiver plays seconds behind live, so it is never a reference —
    /// a room where it is the only other audible device has none.
    @Test func aCastReceiverIsNeverTheReference() {
        let outcome = CompanionAlignmentPreconditions.evaluate(
            targetID: "bt-a", among: room(), isAudible: { $0 == "bt-a" || $0 == "cast" })
        #expect(outcome == .refused("Nothing else is playing to compare \u{201C}Kitchen\u{201D} against."))
    }

    @Test func theMacsOwnOutputIsPreferredOverAnotherSpeaker() {
        let outcome = CompanionAlignmentPreconditions.evaluate(
            targetID: "bt-a", among: room(), isAudible: { _ in true })
        #expect(outcome == .ready(referenceID: "local"))
    }

    @Test func anotherBluetoothSpeakerIsTakenWhenTheMacIsSilent() {
        let outcome = CompanionAlignmentPreconditions.evaluate(
            targetID: "bt-a", among: room(), isAudible: { $0 == "bt-a" || $0 == "bt-b" })
        #expect(outcome == .ready(referenceID: "bt-b"))
    }

    @Test func aDeviceThatIsNotBluetoothIsNotAMeasurableTarget() {
        #expect(CompanionAlignmentPreconditions.evaluate(
            targetID: "local", among: room(), isAudible: { _ in true }) == .refused("Unknown device."))
        #expect(CompanionAlignmentPreconditions.evaluate(
            targetID: "nobody", among: room(), isAudible: { _ in true }) == .refused("Unknown device."))
    }
}
