// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import CastSender
import Foundation
import Network

/// Where one Cast receiver's session is in the recipe.
enum CastSessionState: Equatable, Sendable { case idle, connecting, playing, failed(CastSessionFailure) }

/// Why a Cast session gave up. The backend maps these onto
/// `ConnectionFailure.Cause` for the row; nothing here knows about rows.
enum CastSessionFailure: Equatable, Sendable {
    case timedOut
    case appUnavailable(reason: String?)
    case connectionFailed(String)
    case dropped(String?)
    case noLocalAddress
}

/// The seam `NativeBackend` drives Cast output through, so its tests never open
/// a socket.
protocol CastOutputControlling: AnyObject, Sendable {
    var onStateChange: (@Sendable (_ deviceID: String, _ state: CastSessionState) -> Void)? { get set }
    /// Measured Cast stream lag in whole seconds, non-nil ONLY while a
    /// fixed-volume (feed-gain) receiver is playing — non-nil means
    /// volume/mute are applied inside the audio feed and land ~this many
    /// seconds later. Always `nil` for attenuation receivers and stopped
    /// sessions.
    var onVolumeLagChange: (@Sendable (_ deviceID: String, _ lagSeconds: Int?) -> Void)? { get set }
    /// CAST-SYNC (brief §4): one trustworthy measurement of how far behind
    /// live this receiver is playing, at most one a second. Only samples the
    /// receiver was PLAYING for and answered promptly enough to believe are
    /// reported; the room-delay policy on the other end assumes as much.
    var onLeadSample: (@Sendable (_ deviceID: String, _ leadMs: Int) -> Void)? { get set }
    /// The capture fan-out slot: every whole-system buffer written here is
    /// copied into each desired receiver's feed ring.
    var feed: PCMSink { get }
    func setDevices(_ records: [CastDeviceRecord])
    func setLevel(_ level: Double, forDevice id: String)
    func retry(deviceID: String)
    func stopAll()
}

/// One Cast receiver's feed: the 2-second hand-off between the capture IOProc
/// (producer) and the HTTP server's pacing timer (consumer).
///
/// The producer never blocks and never allocates — a failed `try()` or a block
/// that does not fit is dropped whole, because a late buffer is worse than a
/// missing one on a stream the receiver is already 5.5 s behind. The consumer
/// zero-fills whatever is missing, so a starved ring plays silence rather than
/// stalling the socket.
///
/// The consumer also carries this receiver's volume when the receiver's own
/// volume is `fixed` (see ``CastOutputManager/pushLevel(_:_:)``): a scalar
/// gain applied on the way out, ramped so a fader drag does not step.
///
/// `razor:` ceiling — one scalar gain with a linear ramp. Mute-click
/// suppression or a dB mapping belongs here, in the ramp target, not at the
/// call sites.
final class CastFeedRing: CastPCMSource, @unchecked Sendable {

    /// 2 s at 44 100 Hz.
    private static let capacityFrames = 88_200
    /// The gain never moves faster than full scale per 20 ms, so any change
    /// inside [0, 1] lands within 882 frames and none of them zipper.
    private static let gainRampFrames = 882

    private let storage: UnsafeMutablePointer<Int16>
    private let lock = NSLock()
    private var readFrame = 0
    private var availableFrames = 0
    private var currentGain: Float = 1
    private var targetGain: Float = 1

    init() {
        storage = UnsafeMutablePointer<Int16>.allocate(capacity: Self.capacityFrames * 2)
        storage.initialize(repeating: 0, count: Self.capacityFrames * 2)
    }

    deinit {
        storage.deinitialize(count: Self.capacityFrames * 2)
        storage.deallocate()
    }

