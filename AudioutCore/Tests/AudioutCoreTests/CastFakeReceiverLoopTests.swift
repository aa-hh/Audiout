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

    private func waitFor(
        _ signals: [Signal], timeout: TimeInterval,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        SuiteWait.untilOnRunLoop("every signal to fire", timeout: timeout,
                                 sourceLocation: sourceLocation) { signals.allSatisfy(\.fired) }
        return signals.allSatisfy(\.fired)
    }

    private func waitUntil(
        timeout: TimeInterval,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) -> Bool {
        SuiteWait.untilOnRunLoop(timeout: timeout, sourceLocation: sourceLocation, condition)
        return condition()
    }

    // MARK: - Fixtures

    @available(macOS 15, *)
    private func startFake(fetchBytes: Int = 65_536) throws -> (fake: FakeCastReceiver, endpoint: NWEndpoint) {
        let fake = FakeCastReceiver(fetchBytes: fetchBytes)
        return (fake, try start(fake))
    }

    /// Binds a receiver built by the caller — the timing tests below each need
    /// their own buffer model, and defaults repeated here would be a second
    /// copy of the measured numbers to keep in step.
    @available(macOS 15, *)
    private func start(_ fake: FakeCastReceiver) throws -> NWEndpoint {
        let box = Box<NWEndpoint>()
        fake.start { result in
            if case .success(let endpoint) = result { box.set(endpoint) }
        }
        try #require(waitUntil(timeout: 5) { box.value != nil }, "the fake receiver never bound a loopback port")
        return try #require(box.value)
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

    private func startAudioServer(
        uptimeClock: @escaping CastUptimeClock = castDispatchUptimeClock
    ) throws -> CastLiveAudioServer {
        let server = CastLiveAudioServer(source: SineSource(), loopbackOnly: true, uptimeClock: uptimeClock)
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

    /// A media-namespace STOP must end the fetch too. `fetchBytes` here is
    /// about 0.6 s of real-time stream — the STOP lands mid-fetch, and the wait
    /// below outlasts what the fetch needs to finish, so an un-stopped fetch
    /// WOULD reach its byte count inside the window and report completion with
    /// no session behind it. `onFetchComplete` is the observable that catches
    /// it: the client sees only IDLE either way, because the fake's unsolicited
    /// status after the STOP carries an empty `status` array.
    @Test func aMediaStopEndsTheFetchAndStaysIdle() throws {
        guard #available(macOS 15, *) else { return }
        let (fake, endpoint) = try startFake(fetchBytes: 100_000)
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
        let session = try #require(try loaded.value?.get().mediaSessionID)

        let stopped = Box<Result<CastMediaStatus, Error>>()
        client.stopMedia(mediaSessionID: session, app: app) { stopped.set($0) }
        try #require(waitUntil(timeout: 5) { stopped.value != nil }, "media STOP never answered")
        #expect(try stopped.value?.get().playerState == "IDLE")

        #expect(waitFor([playing], timeout: 1.5) == false, "a stopped session must never come back as PLAYING")
        // This pins the `fetch = nil` half of the media-STOP fix (state
        // resurrection), NOT the `cancel()` half (socket hygiene) — a STOP that
        // only nils the reference passes here too.
        #expect(fetched.value == nil, "the STOP left the fetch running — it ran to completion anyway")
    }

    /// A second LOAD lands on a still-filling fetch and must hand off cleanly.
    /// Replacing the fetch cancels the old connection, which delivers
    /// `.cancelled` to its state handler and an error to its pending receive —
    /// both AFTER the new session is BUFFERING. Without a connection-identity
    /// check in `failFetch` the dead connection tears down the live fetch and
    /// reports the NEW session as ERROR. `fetchBytes` here is about 0.6 s of
    /// real-time stream, so the second LOAD is comfortably mid-fetch.
    @Test func aSecondLoadReplacesTheFetchWithoutFailingIt() throws {
        guard #available(macOS 15, *) else { return }
        let (fake, endpoint) = try startFake(fetchBytes: 100_000)
        defer { fake.stop() }
        let server = try startAudioServer()
        defer { server.stop() }
        let (channel, client) = try connect(to: endpoint)
        defer { channel.close() }

        // Counted, not signalled: the cancelled first fetch must never report
        // completion. The count is written only from the fake's serial queue.
        let fetches = Box<Int>()
        fake.onFetchComplete = { _, _ in fetches.set((fetches.value ?? 0) + 1) }
        let playingSession = Box<Int>()
        let sawError = Signal()
        client.onMediaStatus = { status in
            if status.idleReason == "ERROR" { sawError.fire() }
            if status.playerState == "PLAYING", let id = status.mediaSessionID { playingSession.set(id) }
        }

        let app = try launchedApplication(client)
        let first = Box<Result<CastMediaStatus, Error>>()
        client.load(url: server.url(host: "127.0.0.1"), contentType: "audio/wav", app: app) { first.set($0) }
        try #require(waitUntil(timeout: 5) { first.value != nil }, "the first LOAD never answered")
        let firstSession = try #require(try first.value?.get().mediaSessionID)

        Thread.sleep(forTimeInterval: 0.02)

        let second = Box<Result<CastMediaStatus, Error>>()
        client.load(url: server.url(host: "127.0.0.1"), contentType: "audio/wav", app: app) { second.set($0) }
        try #require(waitUntil(timeout: 5) { second.value != nil }, "the second LOAD never answered")
        let reloaded = try #require(try second.value?.get())
        #expect(reloaded.playerState == "BUFFERING")
        let session = try #require(reloaded.mediaSessionID, "the second LOAD allocated no media session")
        #expect(session != firstSession, "the second LOAD reused the first session id")

        #expect(waitUntil(timeout: 2) { playingSession.value == session },
                Comment(rawValue: "the second session never reached PLAYING, last PLAYING session was \(String(describing: playingSession.value))"))
        #expect(sawError.fired == false, "the replaced fetch reported the live session as ERROR")
        #expect(fetches.value == 1,
                Comment(rawValue: "expected exactly one completed fetch, saw \(String(describing: fetches.value))"))
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

    // MARK: - The timing the receiver models

    /// Every `playerState` the receiver reported, in order.
    private final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [String] = []
        func append(_ state: String) { lock.withLock { states.append(state) } }
        var all: [String] { lock.withLock { states } }
        func count(of state: String) -> Int { lock.withLock { states.filter { $0 == state }.count } }
    }

    /// The bytes a fake on a manual clock counts as "enough to announce
    /// PLAYING", named so the session below can step exactly that far.
    private static let leadFetchBytes = 65_536

    /// A receiver whose play clock, stalls and fetch run on `manual`. The
    /// manual clock runs a job on the thread that advances it, and the
    /// receiver's state lives on its own queue, so each job hops there.
    @available(macOS 15, *)
    private func fakeOnManualClock(
        _ manual: ManualDelayClock,
        startupLead: TimeInterval,
        steadyLead: TimeInterval,
        startupRebufferAfter: TimeInterval = 2,
        clockDriftPPM: Double = 0
    ) -> FakeCastReceiver {
        FakeCastReceiver(
            fetchBytes: Self.leadFetchBytes,
            startupLead: startupLead,
            steadyLead: steadyLead,
            startupRebufferAfter: startupRebufferAfter,
            clockDriftPPM: clockDriftPPM,
            uptimeClock: manual.uptime,
            delayClock: manual.queueHoppingClock
        )
    }

    /// Loads the live stream into `fake` and runs `body` once it is playing.
    /// Sender and receiver share `manual`, so no audio is served and no
    /// playback happens except when `play` moves that clock.
    ///
    /// `play(seconds)` moves it in 20 ms steps, the sender's own tick, and
    /// after each one waits until the sender has served that step's audio and
    /// the receiver has read it, so the receiver's buffer crosses its start
    /// threshold at the same audio position however slow the machine is.
    ///
    /// `lead` is the number the whole sync design turns on, measured exactly
    /// as the sender measures it: audio seconds handed over, minus the
    /// position the receiver reports.
    @available(macOS 15, *)
    private func withPlayingSession(
        _ fake: FakeCastReceiver,
        on manual: ManualDelayClock,
        _ body: (
            _ play: (TimeInterval) async -> Void,
            _ lead: () async throws -> Double,
            _ states: StateLog
        ) async throws -> Void
    ) async throws {
        let endpoint = try start(fake)
        let server = try startAudioServer(uptimeClock: manual.uptime)
        defer { server.stop() }
        let (channel, client) = try connect(to: endpoint)
        defer { channel.close() }
        let app = try launchedApplication(client)

        let states = StateLog()
        let playing = Signal()
        client.onMediaStatus = { status in
            states.append(status.playerState)
            if status.playerState == "PLAYING" { playing.fire() }
        }
        let loaded = Box<Result<CastMediaStatus, Error>>()
        client.load(url: server.url(host: "127.0.0.1"), contentType: "audio/wav", app: app) { loaded.set($0) }
        await SuiteWait.until("LOAD is answered") { loaded.value != nil }

        // The sender starts its pacing clock on its first tick after the GET,
        // at whatever the manual clock reads then. Nudge the clock until
        // that tick has happened and served some audio; a step taken before
        // it would only move the pacing clock's origin and serve nothing.
        await SuiteWait.until("the sender's pacing clock starts") {
            if server.secondsSent > 0 { return true }
            manual.advance(by: 0.001)
            return false
        }

        let step: TimeInterval = 0.02
        func advanceOneStep() async {
            let sent = server.secondsSent
            manual.advance(by: step)
            await SuiteWait.until("the sender serves the step's audio") { server.secondsSent > sent }
            // Received bytes carry chunk framing on top of the audio, so this
            // holds once every audio byte served so far has been read.
            await SuiteWait.until("the receiver reads the step's audio") {
                Double(fake.bodyBytesReceived) >= server.secondsSent * 176_400
            }
        }
        while fake.bodyBytesReceived < Self.leadFetchBytes { await advanceOneStep() }
        await SuiteWait.until("the receiver announces PLAYING") { playing.fired }

        try await body({ seconds in
            for _ in 0..<Int((seconds / step).rounded()) { await advanceOneStep() }
        }, {
            let box = Box<CastMediaStatus>()
            client.getMediaStatus(app: app) { result in
                if case .success(let status) = result { box.set(status) }
            }
            // Nothing moves while the clock stands still, so the two halves
            // of the subtraction describe the same instant.
            let sent = server.secondsSent
            await SuiteWait.until("GET_STATUS is answered") { box.value != nil }
            let time = try #require(box.value?.currentTime, "the receiver reported no media position")
            return sent - time
        }, states)
    }

    /// The receiver starts playing once it holds `startupLead` seconds, and
    /// the sender paces at exactly real time, so that buffer level is the
    /// lead, and it stays put. Turns red if `startPlaybackIfBuffered` starts
    /// the clock at any other buffer level (at `fetchBytes`, say), or if the
    /// sender's pacing stops tracking the clock it is given.
    @Test func theLeadSettlesAtTheStartupBuffer() async throws {
        guard #available(macOS 15, *) else { return }
        let manual = ManualDelayClock()
        let fake = fakeOnManualClock(manual, startupLead: 1, steadyLead: 1)
        defer { fake.stop() }
        try await withPlayingSession(fake, on: manual) { play, lead, _ in
            // PLAYING is announced at `fetchBytes`, well before the buffer is
            // full, so the first second of the session is still filling.
            await play(1.3)
            let first = try await lead()
            await play(1)
            let second = try await lead()
            #expect(abs(first - 1) < 0.05, Comment(rawValue: "expected a 1 s lead, measured \(first)"))
            #expect(abs(second - first) < 0.03,
                    Comment(rawValue: "the lead did not hold flat: \(first) then \(second)"))
        }
    }

    /// The event the whole room-delay policy exists for: the clock stands
    /// still while the stream keeps arriving, and the sender, pacing at
    /// exactly real time, can never give the difference back. Turns red if a
    /// stall stops freezing the play clock, or if the clock catches up the
    /// frozen time when it resumes.
    @Test func aStallLeavesTheLeadPermanentlyHigher() async throws {
        guard #available(macOS 15, *) else { return }
        let manual = ManualDelayClock()
        let fake = fakeOnManualClock(manual, startupLead: 1, steadyLead: 1)
        defer { fake.stop() }
        try await withPlayingSession(fake, on: manual) { play, lead, states in
            await play(1.3)
            let before = try await lead()
            let buffering = states.count(of: "BUFFERING")

            fake.stall(after: 0, duration: 0.5)
            await play(1.5)
            let after = try await lead()

            await SuiteWait.until("the stall shows as BUFFERING") { states.count(of: "BUFFERING") > buffering }
            #expect(states.count(of: "BUFFERING") > buffering,
                    Comment(rawValue: "the stall never showed as BUFFERING: \(states.all)"))
            #expect(abs((after - before) - 0.5) < 0.05,
                    Comment(rawValue: "expected the stall's 0.5 s to stick: \(before) then \(after)"))
        }
    }

    /// The measured session shape: it does not start at its steady value, it
    /// steps up there on one early rebuffer. Turns red if the startup
    /// rebuffer is never scheduled, or if it fires at playback start rather
    /// than `startupRebufferAfter` into it.
    @Test func theStartupProfileStepsUpOnce() async throws {
        guard #available(macOS 15, *) else { return }
        let manual = ManualDelayClock()
        let fake = fakeOnManualClock(manual, startupLead: 0.5, steadyLead: 1, startupRebufferAfter: 1)
        defer { fake.stop() }
        try await withPlayingSession(fake, on: manual) { play, lead, _ in
            await play(0.7)
            let started = try await lead()
            await play(1.6)
            let settled = try await lead()
            #expect(abs(started - 0.5) < 0.05, Comment(rawValue: "expected the 0.5 s startup lead, measured \(started)"))
            #expect(abs(settled - 1) < 0.05, Comment(rawValue: "expected the step to 1 s, measured \(settled)"))
        }
    }

    /// The receiver's crystal against the Mac's. 100 000 ppm is a clock 10 %
    /// fast, which shows in two seconds; the ~100 ppm a real one might drift
    /// would take an hour to move the lead 360 ms, and that is not a test.
    /// Turns red if `currentTime()` stops applying `clockDriftPPM`.
    @Test func theReceiverClockDrifts() async throws {
        guard #available(macOS 15, *) else { return }
        let manual = ManualDelayClock()
        let fake = fakeOnManualClock(manual, startupLead: 1, steadyLead: 1, clockDriftPPM: 100_000)
        defer { fake.stop() }
        try await withPlayingSession(fake, on: manual) { play, lead, _ in
            await play(1.3)
            let early = try await lead()
            await play(2)
            let late = try await lead()
            #expect(abs((early - late) - 0.2) < 0.03,
                    Comment(rawValue: "a fast clock must eat 200 ms of lead in two seconds: \(early) then \(late)"))
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
