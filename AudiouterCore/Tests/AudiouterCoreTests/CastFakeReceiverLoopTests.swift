// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import CastFakeReceiver
import CastSender
import Foundation
import Network
import Testing

/// The whole Cast loop over a REAL TLS socket, sender against fake receiver:
/// connect, heartbeat, launch, load, fetch, play, pause, stop. This is the
/// hardware-free half of roadmap 006 Phase 0 — when a Cast device arrives,
/// `cast-spike --device` runs the same code path against it.
///
/// Everything binds loopback-only (the fake's listener and the audio server's
/// alike), which is what keeps macOS's Application Firewall from prompting the
/// xctest process; the fake's TLS key is imported with
/// `kSecImportToMemoryOnly`, which keeps it out of the login keychain. The
/// `Signal`/`waitFor` spin idiom is DACPServerTests'.
///
/// The fake needs macOS 15 for that import option, but swift-testing rejects
/// `@available` on `@Suite`/`@Test` outright — so the gate is a `guard
/// #available` at the top of each test instead of an attribute on the suite.
/// Both machines the suite runs on are past 15; this is a compile-time
/// formality, not a real skip.
@Suite struct CastFakeReceiverLoopTests {

    // MARK: - Waiting

    private final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var _fired = false
        func fire() { lock.withLock { _fired = true } }
        var fired: Bool { lock.withLock { _fired } }
    }

    /// A lock-guarded slot for a value a network callback produces.
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        func set(_ value: Value) { lock.withLock { stored = value } }
        var value: Value? { lock.withLock { stored } }
    }

    private func waitFor(_ signals: [Signal], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if signals.allSatisfy(\.fired) { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return signals.allSatisfy(\.fired)
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
    private func startFake(fetchBytes: Int = 65_536) throws -> (fake: FakeCastReceiver, endpoint: NWEndpoint) {
        let fake = FakeCastReceiver(fetchBytes: fetchBytes)
        let box = Box<NWEndpoint>()
        fake.start { result in
            if case .success(let endpoint) = result { box.set(endpoint) }
        }
        try #require(waitUntil(timeout: 5) { box.value != nil }, "the fake receiver never bound a loopback port")
        return (fake, try #require(box.value))
    }

    /// A connected sender. `heartbeatInterval` is short so a test can watch
    /// the heartbeat without waiting out the 5 s production cadence.
    private func connect(
        to endpoint: NWEndpoint,
        heartbeatInterval: TimeInterval = 5
    ) throws -> (channel: CastChannel, client: CastClient) {
        let channel = CastChannel(endpoint: endpoint, heartbeatInterval: heartbeatInterval, requestTimeout: 5)
        let client = CastClient(channel: channel)
        let ready = Signal()
        let failure = Box<Error>()
        channel.connect { result in
            if case .failure(let error) = result { failure.set(error) }
            ready.fire()
        }
        try #require(waitFor([ready], timeout: 5), "the TLS connection to the fake never completed")
        if let error = failure.value { throw error }
        return (channel, client)
    }

    private func launchedApplication(_ client: CastClient) throws -> CastApplication {
        let box = Box<Result<CastApplication, Error>>()
        client.launch(appID: CastClient.defaultMediaReceiverAppID) { box.set($0) }
        try #require(waitUntil(timeout: 5) { box.value != nil }, "LAUNCH never answered")
        return try #require(try box.value?.get())
    }

    private func startAudioServer() throws -> CastLiveAudioServer {
        let server = CastLiveAudioServer(source: SineSource(), loopbackOnly: true)
        let box = Box<UInt16>()
        server.start { result in
            if case .success(let port) = result { box.set(port) }
        }
        try #require(waitUntil(timeout: 5) { box.value != nil }, "the live audio server never bound a loopback port")
        return server
    }

    // MARK: - Tests

    @Test func heartbeatsBothWays() throws {
        guard #available(macOS 15, *) else { return }
        let (fake, endpoint) = try startFake()
        defer { fake.stop() }
        let (channel, _) = try connect(to: endpoint, heartbeatInterval: 0.2)
        defer { channel.close() }

        // The sender PINGs on its timer and the fake answers; the fake PINGs
        // once after CONNECT and the sender answers. Both counters prove it.
        #expect(waitUntil(timeout: 2) { channel.pongCount >= 1 && fake.pongCount >= 1 },
                Comment(rawValue: "expected pongs both ways, sender saw \(channel.pongCount) and the fake saw \(fake.pongCount)"))
    }

    @Test func reportsReceiverStatus() throws {
        guard #available(macOS 15, *) else { return }
        let (fake, endpoint) = try startFake()
        defer { fake.stop() }
        let (channel, client) = try connect(to: endpoint)
        defer { channel.close() }

        let box = Box<Result<CastReceiverStatus, Error>>()
        client.getReceiverStatus { box.set($0) }
        try #require(waitUntil(timeout: 5) { box.value != nil }, "GET_STATUS never answered")

        let status = try #require(try box.value?.get())
        #expect(status.volumeLevel == 1)
        #expect(status.muted == false)
        #expect(status.applications.isEmpty)
    }

    @Test func launchesAnApplicationAndSetsVolume() throws {
        guard #available(macOS 15, *) else { return }
        let (fake, endpoint) = try startFake()
        defer { fake.stop() }
        let (channel, client) = try connect(to: endpoint)
        defer { channel.close() }

        let app = try launchedApplication(client)
        #expect(app.appID == CastClient.defaultMediaReceiverAppID)
        #expect(!app.transportID.isEmpty)
        #expect(!app.sessionID.isEmpty)

        let box = Box<Result<CastReceiverStatus, Error>>()
        client.setVolume(level: 0.4) { box.set($0) }
        try #require(waitUntil(timeout: 5) { box.value != nil }, "SET_VOLUME never answered")
        #expect(try box.value?.get().volumeLevel == 0.4)
    }

    @Test func loadsPlaysPausesAndStops() throws {
        guard #available(macOS 15, *) else { return }
        let (fake, endpoint) = try startFake(fetchBytes: 16_384)
        defer { fake.stop() }
        let server = try startAudioServer()
        defer { server.stop() }
        let (channel, client) = try connect(to: endpoint)
        defer { channel.close() }

        let fetched = Box<(Data, Int)>()
        fake.onFetchComplete = { head, total in fetched.set((head, total)) }
        let playing = Signal()
        client.onMediaStatus = { status in
            if status.playerState == "PLAYING" { playing.fire() }
        }

        let app = try launchedApplication(client)
        let loaded = Box<Result<CastMediaStatus, Error>>()
        client.load(url: server.url(host: "127.0.0.1"), contentType: "audio/wav", app: app) { loaded.set($0) }
        try #require(waitUntil(timeout: 5) { loaded.value != nil }, "LOAD never answered")

        let initial = try #require(try loaded.value?.get())
        #expect(initial.playerState == "BUFFERING")
        let session = try #require(initial.mediaSessionID, "the receiver allocated no media session")

        #expect(waitFor([playing], timeout: 3), "the receiver never reached PLAYING")
        let (head, total) = try #require(fetched.value, "the receiver never finished fetching the stream")
        #expect(head.prefix(4) == Data("RIFF".utf8), "the receiver did not fetch a WAV stream")
        #expect(total >= 16_384)

        let paused = Box<Result<CastMediaStatus, Error>>()
        client.pause(mediaSessionID: session, app: app) { paused.set($0) }
        try #require(waitUntil(timeout: 5) { paused.value != nil }, "PAUSE never answered")
        #expect(try paused.value?.get().playerState == "PAUSED")

        let stopped = Box<Result<CastReceiverStatus, Error>>()
        client.stopApplication(sessionID: app.sessionID) { stopped.set($0) }
        try #require(waitUntil(timeout: 5) { stopped.value != nil }, "STOP never answered")
        #expect(try stopped.value?.get().applications.isEmpty == true)
    }

    @Test func spikeRunProducesEveryNumber() throws {
        guard #available(macOS 15, *) else { return }
        let (fake, endpoint) = try startFake(fetchBytes: 16_384)
        defer { fake.stop() }

        let lines = LogSink()
        let run = CastSpikeRun(
            options: CastSpikeRun.Options(
                endpoint: endpoint,
                streamHost: "127.0.0.1",
                loopbackOnly: true,
                holdSeconds: 0.2,
                volumeLevel: 0.4
            ),
            log: { lines.append($0) }
        )
        let result = Box<Result<CastSpikeRun.Summary, Error>>()
        run.run { result.set($0) }
        try #require(waitUntil(timeout: 20) { result.value != nil }, Comment(rawValue: "the spike run never finished:\n" + lines.joined))

        let summary = try #require(try result.value?.get())
        // Every log line is prefixed "+<elapsed>s ", so these are `contains`.
        #expect(lines.joined.contains("launched"), lines.comment)
        #expect(lines.joined.contains("media_status state=PLAYING"), lines.comment)
        #expect(lines.joined.contains("done"), lines.comment)

        for (name, value) in [
            ("bufferingToPlayingMs", summary.bufferingToPlayingMs),
            ("volumeRoundTripMs", summary.volumeRoundTripMs),
            ("pauseRoundTripMs", summary.pauseRoundTripMs),
            ("resumeRoundTripMs", summary.resumeRoundTripMs),
        ] {
            let measured = try #require(value, Comment(rawValue: "\(name) was never measured:\n" + lines.joined))
            #expect(measured >= 0, Comment(rawValue: "\(name) is negative"))
        }
    }

    /// Collects the spike's log so a failure shows what the run actually did.
    private final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var joined: String { lock.withLock { lines.joined(separator: "\n") } }
        var comment: Comment { Comment(rawValue: joined) }
    }
}
