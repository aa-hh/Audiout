// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AudiouterProtocol
@testable import AudiouterCore

/// The BT auto-cal probe (spike): `AlignmentProbeSession`'s mute choreography
/// against a manual clock, the three companion commands' validation, and the
/// trim-sign correction — the one piece of math the phone deliberately does
/// NOT own.
@MainActor
@Suite final class AlignmentProbeTests: IsolatedSuite {

    // MARK: - Session

    /// A hand-cranked stand-in for the session's timer: every scheduled body is
    /// held with its delay so a test can fire the pattern in wall-clock order,
    /// instantly.
    private final class ManualClock {
        private var pending: [(delay: TimeInterval, body: () -> Void)] = []
        /// Delays whose body is thrown away instead of held — a scheduler that
        /// lost a fire, which is the only way the session's timeout is ever
        /// reached before the pattern's own end.
        var drops: [TimeInterval] = []

        func schedule(_ delay: TimeInterval, _ body: @escaping () -> Void) {
            guard !drops.contains(delay) else { return }
            pending.append((delay, body))
        }

        /// Fire everything scheduled up to `time`, in scheduled order, and drop it.
        func advance(to time: TimeInterval) {
            let due = pending.filter { $0.delay <= time }.sorted { $0.delay < $1.delay }
            pending.removeAll { $0.delay <= time }
            for item in due { item.body() }
        }
    }

    private final class MuteSpy {
        /// Every mute write the session made, in order.
        var writes: [(id: String, muted: Bool)] = []
        var muted: Set<String> = []
        var ticks: [Bool] = []
        var targetLive = true
        var outcomes: [AlignmentProbeSession.Outcome] = []

        func setMuted(_ id: String, _ isMuted: Bool) {
            writes.append((id, isMuted))
            if isMuted { muted.insert(id) } else { muted.remove(id) }
        }
    }

    private func makeSession(spy: MuteSpy, clock: ManualClock,
                             references: [String] = ["ref"]) -> AlignmentProbeSession {
        let session = AlignmentProbeSession(
            targetDeviceID: "tgt",
            referenceDeviceIDs: references,
            setMuted: { [spy] id, muted in spy.setMuted(id, muted) },
            isMuted: { [spy] id in spy.muted.contains(id) },
            isTargetLive: { [spy] in spy.targetLive },
            setTick: { [spy] active in spy.ticks.append(active) },
            schedule: { [clock] delay, body in clock.schedule(delay, body) })
        session.onEnd = { [spy] outcome in spy.outcomes.append(outcome) }
        return session
    }

    @Test func patternAlternatesReferenceThenTargetWithBothMutedGaps() {
        let spy = MuteSpy()
        let clock = ManualClock()
        let session = makeSession(spy: spy, clock: clock)

        session.start()
        #expect(spy.ticks == [true])
        #expect(spy.writes.allSatisfy { !$0.muted }, "the preamble puts BOTH speakers up")
        #expect(spy.muted.isEmpty)

        let P = AlignmentProbeSession.beatPeriodSeconds
        let preamble = AlignmentProbeSession.preambleSeconds

        // First REF block: the target goes quiet, the reference keeps playing.
        clock.advance(to: preamble)
        #expect(spy.writes.suffix(1).map(\.id) == ["tgt"], "one write — the reference is already up")
        #expect(spy.muted == ["tgt"])

        // Gap: both quiet.
        clock.advance(to: preamble + 6 * P)
        #expect(spy.muted == ["tgt", "ref"])

        // TGT block: the mirror image — reference quiet, target back up.
        clock.advance(to: preamble + 8 * P)
        #expect(spy.muted == ["ref"])

        // Gap again.
        clock.advance(to: preamble + 14 * P)
        #expect(spy.muted == ["tgt", "ref"])

        // Second repetition opens with REF, exactly as the first did.
        clock.advance(to: preamble + 16 * P)
        #expect(spy.muted == ["tgt"])

        clock.advance(to: AlignmentProbeSession.patternSeconds)
        #expect(spy.outcomes == [.finished])
        #expect(spy.ticks == [true, false])
        #expect(spy.muted.isEmpty, "everything the run muted is unmuted again")
        session.cancel()
    }