    /// Producer side (capture IOProc). Interleaved S16LE stereo, 4 bytes/frame.
    func push(_ pcm: Data) {
        let frames = pcm.count / 4
        guard frames > 0, lock.try() else { return }
        defer { lock.unlock() }
        guard availableFrames + frames <= Self.capacityFrames else { return }
        let writeFrame = (readFrame + availableFrames) % Self.capacityFrames
        let firstRun = min(frames, Self.capacityFrames - writeFrame)
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(storage + writeFrame * 2, base, firstRun * 4)
            if frames > firstRun {
                memcpy(storage, base + firstRun * 4, (frames - firstRun) * 4)
            }
        }
        availableFrames += frames
    }

    /// Consumer side (the server's pacing timer). Always exactly `frames * 4`
    /// bytes; anything the ring is short of is silence.
    func render(frames: Int) -> Data {
        guard frames > 0 else { return Data() }
        var out = Data(count: frames * 4)
        lock.lock()
        let taken = min(frames, availableFrames)
        if taken > 0 {
            let firstRun = min(taken, Self.capacityFrames - readFrame)
            out.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(base, storage + readFrame * 2, firstRun * 4)
                if taken > firstRun {
                    memcpy(base + firstRun * 4, storage, (taken - firstRun) * 4)
                }
            }
            readFrame = (readFrame + taken) % Self.capacityFrames
            availableFrames -= taken
        }
        // Unity on both ends is the whole attenuation-receiver path: the
        // memcpy above is all it costs.
        if currentGain != 1 || targetGain != 1 { applyGainLocked(&out, frames: frames) }
        lock.unlock()
        return out
    }

    /// The receiver's volume for a `fixed` receiver, in [0, 1]. Lock-guarded
    /// rather than queue-confined: the manager sets it from its own queue
    /// while the server's pacing timer is rendering.
    func setTargetGain(_ level: Double) {
        let clamped = Float(min(1, max(0, level)))
        lock.lock()
        targetGain = clamped
        lock.unlock()
    }

    /// What ``setTargetGain(_:)`` last asked for.
    var gainTarget: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(targetGain)
    }

    /// Called with the lock held, on the server's consumer queue. Gain is in
    /// [0, 1] so scaling down can never overflow; the clamp is defensive.
    private func applyGainLocked(_ out: inout Data, frames: Int) {
        let step = 1 / Float(Self.gainRampFrames)
        var gain = currentGain
        let target = targetGain
        out.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                if gain < target {
                    gain = min(target, gain + step)
                } else if gain > target {
                    gain = max(target, gain - step)
                }
                for channel in 0..<2 {
                    let index = frame * 2 + channel
                    let scaled = (Float(samples[index]) * gain).rounded()
                    samples[index] = Int16(max(-32_768, min(32_767, scaled)))
                }
            }
        }
        currentGain = gain
    }

    /// Drop the backlog. Called the moment the receiver's GET arrives, so what
    /// it starts playing is live audio and not up to 2 s of history.
    func reset() {
        lock.lock()
        readFrame = 0
        availableFrames = 0
        // A fresh GET starts at the level the user asked for, not partway
        // through the ramp the previous one was left in.
        currentGain = targetGain
        lock.unlock()
    }
}

/// The capture fan-out's Cast slot: one `write` in, one `push` per desired
/// receiver out. `pts` is ignored — a Cast receiver paces itself off the socket.
final class CastFanOut: PCMSink, @unchecked Sendable {

    private let lock = NSLock()
    private var rings: [CastFeedRing] = []

    func setRings(_ rings: [CastFeedRing]) {
        lock.lock()
        self.rings = rings
        lock.unlock()
    }

    func write(pcm: Data, pts: timespec) {
        // Called from the capture IOProc: never block, and never hold the lock
        // across the pushes.
        guard lock.try() else { return }
        let rings = self.rings
        lock.unlock()
        for ring in rings { ring.push(pcm) }
    }
}

