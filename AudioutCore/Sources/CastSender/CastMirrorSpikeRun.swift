// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation
import Network

/// The Cast Streaming (mirroring) spike, start to finish: connect, launch the
/// mirroring receiver app, OFFER one Opus stream, take the ANSWER, then stream
/// silence with a probe every `probePeriodSeconds` for `holdSeconds`.
///
/// Every frame's pts is generated on `CLOCK_MONOTONIC` from the first tick, so
/// a probe's pts plus the target delay is when the receiver should sound it;
/// the CLI's microphone measures the difference. Confined to ``queue``.
public final class CastMirrorSpikeRun: @unchecked Sendable {

    public struct Options {
        public var endpoint: NWEndpoint
        public var appID: String
        public var targetDelayMs: Int
        public var framesPerPacket: Int
        public var bitRate: Int
        public var rtpPayloadType: UInt8
        public var holdSeconds: Double
        public var probePeriodSeconds: Double
        public var probeAmplitude: Float
        /// Mono, 48 kHz; mixed identically into both channels.
        public var probeSamples: [Float]
        /// Called on the run's queue when a probe's first sample is generated.
        public var onProbe: ((_ index: Int, _ ptsNanos: UInt64) -> Void)?

        public init(
            endpoint: NWEndpoint,
            appID: String = "85CDB22F",
            targetDelayMs: Int = 400,
            framesPerPacket: Int = 480,
            bitRate: Int = 128_000,
            rtpPayloadType: UInt8 = 127,
            holdSeconds: Double = 20,
            probePeriodSeconds: Double = 1.0,
            probeAmplitude: Float = 0.3,
            probeSamples: [Float] = [],
            onProbe: ((_ index: Int, _ ptsNanos: UInt64) -> Void)? = nil
        ) {
            self.endpoint = endpoint
            self.appID = appID
            self.targetDelayMs = targetDelayMs
            self.framesPerPacket = framesPerPacket
            self.bitRate = bitRate
            self.rtpPayloadType = rtpPayloadType
            self.holdSeconds = holdSeconds
            self.probePeriodSeconds = probePeriodSeconds
            self.probeAmplitude = probeAmplitude
            self.probeSamples = probeSamples
            self.onProbe = onProbe
        }
    }

    /// openscreen's sender gives an ANSWER this long.
    private static let answerDeadline: TimeInterval = 4
    private static let statsInterval: TimeInterval = 5
    private static let offerSeqNum = 1

    private let options: Options
    private let logSink: (String) -> Void
    private let queue = DispatchQueue(label: "CastMirrorSpikeRun")
    private let startedAt = DispatchTime.now()
    private let offer: CastStreamingOffer

    private let ptsLock = NSLock()
    private var _firstFramePtsNanos: UInt64?

    // Queue-confined below this line.
    private var channel: CastChannel?
    private var client: CastClient?
    private var application: CastApplication?
    private var session: CastStreamingSession?
    private var answerTimeout: DispatchWorkItem?
    private var generator: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private var nextFrame = 0
    private var completion: ((Result<CastStreamingSession.Stats, Error>) -> Void)?
    private var finished = false

    public init(options: Options, log: @escaping (String) -> Void) {
        self.options = options
        self.logSink = log
        self.offer = CastStreamingOffer(
            targetDelayMs: options.targetDelayMs, rtpPayloadType: options.rtpPayloadType, bitRate: options.bitRate)
    }

    /// The pts of frame 0, `CLOCK_MONOTONIC` nanoseconds; frame k's pts is this
    /// plus k frame durations. Nil until streaming starts.
    public var firstFramePtsNanos: UInt64? { ptsLock.withLock { _firstFramePtsNanos } }

    public func run(completion: @escaping (Result<CastStreamingSession.Stats, Error>) -> Void) {
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
        if case .failure(let error) = result { fail(error); return }
        log("tls_ready remote=\(channel?.remoteIPv4Address ?? "nil")")
        client?.getReceiverStatus { [weak self] result in
            self?.queue.async { self?.afterReceiverStatus(result) }
        }
    }

    private func afterReceiverStatus(_ result: Result<CastReceiverStatus, Error>) {
        switch result {
        case .failure(let error):
            fail(error)
        case .success(let status):
            log("receiver_status level=\(status.volumeLevel) apps=\(status.applications.count)")
            client?.launch(appID: options.appID) { [weak self] result in
                self?.queue.async { self?.afterLaunch(result) }
            }
        }
    }

    private func afterLaunch(_ result: Result<CastApplication, Error>) {
        switch result {
        case .failure(let error):
            fail(error)
        case .success(let app):
            log("launched app=\(app.appID) transportId=\(app.transportID) sessionId=\(app.sessionID)")
            application = app
            // Replaces CastClient's MEDIA_STATUS forwarding, which this run never needs.
            channel?.onUnsolicited = { [weak self] message, json in
                guard message.namespace == CastNamespace.webrtc else { return }
                self?.queue.async { self?.handleWebrtc(json) }
            }
            let timeout = DispatchWorkItem { [weak self] in
                self?.log("no_answer")
                self?.fail(CastError.timeout)
            }
            answerTimeout = timeout
            queue.asyncAfter(deadline: .now() + Self.answerDeadline, execute: timeout)
            channel?.send(namespace: CastNamespace.webrtc, destination: app.transportID,
                          payload: offer.message(seqNum: Self.offerSeqNum))
            log("offer_sent seq=\(Self.offerSeqNum) ssrc=\(offer.ssrc) payload_type=\(offer.rtpPayloadType)"
                + " target_delay_ms=\(offer.targetDelayMs)")
        }
    }

