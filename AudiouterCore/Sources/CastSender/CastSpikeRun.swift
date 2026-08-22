// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation
import Network

/// The whole Phase-0 measurement, start to finish: connect, launch the Default
/// Media Receiver, serve it a live WAV stream, and time what it does about it.
///
/// This is the "roadmap 006 Phase 0" experiment as a single object so the CLI
/// is a thin wrapper and the same run is exercised in tests against the fake
/// receiver. Everything here is confined to ``queue`` — every callback from
/// the channel, the client and the server hops onto it before touching state.
public final class CastSpikeRun: @unchecked Sendable {

    public struct Options {
        public var endpoint: NWEndpoint
        /// The address the receiver should fetch audio from. Nil means "use
        /// whatever local address the control connection ended up on".
        public var streamHost: String?
        public var loopbackOnly: Bool
        public var holdSeconds: Double
        public var volumeLevel: Double
        public var primeMilliseconds: Int
        /// Cast `streamType` sent with LOAD: LIVE, BUFFERED or NONE.
        public var streamType: String
        /// Receiver app to launch; AirConnect uses its own `46C1A819`.
        public var appID: String
        /// LOAD with autoplay, or LOAD then an explicit PLAY (AirConnect).
        public var autoplay: Bool

        public init(
            endpoint: NWEndpoint,
            streamHost: String? = nil,
            loopbackOnly: Bool = false,
            holdSeconds: Double = 20,
            volumeLevel: Double = 0.3,
            primeMilliseconds: Int = 0,
            streamType: String = "LIVE",
            appID: String = CastClient.defaultMediaReceiverAppID,
            autoplay: Bool = true
        ) {
            self.endpoint = endpoint
            self.streamHost = streamHost
            self.loopbackOnly = loopbackOnly
            self.holdSeconds = holdSeconds
            self.volumeLevel = volumeLevel
            self.primeMilliseconds = primeMilliseconds
            self.streamType = streamType
            self.appID = appID
            self.autoplay = autoplay
        }
    }

    /// The numbers Phase 0 exists to produce. Nil means "never observed".
    public struct Summary {
        public var loadToPlayingMs: Double?
        public var bufferingToPlayingMs: Double?
        public var volumeRoundTripMs: Double?
        public var pauseRoundTripMs: Double?
        public var resumeRoundTripMs: Double?
        public var firstPlayerState: String?

        public init() {}
    }

    /// How long a receiver gets to reach PLAYING before the run is called off.
    private static let playDeadline: TimeInterval = 15

    private let options: Options
    private let logSink: (String) -> Void
    private let queue = DispatchQueue(label: "CastSpikeRun")
    private let startedAt = DispatchTime.now()

    private var channel: CastChannel?
    private var client: CastClient?
    private var server: CastLiveAudioServer?
    private var application: CastApplication?
    private var mediaSessionID: Int?
    private var baselineVolume: Double = 1
    private var loadSentAt: DispatchTime?
    private var firstBufferingAt: DispatchTime?
    private var firstPlayingAt: DispatchTime?
    private var playTimeout: DispatchWorkItem?
    private var statusWaiter: ((CastMediaStatus) -> Void)?
    private var summary = Summary()
    private var completion: ((Result<Summary, Error>) -> Void)?
    private var finished = false

    public init(options: Options, log: @escaping (String) -> Void) {
        self.options = options
        self.logSink = log
    }

    public func run(completion: @escaping (Result<Summary, Error>) -> Void) {
        queue.async { [self] in
            self.completion = completion
            log("connect endpoint=\(options.endpoint)")
            let channel = CastChannel(endpoint: options.endpoint)
            self.channel = channel
            self.client = CastClient(channel: channel)
            channel.connect { [weak self] result in
                self?.queue.async { self?.afterConnect(result) }
            }
        }
    }

    // MARK: - Steps

    private func afterConnect(_ result: Result<Void, Error>) {
        switch result {
        case .failure(let error):
            fail(error)
        case .success:
            log("tls_ready local=\(channel?.localIPv4Address ?? "nil")")
            client?.getReceiverStatus { [weak self] result in
                self?.queue.async { self?.afterReceiverStatus(result) }
            }
        }
    }

