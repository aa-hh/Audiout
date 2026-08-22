// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

@testable import AudiouterCore
import CastFakeReceiver
import CastSender
import Foundation
import Network
import Testing

/// `CastOutputManager` driving the whole recipe over a real TLS socket against
/// the fake receiver: connect, launch, serve, LOAD without autoplay, PLAY.
///
/// Everything binds loopback-only (the fake's listener and the manager's audio
/// server alike), which keeps macOS's Application Firewall from prompting the
/// xctest process. The fake needs macOS 15 for its in-memory TLS identity, and
/// swift-testing rejects `@available` on `@Suite`/`@Test`, so the gate is a
/// `guard #available` at the top of each test — the same shape
/// `CastFakeReceiverLoopTests` uses, along with its `Box`/`waitUntil` idiom.
@Suite struct CastOutputManagerTests {

    // MARK: - Waiting

    /// A lock-guarded slot for a value a network callback produces.
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        func set(_ value: Value) { lock.withLock { stored = value } }
        var value: Value? { lock.withLock { stored } }
    }

    /// Every state the manager reported, in order.
    private final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [CastSessionState] = []
        func append(_ state: CastSessionState) { lock.withLock { states.append(state) } }
        var all: [CastSessionState] { lock.withLock { states } }
        var last: CastSessionState? { lock.withLock { states.last } }
        func contains(_ state: CastSessionState) -> Bool { lock.withLock { states.contains(state) } }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    // MARK: - Fixtures

    @available(macOS 15, *)
    private func startFake(
        fetchBytes: Int = 16_384,
        controlType: String = "attenuation"
    ) throws -> (fake: FakeCastReceiver, endpoint: NWEndpoint) {
        let fake = FakeCastReceiver(fetchBytes: fetchBytes, controlType: controlType)
        let box = Box<NWEndpoint>()
        fake.start { result in
            if case .success(let endpoint) = result { box.set(endpoint) }
        }
        try #require(waitUntil(timeout: 5) { box.value != nil }, "the fake receiver never bound a loopback port")
        return (fake, try #require(box.value))
    }

    private func makeManager() -> CastOutputManager {
        CastOutputManager(
            serverBindsLoopbackOnly: true,
            streamHostOverride: "127.0.0.1",
            requestTimeout: 3,
            reconnectDelay: 0.1
        )
    }

    /// Watches one device and returns the log the assertions read.
    private func watch(_ manager: CastOutputManager, deviceID: String) -> StateLog {
        let log = StateLog()
        manager.onStateChange = { id, state in
            guard id == deviceID else { return }
            log.append(state)
        }
        return log
    }

    private func record(_ endpoint: NWEndpoint, id: String = "dev1") -> CastDeviceRecord {
        CastDeviceRecord(id: id, friendlyName: "Fake", model: nil, endpoint: endpoint)
    }

    /// One block of audibly non-zero S16LE stereo.
    private func tone(frames: Int) -> Data {
        var out = Data(capacity: frames * 4)
        for _ in 0..<frames {
            out.append(contentsOf: [0xE8, 0x03, 0xE8, 0x03])  // 1000, both channels
        }
        return out
    }

    /// The left channel of one rendered block, as amplitudes.
    private func leftChannel(_ pcm: Data) -> [Int16] {
        let samples: [Int16] = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
    }

    /// The receiver's own view of its volume, over a second sender connection —
    /// the fake keeps the level private, so this is the only way to read it.
    private func receiverVolume(_ client: CastClient) -> Double? {
        let box = Box<CastReceiverStatus>()
        client.getReceiverStatus { result in
            if case .success(let status) = result { box.set(status) }
        }
        _ = waitUntil(timeout: 3) { box.value != nil }
        return box.value?.volumeLevel
    }

    // MARK: - Tests

    @Test func selectingADeviceReachesPlaying() throws {
        guard #available(macOS 15, *) else { return }
        let (fake, endpoint) = try startFake()
        defer { fake.stop() }
        let fetched = Box<(Data, Int)>()
        fake.onFetchComplete = { head, total in fetched.set((head, total)) }

        let manager = makeManager()
        defer { manager.stopAll() }
        let log = watch(manager, deviceID: "dev1")
        manager.setDevices([record(endpoint)])

        #expect(waitUntil(timeout: 10) { log.contains(.playing) },
                Comment(rawValue: "never reached PLAYING, saw \(log.all)"))
        #expect(log.all == [.connecting, .playing])
        try #require(waitUntil(timeout: 5) { fetched.value != nil }, "fetch never completed")
        let head = try #require(fetched.value?.0)
        #expect(head.prefix(4) == Data("RIFF".utf8))
    }

    @Test func feedAudioReachesTheReceiver() throws {
        guard #available(macOS 15, *) else { return }
        // Past the 44-byte WAV header AND the 1 s silent prime (176 400 bytes),
        // so what the receiver reports includes live audio, not just the prime.
        let (fake, endpoint) = try startFake(fetchBytes: 300_000)
        defer { fake.stop() }
        let fetched = Box<(Data, Int)>()
        fake.onFetchComplete = { body, total in fetched.set((body, total)) }

        let manager = makeManager()
        defer { manager.stopAll() }
        let log = watch(manager, deviceID: "dev1")

        // 882 frames every 20 ms — real time at 44.1 kHz, so the ring is fed at
        // exactly the rate the server drains it and nothing gets zero-filled.
        // Started before the device, so the ring is already live when the
        // receiver's GET arrives.
        let feed = manager.feed
        let writer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "CastOutputManagerTests.feed"))
        writer.schedule(deadline: .now(), repeating: 0.020)
        let block = tone(frames: 882)
        writer.setEventHandler { feed.write(pcm: block, pts: timespec(tv_sec: 0, tv_nsec: 0)) }
        writer.resume()
        defer { writer.cancel() }

        manager.setDevices([record(endpoint)])
        #expect(waitUntil(timeout: 10) { log.contains(.playing) },
                Comment(rawValue: "never reached PLAYING, saw \(log.all)"))
        // PLAYING lands as soon as PLAY is answered; the 300 000th byte only
        // after ~0.7 s of real-time stream past the instant prime burst.
        try #require(waitUntil(timeout: 5) { fetched.value != nil },
                     "the receiver never finished fetching")
        let (body, total) = try #require(fetched.value)
        #expect(body.prefix(4) == Data("RIFF".utf8))
        #expect(total >= 300_000)

        // The evidence: past the header and the silent prime, the fetched bytes
        // carry the exact pattern this test fed in. Chunk framing is still
        // interleaved in there, which is why this looks for the pattern rather
        // than merely for something non-zero.
        let afterPrime = Data(body.dropFirst(176_444))
        #expect(afterPrime.range(of: tone(frames: 16)) != nil,
                "the receiver fetched no fed audio past the prime (\(afterPrime.count) bytes past it)")

        // The fan-out → ring hop those samples take, pinned directly.
        let ring = CastFeedRing()
        let fanOut = CastFanOut()
        fanOut.setRings([ring])
        fanOut.write(pcm: block, pts: timespec(tv_sec: 0, tv_nsec: 0))
        #expect(ring.render(frames: 441).contains { $0 != 0 })
    }

    @Test func setLevelRoundTrips() throws {
        guard #available(macOS 15, *) else { return }
        let (fake, endpoint) = try startFake()
        defer { fake.stop() }
        let manager = makeManager()
        defer { manager.stopAll() }
        let log = watch(manager, deviceID: "dev1")
        manager.setDevices([record(endpoint)])
        try #require(waitUntil(timeout: 10) { log.contains(.playing) }, "never reached PLAYING")

        manager.setLevel(0.4, forDevice: "dev1")

        let channel = CastChannel(endpoint: endpoint, requestTimeout: 3)
        defer { channel.close() }
        let client = CastClient(channel: channel)
        let connected = Box<Bool>()
        channel.connect { _ in connected.set(true) }
        try #require(waitUntil(timeout: 5) { connected.value != nil }, "the observing connection never completed")

        var level: Double?
        let deadline = Date().addingTimeInterval(3)
        repeat {
            level = receiverVolume(client)
            if let level, abs(level - 0.4) < 0.001 { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        let observed = level ?? -1
        #expect(abs(observed - 0.4) < 0.001,
                Comment(rawValue: "the receiver's level never became 0.4 (saw \(observed))"))
    }

    @Test func removingTheDeviceStopsEverything() throws {
        guard #available(macOS 15, *) else { return }
        let (fake, endpoint) = try startFake()
        defer { fake.stop() }
        let manager = makeManager()
        let log = watch(manager, deviceID: "dev1")
        manager.setDevices([record(endpoint)])
        try #require(waitUntil(timeout: 10) { log.contains(.playing) }, "never reached PLAYING")

        manager.setDevices([])
        #expect(waitUntil(timeout: 5) { log.last == .idle },
                Comment(rawValue: "the removed device never went idle, saw \(log.all)"))

        // A write with nothing selected has nowhere to go, and must not crash.
        manager.feed.write(pcm: tone(frames: 441), pts: timespec(tv_sec: 0, tv_nsec: 0))
        manager.stopAll()
        manager.stopAll()
    }

    @Test func unreachableEndpointFails() throws {
        guard #available(macOS 15, *) else { return }
        let manager = makeManager()
        defer { manager.stopAll() }
        let log = watch(manager, deviceID: "dev1")
        // Port 1 on loopback: nothing listens, so the refusal is immediate.
        manager.setDevices([record(.hostPort(host: "127.0.0.1", port: 1))])

        #expect(waitUntil(timeout: 5) {
            switch log.last {
            case .failed(.connectionFailed), .failed(.timedOut): return true
            default: return false
            }
        }, Comment(rawValue: "expected a connect failure, saw \(log.all)"))
    }

    @Test func rapidReselectRelaunchesCleanly() throws {
        guard #available(macOS 15, *) else { return }
        let (fake, endpoint) = try startFake()
        defer { fake.stop() }
        let manager = makeManager()
        defer { manager.stopAll() }
        let log = watch(manager, deviceID: "dev1")
        manager.setDevices([record(endpoint)])
        try #require(waitUntil(timeout: 10) { log.contains(.playing) },
                     Comment(rawValue: "never reached PLAYING, saw \(log.all)"))

        // Deselect and re-select in the same breath: the first session's STOP
        // is still in flight when the second one is asked for.
        manager.setDevices([])
        manager.setDevices([record(endpoint)])

        #expect(waitUntil(timeout: 20) { log.all.filter { $0 == .playing }.count >= 2 },
                Comment(rawValue: "the re-selected session never reached PLAYING, saw \(log.all)"))
        #expect(log.all.last == .playing)

        // The ordering that makes the relaunch clean: the receiver answered
        // STOP before the second LAUNCH arrived. (The first channel's close is
        // initiated before the second connect, but the fake OBSERVES the close
        // on its own connection handler, which can land after the new connect —
        // so receiver-side close order is deliberately not asserted.)
        let events = fake.events
        let launches = events.indices.filter { events[$0] == "LAUNCH" }
        try #require(launches.count >= 2, Comment(rawValue: "expected two LAUNCHes, saw \(events)"))
        #expect(events[..<launches[1]].contains("STOP"),
                Comment(rawValue: "the relaunch raced the previous STOP: \(events)"))
    }

    @Test func fixedReceiverAppliesGainInTheFeedNotSetVolume() throws {
        guard #available(macOS 15, *) else { return }
        let (fake, endpoint) = try startFake(controlType: "fixed")
        defer { fake.stop() }
        let manager = makeManager()
        defer { manager.stopAll() }
        let log = watch(manager, deviceID: "dev1")
        manager.setDevices([record(endpoint)])
        try #require(waitUntil(timeout: 10) { log.contains(.playing) },
                     Comment(rawValue: "never reached PLAYING, saw \(log.all)"))

        manager.setLevel(0.5, forDevice: "dev1")
        let ring = try #require(manager.test_ring(forDevice: "dev1"))
        #expect(waitUntil(timeout: 3) { abs(ring.gainTarget - 0.5) < 0.001 },
                Comment(rawValue: "the level never reached the feed (gain \(ring.gainTarget))"))
        // A fixed receiver is told to reach for the TV remote instead, so the
        // one thing that must NOT happen is a SET_VOLUME.
        #expect(fake.setVolumeCount == 0,
                Comment(rawValue: "a fixed receiver was sent \(fake.setVolumeCount) SET_VOLUME(s)"))

        // What that gain does to the audio: half scale out of a full-scale in.
        let scratch = CastFeedRing()
        scratch.setTargetGain(0.5)
        scratch.reset()
        scratch.push(tone(frames: 441))
        let peak = leftChannel(scratch.render(frames: 441)).map { abs(Int($0)) }.max() ?? 0
        #expect(abs(peak - 500) <= 1, Comment(rawValue: "expected ~500, rendered \(peak)"))
    }

    @Test func attenuationReceiverStillUsesSetVolume() throws {
        guard #available(macOS 15, *) else { return }
        let (fake, endpoint) = try startFake()
        defer { fake.stop() }
        let manager = makeManager()
        defer { manager.stopAll() }
        let log = watch(manager, deviceID: "dev1")
        manager.setDevices([record(endpoint)])
        try #require(waitUntil(timeout: 10) { log.contains(.playing) },
                     Comment(rawValue: "never reached PLAYING, saw \(log.all)"))

        manager.setLevel(0.4, forDevice: "dev1")
        #expect(waitUntil(timeout: 3) { fake.setVolumeCount >= 1 },
                "the receiver was never sent SET_VOLUME")
        let ring = try #require(manager.test_ring(forDevice: "dev1"))
        #expect(ring.gainTarget == 1, Comment(rawValue: "the feed was attenuated as well (gain \(ring.gainTarget))"))
    }

    @Test func fixedReceiverGainRampsWithoutZipper() {
        let ring = CastFeedRing()
        ring.push(tone(frames: 882))
        ring.setTargetGain(0)

        // 20 ms is the cap: a full-scale-to-silence jump lands inside one
        // 882-frame block, and every step on the way is smaller than the last.
        let left = leftChannel(ring.render(frames: 882))
        #expect(left.count == 882)
        #expect(left.first ?? 0 < 1000, Comment(rawValue: "the first frame did not start ramping: \(left.prefix(4))"))
        #expect(left.last == 0, Comment(rawValue: "the ramp had not finished after 882 frames: \(left.suffix(4))"))
        #expect(zip(left, left.dropFirst()).allSatisfy { $0 >= $1 },
                "the ramp was not monotonic")
        // Halfway through is halfway down — a ramp, not a step.
        #expect(abs(Int(left[440]) - 500) <= 2, Comment(rawValue: "midpoint was \(left[440])"))
    }

    @Test func ringZeroFillsWhenEmpty() {
        let ring = CastFeedRing()
        #expect(ring.render(frames: 100) == Data(count: 400))

        ring.push(tone(frames: 10))
        let rendered = ring.render(frames: 20)
        #expect(rendered.count == 80)
        #expect(rendered.prefix(40) == tone(frames: 10))
        #expect(rendered.suffix(40) == Data(count: 40))

        ring.push(tone(frames: 10))
        ring.reset()
        #expect(ring.render(frames: 10) == Data(count: 40))
    }
}