    private func handleWebrtc(_ json: [String: Any]) {
        guard !finished, answerTimeout != nil,
              (json["type"] as? String) == "ANSWER",
              (json["seqNum"] as? Int) == Self.offerSeqNum else { return }
        answerTimeout?.cancel()
        answerTimeout = nil
        let raw = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "?"
        log("answer_json=\(raw)")
        switch CastStreamingAnswer.parse(json) {
        case .failure(let error):
            if case .receiverError(_, let reason) = error { log("answer_error=\(reason ?? "nil")") }
            fail(error)
        case .success(let answer):
            guard let position = answer.sendIndexes.firstIndex(of: offer.index), position < answer.ssrcs.count else {
                fail(CastError.protocolViolation("ANSWER did not select the audio stream"))
                return
            }
            guard let host = channel?.remoteIPv4Address ?? Self.host(of: options.endpoint) else {
                fail(CastError.connectionFailed("no receiver IPv4 address"))
                return
            }
            startStreaming(host: host, answer: answer, receiverSSRC: answer.ssrcs[position])
        }
    }

    private func startStreaming(host: String, answer: CastStreamingAnswer, receiverSSRC: UInt32) {
        let session: CastStreamingSession
        do {
            session = try CastStreamingSession(
                host: host, udpPort: answer.udpPort, offer: offer, receiverSSRC: receiverSSRC,
                framesPerPacket: options.framesPerPacket, bitRate: options.bitRate,
                log: { [weak self] line in self?.queue.async { self?.log(line) } })
        } catch {
            fail(error)
            return
        }
        self.session = session
        session.start()
        log("streaming host=\(host) udp_port=\(answer.udpPort) receiver_ssrc=\(receiverSSRC)")

        let frameNanos = UInt64(options.framesPerPacket) * 1_000_000_000 / 48_000
        let generator = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        generator.schedule(deadline: .now(), repeating: .nanoseconds(Int(frameNanos)), leeway: .milliseconds(1))
        generator.setEventHandler { [weak self] in self?.generateDueFrames() }
        generator.resume()
        self.generator = generator

        let stats = DispatchSource.makeTimerSource(queue: queue)
        stats.schedule(deadline: .now() + Self.statsInterval, repeating: Self.statsInterval)
        stats.setEventHandler { [weak self] in self?.logStats() }
        stats.resume()
        statsTimer = stats

        queue.asyncAfter(deadline: .now() + options.holdSeconds) { [weak self] in self?.teardown() }
    }

    /// Every frame whose pts has come due, so a late tick catches up rather
    /// than letting the stream fall behind real time.
    private func generateDueFrames() {
        guard !finished, let session else { return }
        let now = CastNTP.monotonicNanos()
        let t0 = ptsLock.withLock { () -> UInt64 in
            if _firstFramePtsNanos == nil { _firstFramePtsNanos = now }
            return _firstFramePtsNanos!
        }
        let frames = options.framesPerPacket
        let period = max(1, Int((options.probePeriodSeconds * 48_000).rounded()))
        while true {
            let firstSample = nextFrame * frames
            let pts = t0 + UInt64(firstSample) * 1_000_000_000 / 48_000
            guard pts <= now else { return }
            var pcm = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                let sample = firstSample + i
                let position = sample % period
                if position == 0 {
                    let index = sample / period
                    let probePts = t0 + UInt64(sample) * 1_000_000_000 / 48_000
                    log("probe index=\(index) pts_ns=\(probePts)")
                    options.onProbe?(index, probePts)
                }
                guard position < options.probeSamples.count else { continue }
                let value = options.probeSamples[position] * options.probeAmplitude
                pcm[2 * i] = value
                pcm[2 * i + 1] = value
            }
            session.enqueue(pcm: pcm, pts: pts)
            nextFrame += 1
        }
    }

    private func logStats() {
        guard let stats = session?.stats else { return }
        log("mirror_stats frames=\(stats.framesSent) resent=\(stats.packetsResent)"
            + " rtt_ms=\(stats.lastRTTMs.map { String(format: "%.2f", $0) } ?? "nil")"
            + " playout_delay=\(stats.receiverPlayoutDelayMs.map(String.init) ?? "nil")"
            + " feedback_age_s=\(stats.lastFeedbackAgeSeconds.map { String(format: "%.2f", $0) } ?? "nil")")
    }

    private func teardown() {
        guard !finished else { return }
        generator?.cancel()
        generator = nil
        statsTimer?.cancel()
        statsTimer = nil
        logStats()
        let stats = session?.stats ?? CastStreamingSession.Stats()
        session?.stop()
        guard let app = application else { fail(CastError.protocolViolation("no application to stop")); return }
        client?.stopApplication(sessionID: app.sessionID) { [weak self] result in
            self?.queue.async {
                guard let self else { return }
                if case .failure(let error) = result { self.fail(error); return }
                self.channel?.close()
                self.log("done")
                self.finish(.success(stats))
            }
        }
    }

    // MARK: - Helpers

    private static func host(of endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        if case let .ipv4(address) = host { return "\(address)" }
        return "\(host)"
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        log("error=\(error)")
        answerTimeout?.cancel()
        answerTimeout = nil
        generator?.cancel()
        generator = nil
        statsTimer?.cancel()
        statsTimer = nil
        session?.stop()
        channel?.close()
        finish(.failure(error))
    }

    private func finish(_ result: Result<CastStreamingSession.Stats, Error>) {
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
}