/// Every Cast receiver Audiout is currently sending to, one session each.
///
/// A session is the measured recipe from the roadmap 006 spike: connect →
/// receiver status → serve a live WAV → launch the Default Media Receiver →
/// LOAD with `autoplay: false` → explicit PLAY. That ordering is what buys the
/// ~5.5 s lead instead of ~7.9 s; do not "simplify" it to `autoplay: true`.
///
/// Everything mutable is confined to ``queue``; every channel/client/server
/// completion hops onto it first. A completion whose captured generation no
/// longer matches its session belongs to a torn-down attempt and is dropped.
final class CastOutputManager: CastOutputControlling, @unchecked Sendable {

    /// How long a receiver gets to reach PLAYING before the session fails —
    /// and how long again from the moment its fetch starts. A Google TV
    /// Streamer has been measured issuing the GET 12 s after PLAY.
    static let defaultPlayDeadline: TimeInterval = 20
    /// Audio handed over up front, so the receiver's buffer target is met by
    /// bytes rather than by waiting. Silence, because the ring is reset by the
    /// GET that asks for it — the join gap is silent by design.
    private static let primeMilliseconds = 1000

    private let serverBindsLoopbackOnly: Bool
    private let streamHostOverride: String?
    private let requestTimeout: TimeInterval
    private let reconnectDelay: TimeInterval
    private let playDeadline: TimeInterval
    private let queue = DispatchQueue(label: "CastOutputManager")
    private let fanOut = CastFanOut()

    /// Lock-guarded rather than queue-confined: the backend sets it from its
    /// own queue while a session completion may be reading it on ``queue``.
    private let stateLock = NSLock()
    private var _onStateChange: (@Sendable (String, CastSessionState) -> Void)?
    private var _onVolumeLagChange: (@Sendable (String, Int?) -> Void)?
    private var _onLeadSample: (@Sendable (String, Int) -> Void)?

    /// Queue-confined.
    private var sessions: [String: Session] = [:]

    /// How many teardowns are still finishing per device id. A receiver that
    /// is handed LAUNCH while it is still processing the previous session's
    /// STOP answers with the app it is tearing down, and the new LOAD lands on
    /// a dead player — so a re-select waits for its predecessor's last hop.
    /// Queue-confined.
    private var teardownsInFlight: [String: Int] = [:]

    init(
        serverBindsLoopbackOnly: Bool = false,
        streamHostOverride: String? = nil,
        requestTimeout: TimeInterval = 10,
        reconnectDelay: TimeInterval = 2,
        playDeadline: TimeInterval = CastOutputManager.defaultPlayDeadline
    ) {
        self.serverBindsLoopbackOnly = serverBindsLoopbackOnly
        self.streamHostOverride = streamHostOverride
        self.requestTimeout = requestTimeout
        self.reconnectDelay = reconnectDelay
        self.playDeadline = playDeadline
    }

    var onStateChange: (@Sendable (String, CastSessionState) -> Void)? {
        get { stateLock.withLock { _onStateChange } }
        set { stateLock.withLock { _onStateChange = newValue } }
    }

    var onVolumeLagChange: (@Sendable (String, Int?) -> Void)? {
        get { stateLock.withLock { _onVolumeLagChange } }
        set { stateLock.withLock { _onVolumeLagChange = newValue } }
    }

    var onLeadSample: (@Sendable (String, Int) -> Void)? {
        get { stateLock.withLock { _onLeadSample } }
        set { stateLock.withLock { _onLeadSample = newValue } }
    }

    var feed: PCMSink { fanOut }