    private func afterReceiverStatus(_ result: Result<CastReceiverStatus, Error>) {
        switch result {
        case .failure(let error):
            fail(error)
        case .success(let status):
            log("receiver_status level=\(status.volumeLevel) muted=\(status.muted) apps=\(status.applications.count)")
            baselineVolume = status.volumeLevel
            guard let host = options.streamHost ?? channel?.localIPv4Address else {
                fail(CastError.noLocalAddress)
                return
            }
            let server = CastLiveAudioServer(
                source: SineSource(),
                loopbackOnly: options.loopbackOnly,
                primeMilliseconds: options.primeMilliseconds
            )
            server.onRequest = { [weak self] head in
                self?.queue.async {
                    let lines = head.split(separator: "\r\n")
                    let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { " \($0)" } ?? ""
                    self?.log("http_request \(lines.first ?? "")\(range)")
                }
            }
            self.server = server
            server.start { [weak self] result in
                self?.queue.async { self?.afterServerStart(result, host: host) }
            }
        }
    }

    private func afterServerStart(_ result: Result<UInt16, Error>, host: String) {
        switch result {
        case .failure(let error):
            fail(error)
        case .success:
            guard let url = server?.url(host: host) else { fail(CastError.noLocalAddress); return }
            log("stream_url=\(url.absoluteString)")
            client?.launch(appID: options.appID) { [weak self] result in
                self?.queue.async { self?.afterLaunch(result, url: url) }
            }
        }
    }