    @Test func patternRunsThreeRepetitionsEndingOnAGap() {
        let steps = AlignmentProbeSession.stepSchedule()
        #expect(steps.count == 4 * AlignmentProbeSession.repetitions)
        #expect(steps.map(\.step).first == .referenceBlock)
        #expect(steps.map(\.step).last == .gap)
        // Wall-clock offsets from run start, not chained: the last boundary
        // sits exactly two beats before the pattern ends.
        let lastGap = steps.last?.offset ?? 0
        #expect(abs(lastGap
            + Double(AlignmentProbeSession.gapBeats) * AlignmentProbeSession.beatPeriodSeconds
            - AlignmentProbeSession.patternSeconds) < 1e-9)
    }

    @Test func cancelRestoresTheMuteStateTheRunFound() {
        let spy = MuteSpy()
        let clock = ManualClock()
        // The user had the reference muted before the probe started.
        spy.muted = ["ref"]
        let session = makeSession(spy: spy, clock: clock)

        session.start()
        #expect(spy.muted == [], "the preamble makes both audible")
        clock.advance(to: AlignmentProbeSession.preambleSeconds)   // REF block
        session.cancel()

        #expect(spy.outcomes == [.cancelled])
        #expect(spy.muted == ["ref"], "the user's own mute is back")
        #expect(spy.ticks == [true, false])
    }

    @Test func timeoutRestoresWhenThePatternsOwnEndNeverFires() {
        let spy = MuteSpy()
        let clock = ManualClock()
        clock.drops = [AlignmentProbeSession.patternSeconds]
        let session = makeSession(spy: spy, clock: clock)

        session.start()
        clock.advance(to: AlignmentProbeSession.preambleSeconds)
        clock.advance(to: AlignmentProbeSession.timeoutSeconds)

        #expect(spy.outcomes == [.timedOut])
        #expect(spy.muted.isEmpty, "a stuck run still hands the fleet back")
        #expect(spy.ticks == [true, false])
        #expect(!session.isRunning)
    }

    @Test func targetVanishingMidRunEndsTheRunAndUnmutesTheReference() {
        let spy = MuteSpy()
        let clock = ManualClock()
        let session = makeSession(spy: spy, clock: clock)

        session.start()
        clock.advance(to: AlignmentProbeSession.preambleSeconds)     // REF block
        spy.targetLive = false
        clock.advance(to: AlignmentProbeSession.preambleSeconds
                      + 6 * AlignmentProbeSession.beatPeriodSeconds) // would be the gap

        #expect(spy.outcomes == [.targetVanished])
        #expect(spy.muted.isEmpty, "no speaker is left silent for a run that can't continue")
        #expect(spy.ticks == [true, false])
    }

    @Test func endIsFiredOnceEvenWhenCancelRacesTheFinish() {
        let spy = MuteSpy()
        let clock = ManualClock()
        let session = makeSession(spy: spy, clock: clock)

        session.start()
        clock.advance(to: AlignmentProbeSession.timeoutSeconds)
        session.cancel()
        #expect(spy.outcomes.count == 1)
    }

    // MARK: - Commands

    private struct Context {
        let dispatcher: CompanionCommandDispatcher
        let groupController: GroupController
        let spy: BackendSpy
    }

    private final class BackendSpy {
        var ticks: [Bool] = []
        var trims: [String: Double] = [:]
        var persisted: [(ms: Double, id: String)] = []
    }

    private static let btDeviceID = "C4-38-75-0E-BF-4A:output"

    private func makeContext() async throws -> Context {
        let fleet: [Device] = [
            Device(id: Self.btDeviceID, name: "Sonos Move 2", kind: .bluetooth,
                   supportsAirPlay2: false, volume: 50),
            Device(id: "homepod", name: "Bedroom HomePod", kind: .homePod, volume: 40),
            Device(id: "office", name: "Office", kind: .generic, volume: 50),
        ]
        let backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        backend.start()
        try await waitForFleet(backend, count: fleet.count)

        let groupController = GroupController(backend: backend, store: GroupStore(directory: scratchDir),
                                              routingStore: RoutingStore(directory: scratchDir),
                                              loadPersisted: false)
        let spy = BackendSpy()
        let dispatcher = CompanionCommandDispatcher(
            groupController: groupController,
            appRouting: AppRoutingController(store: AppRouteStore(directory: scratchDir),
                                             loadPersisted: false),
            settings: AppSettings(defaults: isolatedDefaults),
            isExcluded: { _ in false },
            setLocalPlaybackVolume: { _, _ in },
            applyStartBuffer: { _ in },
            setProbeTickActive: { spy.ticks.append($0) },
            btSyncTrim: { spy.trims[$0] ?? 0 },
            persistBTSyncTrim: { ms, id in
                spy.persisted.append((ms, id))
                spy.trims[id] = ms
            })
        return Context(dispatcher: dispatcher, groupController: groupController, spy: spy)
    }

    /// `MockBackend` publishes its fleet asynchronously; the dispatcher's
    /// validation reads `groupController.devices`, so wait for it to land.
    private func waitForFleet(_ backend: MockBackend, count: Int) async throws {
        for _ in 0..<200 where backend.devices.count < count {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(backend.devices.count == count)
    }

    /// Selecting a device connects it in the mock and makes it a Main Out
    /// member — the two things the probe requires of both speakers.
    private func select(_ ids: [String], in ctx: Context) {
        for id in ids { _ = ctx.dispatcher.execute(.setDeviceSelected(id: id, selected: true)) }
    }

    @Test func startProbeRunsAgainstAPickedReference() async throws {
        let ctx = try await makeContext()
        select([Self.btDeviceID, "homepod"], in: ctx)

        let result = ctx.dispatcher.execute(
            .startAlignmentProbe(targetDeviceID: Self.btDeviceID, referenceDeviceID: "homepod"))
        #expect(result.applied)
        #expect(ctx.spy.ticks == [true])
        #expect(ctx.dispatcher.alignmentProbeState
            == AlignmentProbeState(targetDeviceID: Self.btDeviceID, state: "running"))

        _ = ctx.dispatcher.execute(.cancelAlignmentProbe)
        #expect(ctx.dispatcher.alignmentProbeState == nil)
        #expect(ctx.spy.ticks == [true, false])
    }

    @Test func startProbeWithoutAReferenceUsesTheOtherMainOutMembers() async throws {
        let ctx = try await makeContext()
        select([Self.btDeviceID, "homepod", "office"], in: ctx)

        let result = ctx.dispatcher.execute(
            .startAlignmentProbe(targetDeviceID: Self.btDeviceID, referenceDeviceID: nil))
        #expect(result.applied)
        _ = ctx.dispatcher.execute(.cancelAlignmentProbe)
    }

    @Test func startProbeRefusedForANonBluetoothTarget() async throws {
        let ctx = try await makeContext()
        select(["homepod", "office"], in: ctx)
        let result = ctx.dispatcher.execute(
            .startAlignmentProbe(targetDeviceID: "homepod", referenceDeviceID: "office"))
        #expect(!result.applied)
        #expect(result.refusalReason?.contains("Bluetooth") == true)
        #expect(ctx.spy.ticks.isEmpty)
    }

    @Test func startProbeRefusedWhenTheTargetIsntConnected() async throws {
        let ctx = try await makeContext()
        select(["homepod"], in: ctx)
        let result = ctx.dispatcher.execute(
            .startAlignmentProbe(targetDeviceID: Self.btDeviceID, referenceDeviceID: "homepod"))
        #expect(!result.applied)
        #expect(ctx.dispatcher.alignmentProbeState == nil)
    }

    @Test func startProbeRefusedWhenTheReferenceIsTheTarget() async throws {
        let ctx = try await makeContext()
        select([Self.btDeviceID, "homepod"], in: ctx)
        let result = ctx.dispatcher.execute(
            .startAlignmentProbe(targetDeviceID: Self.btDeviceID, referenceDeviceID: Self.btDeviceID))
        #expect(!result.applied)
    }

    @Test func startProbeRefusedWhenTheReferenceIsMuted() async throws {
        let ctx = try await makeContext()
        select([Self.btDeviceID, "homepod"], in: ctx)
        ctx.groupController.setMuted(true, for: "homepod")
        let result = ctx.dispatcher.execute(
            .startAlignmentProbe(targetDeviceID: Self.btDeviceID, referenceDeviceID: "homepod"))
        #expect(!result.applied)
        #expect(result.refusalReason?.contains("isn't playing") == true)
    }

    @Test func startProbeRefusedWhenNothingElseIsPlaying() async throws {
        let ctx = try await makeContext()
        select([Self.btDeviceID], in: ctx)
        let result = ctx.dispatcher.execute(
            .startAlignmentProbe(targetDeviceID: Self.btDeviceID, referenceDeviceID: nil))
        #expect(!result.applied)
        #expect(ctx.spy.ticks.isEmpty)
    }

    @Test func secondStartRefusedWhileAProbeIsRunning() async throws {
        let ctx = try await makeContext()
        select([Self.btDeviceID, "homepod"], in: ctx)
        _ = ctx.dispatcher.execute(
            .startAlignmentProbe(targetDeviceID: Self.btDeviceID, referenceDeviceID: "homepod"))
        let second = ctx.dispatcher.execute(
            .startAlignmentProbe(targetDeviceID: Self.btDeviceID, referenceDeviceID: "homepod"))
        #expect(!second.applied)
        _ = ctx.dispatcher.execute(.cancelAlignmentProbe)
    }

    @Test func cancelWithNoProbeRunningIsAnHonestNoOp() async throws {
        let ctx = try await makeContext()
        #expect(ctx.dispatcher.execute(.cancelAlignmentProbe).applied)
    }

    // MARK: - Trim sign

    /// The sign is a 50/50 that compiles either way, so this test justifies its
    /// expected value from the SINK, never from the formula:
    /// `BTSyncTrim` is `SyncTiming.totalDelayNanos`'s `userOffsetMs`, which is
    /// ADDED to the device's scheduled delay — a larger trim plays the device
    /// later. So a target measured LATE must end up with a SMALLER trim.
    @Test func aLateTargetGetsItsTrimReduced() async throws {
        let ctx = try await makeContext()
        ctx.spy.trims[Self.btDeviceID] = 40

        // Sanity, straight from the sink: +10 ms of trim is +10 ms of delay.
        let delayAt40 = BTReferenceTimeline.delayNanos(
            composition: BTGroupComposition(airPlayPresent: false, macLocalPresent: false),
            presentationDelayMs: 250, btOnlyBufferMs: 250, deviceOffsetMs: 0, trimMs: 40)
        let delayAt50 = BTReferenceTimeline.delayNanos(
            composition: BTGroupComposition(airPlayPresent: false, macLocalPresent: false),
            presentationDelayMs: 250, btOnlyBufferMs: 250, deviceOffsetMs: 0, trimMs: 50)
        #expect(delayAt50 > delayAt40, "a bigger trim delays the speaker further")

        let result = ctx.dispatcher.execute(.submitProbeResult(
            targetDeviceID: Self.btDeviceID, offsetMs: 12, spreadMs: 1, confident: true))
        #expect(result.applied)
        #expect(ctx.spy.persisted.count == 1)
        // 12 ms late at a 40 ms trim ⇒ 28 ms: less delay, so it plays earlier.
        #expect(ctx.spy.persisted.first?.ms == 28)
        #expect(ctx.spy.persisted.first?.id == Self.btDeviceID)
    }

    @Test func anEarlyTargetGetsItsTrimIncreased() async throws {
        let ctx = try await makeContext()
        ctx.spy.trims[Self.btDeviceID] = 40
        _ = ctx.dispatcher.execute(.submitProbeResult(
            targetDeviceID: Self.btDeviceID, offsetMs: -12.4, spreadMs: 1, confident: true))
        // Quantised to whole ms, the same contract the wizard and the drawer use.
        #expect(ctx.spy.persisted.first?.ms == 52)
    }

    @Test func anUnconfidentResultChangesNothing() async throws {
        let ctx = try await makeContext()
        ctx.spy.trims[Self.btDeviceID] = 40
        let result = ctx.dispatcher.execute(.submitProbeResult(
            targetDeviceID: Self.btDeviceID, offsetMs: 12, spreadMs: 40, confident: false))
        #expect(result.applied, "the phone already told the user — no second failure")
        #expect(ctx.spy.persisted.isEmpty)
    }

    @Test func resultRefusedForAnUnknownDeviceOrANonNumber() async throws {
        let ctx = try await makeContext()
        #expect(!ctx.dispatcher.execute(.submitProbeResult(
            targetDeviceID: "no-such-device", offsetMs: 12, spreadMs: 1, confident: true)).applied)
        #expect(!ctx.dispatcher.execute(.submitProbeResult(
            targetDeviceID: Self.btDeviceID, offsetMs: .nan, spreadMs: 1, confident: true)).applied)
        #expect(ctx.spy.persisted.isEmpty)
    }

    // MARK: - Wire round-trip

    @Test func theThreeCommandsRoundTripOnTheWire() throws {
        let commands: [CompanionCommand] = [
            .startAlignmentProbe(targetDeviceID: "tgt", referenceDeviceID: "ref"),
            .startAlignmentProbe(targetDeviceID: "tgt", referenceDeviceID: nil),
            .cancelAlignmentProbe,
            .submitProbeResult(targetDeviceID: "tgt", offsetMs: -37.4, spreadMs: 2, confident: true),
        ]
        for command in commands {
            let data = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(CompanionCommand.self, from: data) == command)
        }
    }
}