    /// One receiver's whole session. Queue-confined.
    private final class Session {
        let record: CastDeviceRecord
        let ring = CastFeedRing()
        var channel: CastChannel?
        var client: CastClient?
        var server: CastLiveAudioServer?
        var application: CastApplication?
        var mediaSessionID: Int?
        /// Bumped by every teardown; a completion carrying an older value is a
        /// late callback of an attempt nobody is waiting for any more.
        var generation = 0
        var state: CastSessionState = .idle
        var controlReady = false
        var requestedLevel: Double?
        var levelInFlight = false
        var levelPending: Double?
        var autoRetryCount = 0
        var playDeadline: DispatchWorkItem?
        var statusPoll: DispatchSourceTimer?
        var wasPlaying = false
        /// `fixed` receivers ignore `SET_VOLUME`; their level is carried by
        /// the feed's gain instead.
        var volumeControlIsFixed = false
        /// Last lag value reported via `onVolumeLagChange`, so `handle(_:id:generation:)`
        /// only fires on a genuine change.
        var reportedLagSeconds: Int?
        /// Only the FIRST GET is logged — the interesting fact is whether the
        /// receiver ever reached the server at all.
        var loggedHTTPRequest = false
        /// Set while this id's PREVIOUS session is still tearing down: the
        /// recipe starts from that teardown's completion, not here.
        var awaitingTeardown = false

        init(record: CastDeviceRecord) { self.record = record }
    }

    /// Which step an error came out of — the same `CastError` means different
    /// things after LAUNCH than it does after LOAD.
    private enum Stage { case connect, launch, media }

    // MARK: - CastOutputControlling

    func setDevices(_ records: [CastDeviceRecord]) {
        queue.async { [weak self] in
            guard let self else { return }
            let desired = Set(records.map(\.id))
            for (id, session) in self.sessions where !desired.contains(id) {
                self.teardown(session)
                self.sessions.removeValue(forKey: id)
                self.setState(session, .idle)
            }
            // An id present in both is left alone: a re-advertised endpoint is
            // not a reason to interrupt a playing receiver.
            for record in records where self.sessions[record.id] == nil {
                let session = Session(record: record)
                self.sessions[record.id] = session
                if self.teardownsInFlight[record.id] != nil {
                    // The row is connecting from the user's point of view the
                    // instant it is selected, waiting included.
                    session.awaitingTeardown = true
                    self.setState(session, .connecting)
                } else {
                    self.startRecipe(session)
                }
            }
            self.fanOut.setRings(self.sessions.values.map(\.ring))
        }
    }

    func setLevel(_ level: Double, forDevice id: String) {
        let clamped = min(1, max(0, level))
        queue.async { [weak self] in
            guard let self, let session = self.sessions[id] else { return }
            session.requestedLevel = clamped
            guard session.controlReady else { return }
            self.pushLevel(session, clamped)
        }
    }