    private func afterLaunch(_ result: Result<CastApplication, Error>, url: URL) {
        switch result {
        case .failure(let error):
            fail(error)
        case .success(let app):
            log("launched transportId=\(app.transportID) sessionId=\(app.sessionID)")
            application = app
            client?.onMediaStatus = { [weak self] status in
                self?.queue.async { self?.handle(status) }
            }
            let timeout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.log("never_played")
                self.fail(CastError.timeout)
            }
            playTimeout = timeout
            queue.asyncAfter(deadline: .now() + Self.playDeadline, execute: timeout)
            statusWaiter = { [weak self] status in
                guard status.playerState == "PLAYING", let self else { return }
                self.statusWaiter = nil
                self.playTimeout?.cancel()
                self.playTimeout = nil
                self.afterPlaying()
            }
            loadSentAt = DispatchTime.now()
            client?.load(url: url, contentType: "audio/wav", streamType: options.streamType, autoplay: options.autoplay, app: app) { [weak self] result in
                if case .success(let status) = result, !(self?.options.autoplay ?? true), let session = status.mediaSessionID {
                    self?.queue.async {
                        self?.log("play_sent")
                        self?.client?.play(mediaSessionID: session, app: app) { _ in }
                    }
                    return
                }
                guard case .failure(let error) = result else { return }
                self?.queue.async { self?.fail(error) }
            }
            log("load_sent")
        }
    }

    /// Every media status the receiver produces, solicited or not.
    private func handle(_ status: CastMediaStatus) {
        guard !finished else { return }
        var lead = ""
        if let t = status.currentTime, let sent = server?.secondsSent, status.playerState == "PLAYING" {
            lead = String(format: " t=%.2f lead_s=%.2f", t, sent - t)
        }
        log("media_status state=\(status.playerState)"
            + " session=\(status.mediaSessionID.map(String.init) ?? "nil")"
            + " idle=\(status.idleReason ?? "nil")" + lead)
        if summary.firstPlayerState == nil { summary.firstPlayerState = status.playerState }
        if let session = status.mediaSessionID { mediaSessionID = session }
        if status.playerState == "BUFFERING", firstBufferingAt == nil { firstBufferingAt = DispatchTime.now() }
        if status.playerState == "PLAYING", firstPlayingAt == nil { firstPlayingAt = DispatchTime.now() }
        statusWaiter?(status)
    }

    private func afterPlaying() {
        guard let playing = firstPlayingAt else { fail(CastError.timeout); return }
        if let buffering = firstBufferingAt { summary.bufferingToPlayingMs = milliseconds(buffering, playing) }
        if let sent = loadSentAt { summary.loadToPlayingMs = milliseconds(sent, playing) }
        log("buffering_to_playing_ms=\(format(summary.bufferingToPlayingMs))")
        log("load_to_playing_ms=\(format(summary.loadToPlayingMs))")

        let sentAt = DispatchTime.now()
        client?.setVolume(level: options.volumeLevel) { [weak self] result in
            self?.queue.async {
                guard let self else { return }
                if case .failure(let error) = result { self.fail(error); return }
                self.summary.volumeRoundTripMs = self.milliseconds(sentAt, DispatchTime.now())
                self.log("volume_roundtrip_ms=\(self.format(self.summary.volumeRoundTripMs))")
                self.client?.setVolume(level: self.baselineVolume) { [weak self] result in
                    self?.queue.async {
                        guard let self else { return }
                        if case .failure(let error) = result { self.fail(error); return }
                        // Poll during the hold so every status line carries the lead.
                        let poll = DispatchSource.makeTimerSource(queue: self.queue)
                        poll.schedule(deadline: .now() + 5, repeating: 5)
                        poll.setEventHandler { [weak self] in
                            guard let self, !self.finished, let app = self.application else { return }
                            self.client?.getMediaStatus(app: app) { _ in }
                        }
                        poll.resume()
                        self.queue.asyncAfter(deadline: .now() + self.options.holdSeconds) { [weak self] in
                            poll.cancel()
                            self?.pauseStep()
                        }
                    }
                }
            }
        }
    }

    private func pauseStep() {
        guard !finished else { return }
        guard let app = application, let session = mediaSessionID else {
            fail(CastError.protocolViolation("no media session to pause"))
            return
        }
        let sentAt = DispatchTime.now()
        statusWaiter = { [weak self] status in
            guard status.playerState == "PAUSED", let self else { return }
            self.statusWaiter = nil
            self.summary.pauseRoundTripMs = self.milliseconds(sentAt, DispatchTime.now())
            self.log("pause_roundtrip_ms=\(self.format(self.summary.pauseRoundTripMs))")
            self.resumeStep()
        }
        client?.pause(mediaSessionID: session, app: app) { [weak self] result in
            guard case .failure(let error) = result else { return }
            self?.queue.async { self?.fail(error) }
        }
    }

    private func resumeStep() {
        guard let app = application, let session = mediaSessionID else {
            fail(CastError.protocolViolation("no media session to resume"))
            return
        }
        let sentAt = DispatchTime.now()
        statusWaiter = { [weak self] status in
            guard status.playerState == "PLAYING", let self else { return }
            self.statusWaiter = nil
            self.summary.resumeRoundTripMs = self.milliseconds(sentAt, DispatchTime.now())
            self.log("resume_roundtrip_ms=\(self.format(self.summary.resumeRoundTripMs))")
            self.teardown()
        }
        client?.play(mediaSessionID: session, app: app) { [weak self] result in
            guard case .failure(let error) = result else { return }
            self?.queue.async { self?.fail(error) }
        }
    }

    private func teardown() {
        guard let app = application, let session = mediaSessionID else {
            fail(CastError.protocolViolation("no media session to stop"))
            return
        }
        client?.stopMedia(mediaSessionID: session, app: app) { [weak self] result in
            self?.queue.async {
                guard let self else { return }
                if case .failure(let error) = result { self.fail(error); return }
                self.client?.stopApplication(sessionID: app.sessionID) { [weak self] result in
                    self?.queue.async {
                        guard let self else { return }
                        if case .failure(let error) = result { self.fail(error); return }
                        self.channel?.close()
                        self.server?.stop()
                        self.log("done")
                        self.finish(.success(self.summary))
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func fail(_ error: Error) {
        guard !finished else { return }
        log("error=\(error)")
        playTimeout?.cancel()
        playTimeout = nil
        statusWaiter = nil
        channel?.close()
        server?.stop()
        finish(.failure(error))
    }

    private func finish(_ result: Result<Summary, Error>) {
        guard !finished else { return }
        finished = true
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    private func log(_ event: String) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000
        logSink(String(format: "+%.3fs ", elapsed) + event)
    }

    private func milliseconds(_ from: DispatchTime, _ to: DispatchTime) -> Double {
        Double(to.uptimeNanoseconds - from.uptimeNanoseconds) / 1_000_000
    }

    private func format(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "nil"
    }
}
