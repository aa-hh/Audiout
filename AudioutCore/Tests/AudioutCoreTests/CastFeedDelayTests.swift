// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

@testable import AudioutCore
import CastSender
import Foundation
import Network
import Testing

/// CAST-SYNC: the per-device feed delay that lets the room-delay controller
/// hold a Cast leg back to the room's common delay, and the observability the
/// controller reads it through.
///
/// Offline by construction — the ring and the fan-out are driven directly, and
/// the one manager test points at a port nothing listens on, so a session (and
/// its feed) exists without a receiver anywhere. Socket behaviour is
/// `CastOutputManagerTests`' job.
@Suite struct CastFeedDelayTests {

    // MARK: - Fixtures

    /// One block of audibly non-zero S16LE stereo, amplitude 1000 on both
    /// channels — the same figure `CastOutputManagerTests` feeds.
    private func tone(frames: Int) -> Data {
        var out = Data(count: frames * 4)
        out.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in 0..<(frames * 2) { samples[sample] = 1000 }
        }
        return out
    }

    private func frameValues(_ pcm: Data) -> [Int16] {
        let samples: [Int16] = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
    }

    // MARK: - The bypass is structural

    @Test func aFeedNeverAskedForADelayHasNoLine() {
        let ring = CastFeedRing()
        #expect(ring.test_hasDelayLine == false)
        // A zero ask must not build one either: with no Cast device selected
        // there is no ring at all, and an undelayed leg is today's byte path.
        ring.setDelayMs(0)
        #expect(ring.test_hasDelayLine == false)

        let block = tone(frames: 882)
        ring.push(block)
        #expect(ring.render(frames: 882) == block)
        #expect(ring.stats == CastFeedStats(
            achievedDelayMs: 0, droppedBlocks: 0, droppedLockBusy: 0,
            underrunFrames: 0, feedResets: 0))
    }

    // MARK: - Delaying by inserting zeros in FRONT of the ring

    /// The mechanism, and the reason it is free: the zeros go in ahead of the
    /// ring, so the ring's fill rate is exactly what it was and the server's
    /// wall-clock pacing is satisfied at the same rate. Five seconds of delay
    /// through a two-second ring is the proof — stuffing the zeros INTO the
    /// ring instead would have started dropping live audio past 2 s.
    @Test func fiveSecondsOfDelayCostsTheTwoSecondRingNothing() {
        let ring = CastFeedRing()
        ring.setDelayMs(5000)
        #expect(ring.test_hasDelayLine)

        // 6 s of tone, one 20 ms block at a time, each block drained straight
        // back out — the producer/consumer balance the real server runs at.
        var rendered: [Int16] = []
        for _ in 0..<300 {
            ring.push(tone(frames: 882))
            rendered += frameValues(ring.render(frames: 882))
        }

        let stats = ring.stats
        #expect(stats.droppedBlocks == 0)
        #expect(stats.underrunFrames == 0)
        #expect(stats.achievedDelayMs == 5000)
        // 5 s of inserted silence, then the audio, in step: nothing was lost in
        // between.
        #expect(rendered.count == 264_600)
        #expect(rendered[0..<220_500].allSatisfy { $0 == 0 })
        #expect(rendered[220_500...].allSatisfy { $0 == 1000 })
    }

    // MARK: - The reset()-on-GET reconciliation

    /// Every receiver GET drops the backlog, and a mid-session re-GET therefore
    /// throws away audio the delay line had ALREADY held back — the leg's
    /// achieved delay silently shortens by exactly that much. The line in front
    /// survives it; the discarded milliseconds and the reset count are what the
    /// room-delay controller re-settles on.
    @Test func aGETDiscardsDelayedAudioAndSaysHowMuch() {
        let ring = CastFeedRing()
        ring.setDelayMs(1000)
        // 2 s in, nothing out: the ring fills to its capacity behind a 1 s line.
        for _ in 0..<100 { ring.push(tone(frames: 882)) }
        #expect(ring.stats.achievedDelayMs == 3000)

        #expect(ring.reset() == 2000)
        #expect(ring.stats.feedResets == 1)
        #expect(ring.stats.achievedDelayMs == 1000, "the line in front is not what a GET resets")

        // Still emitting delayed audio rather than restarting into silence,
        // which is the visible half of the line having survived.
        ring.push(tone(frames: 882))
        #expect(ring.render(frames: 882) == tone(frames: 882))
    }

    // MARK: - Drops and underruns

    @Test func aBlockPastCapacityIsDroppedAndCounted() {
        let ring = CastFeedRing()
        for _ in 0..<101 { ring.push(tone(frames: 882)) }  // one block past 2 s
        #expect(ring.stats.droppedBlocks == 1)

        _ = ring.render(frames: 88_200)
        _ = ring.render(frames: 441)
        #expect(ring.stats.underrunFrames == 441, "what the consumer had to invent")
    }

    // MARK: - The controller's and the user's terms compose

    @Test func roomDelayAndUserOffsetComposeAndClampAtTheFloor() {
        let manager = CastOutputManager(
            serverBindsLoopbackOnly: true,
            streamHostOverride: "127.0.0.1",
            requestTimeout: 1,
            reconnectDelay: 60,
            playDeadline: 60)
        defer { manager.stopAll() }
        // Port 1 on loopback: nothing listens, so the session fails and stays —
        // which is all this needs, because the feed belongs to the session.
        manager.setDevices([CastDeviceRecord(
            id: "dev1", friendlyName: "Fake", model: nil,
            endpoint: .hostPort(host: "127.0.0.1", port: 1))])

        manager.setCastRoomDelayMs(2000, forDeviceID: "dev1")
        manager.setCastUserOffsetMs(-500, forDeviceID: "dev1")
        #expect(appliedDelayMs(manager) == 1500)

        // The trim exists for the receiver's own output stage and whatever TV
        // or soundbar chain follows it — tens of ms, not seconds. It can never
        // pull the leg below the floor: those frames are not captured yet.
        manager.setCastUserOffsetMs(-9000, forDeviceID: "dev1")
        #expect(appliedDelayMs(manager) == 0)

        #expect(manager.castFeedStats(forDevice: "nobody") == nil)
    }

    /// One block through the fan-out so the line adopts the pending value, then
    /// the ring drained so what comes back is the line's delay on its own.
    /// Both reads are `queue`-synchronous, so they also flush the setters.
    private func appliedDelayMs(_ manager: CastOutputManager) -> Int? {
        _ = manager.castFeedStats(forDevice: "dev1")
        manager.feed.write(pcm: tone(frames: 882), pts: timespec(tv_sec: 0, tv_nsec: 0))
        _ = manager.test_ring(forDevice: "dev1")?.render(frames: 88_200)
        return manager.castFeedStats(forDevice: "dev1")?.achievedDelayMs
    }
}