    func retry(deviceID: String) {
        queue.async { [weak self] in
            guard let self, let session = self.sessions[deviceID] else { return }
            session.autoRetryCount = 0
            self.teardown(session)
            self.startRecipe(session)
        }
    }

    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for (_, session) in self.sessions {
                self.teardown(session)
                self.setState(session, .idle)
            }
            self.sessions.removeAll()
            self.fanOut.setRings([])
        }
    }

    // MARK: - The recipe (on queue)

    private func startRecipe(_ session: Session) {
        session.generation += 1
        let generation = session.generation
        let id = session.record.id
        setState(session, .connecting)
        let channel = CastChannel(endpoint: session.record.endpoint, requestTimeout: requestTimeout)
        session.channel = channel
        session.client = CastClient(channel: channel)
        channel.onClose = { [weak self] error in
            self?.queue.async { self?.handleDrop(id: id, generation: generation, reason: error.map { String(describing: $0) }) }
        }
        channel.connect { [weak self] result in
            self?.queue.async { self?.afterConnect(result, id: id, generation: generation) }
        }
    }

    private func afterConnect(_ result: Result<Void, Error>, id: String, generation: Int) {
        guard let session = live(id, generation) else { return }
        if case .failure(let error) = result { fail(session, error, stage: .connect); return }
        session.client?.getReceiverStatus { [weak self] result in
            self?.queue.async { self?.afterReceiverStatus(result, id: id, generation: generation) }
        }
    }

    private func afterReceiverStatus(_ result: Result<CastReceiverStatus, Error>, id: String, generation: Int) {
        guard let session = live(id, generation) else { return }
        let status: CastReceiverStatus
        switch result {
        case .failure(let error):
            fail(session, error, stage: .connect)
            return
        case .success(let received):
            status = received
        }
        session.volumeControlIsFixed = status.volumeControlType == "fixed"
        session.controlReady = true
        guard let host = streamHostOverride ?? session.channel?.localIPv4Address else {
            fail(session, CastError.noLocalAddress, stage: .connect)
            return
        }
        let server = CastLiveAudioServer(
            source: session.ring,
            loopbackOnly: serverBindsLoopbackOnly,
            primeMilliseconds: Self.primeMilliseconds
        )
        // The reset fires on the server's queue, synchronously ahead of the
        // prime render, so the receiver's first bytes are the live edge of the
        // feed. The log line hops onto ``queue`` — the session's flag is
        // queue-confined, and Telemetry never belongs on an audio path.
        server.onRequest = { [weak self, weak session] _ in
            session?.ring.reset()
            self?.queue.async {
                guard let self, let session = self.live(id, generation) else { return }
                guard !session.loggedHTTPRequest else {
                    // CAST-SYNC: the reset above just threw away up to 2 s of
                    // audio the receiver was already holding, so it lands that
                    // much closer to live than the room is delayed for. The
                    // lead metric reads it as a step DOWN and the policy
                    // re-settles on its own — this line is what makes the step
                    // explicable afterwards.
                    Telemetry.log(.cast, "cast_http_reget", ["device": id])
                    return
                }
                session.loggedHTTPRequest = true
                Telemetry.log(.cast, "cast_http_request", ["device": id])
                // A receiver that is fetching is demonstrably alive, so only
                // the stretch from here to PLAYING is worth timing.
                self.armPlayDeadline(session, id: id, generation: generation)
            }
        }
        session.server = server
        server.start { [weak self] result in
            self?.queue.async { self?.afterServerStart(result, id: id, generation: generation, host: host) }
        }
    }

    private func afterServerStart(_ result: Result<UInt16, Error>, id: String, generation: Int, host: String) {
        guard let session = live(id, generation) else { return }
        if case .failure(let error) = result { fail(session, error, stage: .connect); return }
        guard let url = session.server?.url(host: host) else {
            fail(session, CastError.noLocalAddress, stage: .connect)
            return
        }
        Telemetry.log(.cast, "cast_server_ready", [
            "device": id,
            "host": host,
            "port": String(session.server?.port ?? 0),
        ])
        session.client?.launch(appID: CastClient.defaultMediaReceiverAppID) { [weak self] result in
            self?.queue.async { self?.afterLaunch(result, id: id, generation: generation, url: url) }
        }
    }

    private func afterLaunch(_ result: Result<CastApplication, Error>, id: String, generation: Int, url: URL) {
        guard let session = live(id, generation) else { return }
        let app: CastApplication
        switch result {
        case .failure(let error):
            fail(session, error, stage: .launch)
            return
        case .success(let launched):
            app = launched
        }
        // A re-select that is handed the JUST-torn-down session's transport id
        // is the receiver answering with an app it is still stopping.
        Telemetry.log(.cast, "cast_launch_ok", [
            "device": id,
            "transport": app.transportID,
            "session": app.sessionID,
            "app": app.appID,
        ])
        session.application = app
        session.client?.onMediaStatus = { [weak self] status in
            self?.queue.async { self?.handle(status, id: id, generation: generation) }
        }
        if let level = session.requestedLevel { pushLevel(session, level) }
        armPlayDeadline(session, id: id, generation: generation)
        session.client?.load(url: url, contentType: "audio/wav", streamType: "LIVE", autoplay: false, app: app) { [weak self] result in
            self?.queue.async {
                guard let self, let session = self.live(id, generation) else { return }
                switch result {
                case .failure(let error):
                    Telemetry.log(.cast, "cast_load_reply", ["device": id, "error": String(describing: error)])
                    self.fail(session, error, stage: .media)
                case .success(let status):
                    Telemetry.log(.cast, "cast_load_reply", [
                        "device": id,
                        "state": status.playerState,
                        "media": status.mediaSessionID.map(String.init) ?? "nil",
                    ])
                    guard let media = status.mediaSessionID else { return }
                    session.mediaSessionID = media
                    Telemetry.log(.cast, "cast_play_sent", ["device": id, "media": String(media)])
                    session.client?.play(mediaSessionID: media, app: app) { _ in }
                }
            }
        }
    }

    /// Fails the session unless PLAYING arrives within ``playDeadline``.
    /// Replaces any pending one — the receiver's first GET restarts the clock.
    private func armPlayDeadline(_ session: Session, id: String, generation: Int) {
        session.playDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, let session = self.live(id, generation) else { return }
            self.fail(session, CastError.timeout, stage: .media)
        }
        session.playDeadline = deadline
        queue.asyncAfter(deadline: .now() + playDeadline, execute: deadline)
    }

    /// Every media status the receiver produces, solicited or not.
    private func handle(_ status: CastMediaStatus, id: String, generation: Int) {
        guard let session = live(id, generation) else { return }
        var lead = "nil"
        if let seconds = Self.leadSeconds(session, status) {
            lead = String(format: "%.2f", seconds)
            if session.volumeControlIsFixed {
                let lagSeconds = Int(max(0, seconds).rounded())
                if lagSeconds != session.reportedLagSeconds {
                    session.reportedLagSeconds = lagSeconds
                    onVolumeLagChange?(id, lagSeconds)
                }
            }
        }
        Telemetry.log(.cast, "cast_media_status", ["device": id, "state": status.playerState, "lead_s": lead])
        if let media = status.mediaSessionID { session.mediaSessionID = media }
        if status.playerState == "PLAYING" {
            session.playDeadline?.cancel()
            session.playDeadline = nil
            session.wasPlaying = true
            // "Three CONSECUTIVE automatic attempts": reaching PLAYING ends the
            // run, so a receiver that drops once a day is never written off.
            session.autoRetryCount = 0
            setState(session, .playing)
            if session.statusPoll == nil { armStatusPoll(session, id: id, generation: generation) }
        }
        // IDLE after having played is the receiver walking away mid-stream —
        // the same event as a dropped control connection.
        if status.playerState == "IDLE", session.wasPlaying {
            handleDrop(id: id, generation: generation, reason: status.idleReason)
        }
    }

    /// How far behind live this receiver is playing, in seconds — the audio we
    /// have handed the socket minus the point it says it has reached. `nil`
    /// unless it is actually playing: a paused or buffering receiver's
    /// `currentTime` stands still while `secondsSent` does not.
    private static func leadSeconds(_ session: Session, _ status: CastMediaStatus) -> Double? {
        guard status.playerState == "PLAYING", let time = status.currentTime,
              let sent = session.server?.secondsSent else { return nil }
        return sent - time
    }

    /// A lead measurement is only believed if the answer came back inside
    /// this. A reply that queued behind a stall carries a `currentTime` from
    /// before the queue, which reads as a lead seconds too long — and how long
    /// the answer took is the cheapest way to tell that apart from a receiver
    /// that has genuinely fallen further behind. The roadmap 006 spike measured
    /// a settled control round trip at 17 ms and a mid-stall one at ~1 s, so
    /// there is an order of magnitude either side of this line.
    private static let leadRoundTripLimitMs = 100

    /// One `GET_STATUS` a second: the receiver volunteers state changes, but
    /// `currentTime` (and with it the measured lead) only arrives when asked.
    /// The reply is TIMED as well as read (CAST-SYNC, brief §4) — the room's
    /// whole delay is derived from these samples, so a slow one is thrown away
    /// rather than believed.
    private func armStatusPoll(_ session: Session, id: String, generation: Int) {
        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(deadline: .now() + 1, repeating: 1)
        poll.setEventHandler { [weak self] in
            guard let self, let session = self.live(id, generation), let app = session.application else { return }
            let asked = DispatchTime.now()
            session.client?.getMediaStatus(app: app) { [weak self] result in
                guard case .success(let status) = result else { return }
                // Timed HERE, in the channel's own completion, before the hop
                // onto `queue`: a busy queue is this process being slow, not
                // the receiver, and charging it to the receiver would throw
                // away good samples exactly when the Mac is under load.
                let roundTripMs = Int(
                    (DispatchTime.now().uptimeNanoseconds - asked.uptimeNanoseconds) / 1_000_000)
                self?.queue.async {
                    guard let self, let session = self.live(id, generation) else { return }
                    self.reportLead(session, status, roundTripMs: roundTripMs, id: id)
                }
            }
        }
        session.statusPoll = poll
        poll.resume()
    }

    /// Hand one measured lead to the room-delay policy (on ``queue``).
    private func reportLead(_ session: Session, _ status: CastMediaStatus,
                            roundTripMs: Int, id: String) {
        guard let seconds = Self.leadSeconds(session, status) else { return }
        let leadMs = Int((seconds * 1_000).rounded())
        let kept = roundTripMs < Self.leadRoundTripLimitMs
        Telemetry.log(.cast, "cast_lead_sample", [
            "device": id,
            "lead_ms": String(leadMs),
            "rtt_ms": String(roundTripMs),
            "kept": kept ? "1" : "0",
        ])
        guard kept else { return }
        onLeadSample?(id, leadMs)
    }

    // MARK: - Volume (on queue)

    /// Latest-wins, one `SET_VOLUME` in flight per receiver — the
    /// `NativeBackend.pushVolume` idiom. Failures are swallowed: the next user
    /// action reconciles.
    ///
    /// A `fixed` receiver ignores `SET_VOLUME` outright (and tells the user to
    /// reach for the TV remote), so its level is applied to the audio we serve
    /// it instead. The composed `Main × Group × Device` level is the same
    /// either way; only where it lands differs.
    private func pushLevel(_ session: Session, _ level: Double) {
        guard !session.volumeControlIsFixed else {
            session.ring.setTargetGain(level)
            return
        }
        guard !session.levelInFlight else { session.levelPending = level; return }
        session.levelInFlight = true
        issueLevel(session, level)
    }

    private func issueLevel(_ session: Session, _ level: Double) {
        guard let client = session.client else { session.levelInFlight = false; return }
        let id = session.record.id
        let generation = session.generation
        client.setVolume(level: level) { [weak self] _ in
            self?.queue.async {
                guard let self, let session = self.live(id, generation) else { return }
                if let next = session.levelPending {
                    session.levelPending = nil
                    self.issueLevel(session, next)
                } else {
                    session.levelInFlight = false
                }
            }
        }
    }

    // MARK: - Failure and teardown (on queue)

    /// A drop while the receiver is still wanted: one reconnect run of at most
    /// three attempts, then the row is failed and left to the user's retry.
    private func handleDrop(id: String, generation: Int, reason: String?) {
        guard let session = live(id, generation) else { return }
        teardown(session)
        session.autoRetryCount += 1
        guard session.autoRetryCount <= 3 else {
            setState(session, .failed(.dropped(reason)))
            return
        }
        setState(session, .connecting)
        let waiting = session.generation
        queue.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self, let session = self.live(id, waiting) else { return }
            self.startRecipe(session)
        }
    }

    private func fail(_ session: Session, _ error: Error, stage: Stage) {
        teardown(session)
        setState(session, .failed(Self.failure(for: error, stage: stage)))
    }

    private static func failure(for error: Error, stage: Stage) -> CastSessionFailure {
        switch error {
        case CastError.timeout:
            return .timedOut
        case CastError.connectionFailed(let message):
            return message.contains("timed out") ? .timedOut : .connectionFailed(message)
        case CastError.noLocalAddress:
            return .noLocalAddress
        case CastError.applicationNotInStatus(let appID):
            return .appUnavailable(reason: appID)
        case CastError.receiverError(let type, let reason):
            // A receiver that refuses LAUNCH cannot run the Default Media
            // Receiver at all; the same error after LOAD is this stream only.
            return stage == .launch ? .appUnavailable(reason: reason) : .dropped(type)
        default:
            return .dropped(String(describing: error))
        }
    }

    /// Best-effort, in the receiver's own order: stop the media, stop the app,
    /// close the channel, stop the server. A step that fails still hands over
    /// to the next one — the session object survives, its transport does not.
    private func teardown(_ session: Session) {
        let id = session.record.id
        teardownsInFlight[id, default: 0] += 1

        session.playDeadline?.cancel()
        session.playDeadline = nil
        session.statusPoll?.cancel()
        session.statusPoll = nil
        session.levelInFlight = false
        session.levelPending = nil
        session.controlReady = false
        session.wasPlaying = false
        session.generation += 1
        if session.reportedLagSeconds != nil {
            session.reportedLagSeconds = nil
            onVolumeLagChange?(id, nil)
        }

        let channel = session.channel
        let server = session.server
        let client = session.client
        let application = session.application
        let media = session.mediaSessionID
        session.channel = nil
        session.server = nil
        session.client = nil
        session.application = nil
        session.mediaSessionID = nil
        channel?.onClose = nil
        client?.onMediaStatus = nil

        let finish = { [weak self] in
            channel?.close()
            server?.stop()
            self?.queue.async { self?.teardownFinished(id) }
        }
        guard let client, let application else { finish(); return }
        let stopApplication = {
            client.stopApplication(sessionID: application.sessionID) { _ in finish() }
        }
        if let media {
            client.stopMedia(mediaSessionID: media, app: application) { _ in stopApplication() }
        } else {
            stopApplication()
        }
    }

    /// The last hop of one teardown. When the id has no other teardown still
    /// running, a session that was re-selected during it starts its recipe
    /// here — the receiver has answered STOP by now, so its LAUNCH is a clean
    /// one.
    ///
    /// `razor:` ceiling — the completion chain the teardown already had. A
    /// fixed settle delay would also serialize, less reliably.
    private func teardownFinished(_ id: String) {
        guard let remaining = teardownsInFlight[id] else { return }
        guard remaining <= 1 else {
            teardownsInFlight[id] = remaining - 1
            return
        }
        teardownsInFlight.removeValue(forKey: id)
        guard let session = sessions[id], session.awaitingTeardown else { return }
        session.awaitingTeardown = false
        startRecipe(session)
    }

    // MARK: - Test seam

    /// The feed ring one device's session renders from, so a test can read the
    /// gain a `fixed` receiver's level landed in.
    func test_ring(forDevice id: String) -> CastFeedRing? {
        queue.sync { sessions[id]?.ring }
    }

    // MARK: - Helpers (on queue)

    /// The session for `id` if this completion still belongs to it.
    private func live(_ id: String, _ generation: Int) -> Session? {
        guard let session = sessions[id], session.generation == generation else { return nil }
        return session
    }

    private func setState(_ session: Session, _ state: CastSessionState) {
        guard session.state != state else { return }
        session.state = state
        Telemetry.log(.cast, "cast_session_state", ["device": session.record.id, "state": Self.name(state)])
        onStateChange?(session.record.id, state)
    }

    private static func name(_ state: CastSessionState) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .playing: return "playing"
        case .failed: return "failed"
        }
    }
}
