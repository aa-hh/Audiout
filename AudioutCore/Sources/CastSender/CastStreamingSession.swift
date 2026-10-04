// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation
import Network

/// One Cast Streaming audio stream to one receiver: Opus frames in RTP out,
/// Sender Reports every 500 ms, receiver feedback in, NACKed packets resent.
/// RTP and RTCP share one UDP socket to the ANSWER's port.
///
/// Every frame's pts is `CLOCK_MONOTONIC` nanoseconds. The Sender Report maps
/// "sender monotonic time now" to an RTP sample position, so the receiver
/// plays each frame at `pts + targetDelay + c`, where `c` is whatever the
/// receiver adds on top.
///
/// Everything mutable is confined to ``queue``.
public final class CastStreamingSession: @unchecked Sendable {

    public struct Stats: Equatable {
        public var framesSent = 0
        public var packetsResent = 0
        public var lastRTTMs: Double?
        public var lastFeedbackAgeSeconds: Double?
        public var receiverPlayoutDelayMs: Int?
    }

    private static let maxUnackedFrames = 120
    private static let maxPayload = 1_454
    private static let reportInterval: TimeInterval = 0.5
    private static let silenceLimitNanos: UInt64 = 15_000_000_000

    private let host: String
    private let udpPort: UInt16
    private let offer: CastStreamingOffer
    private let receiverSSRC: UInt32
    private let framesPerPacket: Int
    private let encoder: CastOpusEncoder
    private let logSink: (String) -> Void
    private let queue = DispatchQueue(label: "CastStreamingSession")

    private let statsLock = NSLock()
    private var _stats = Stats()
    private var lastFeedbackNanos: UInt64?

    /// One sent frame, kept until the receiver's checkpoint or an ACK frees it.
    private struct Slot {
        var frameID: Int
        var rtpTimestamp: UInt32
        var encrypted: Data
        var lastSendNanos: UInt64
    }

    // Queue-confined below this line.
    private var connection: NWConnection?
    private var origin = CastNTP.Origin.now()
    private var reportTimer: DispatchSourceTimer?
    private var slots = [Slot?](repeating: nil, count: CastStreamingSession.maxUnackedFrames)
    private var nextFrameID = 0
    private var checkpoint = -1
    private var sequence = UInt16.random(in: 0...UInt16.max)
    private var lastFrame: (rtp: UInt32, pts: UInt64)?
    private var packetCount: UInt32 = 0
    private var octetCount: UInt32 = 0
    /// Recent Sender Reports by id, so a report block's round trip can be timed.
    private var reportSendTimes: [(id: UInt32, nanos: UInt64)] = []
    private var rttNanos: UInt64 = 0
    private var lastFeedbackLogNanos: UInt64 = 0
    private var startedNanos: UInt64 = 0
    private var silenceLogged = false
    private var stopped = false

    public init(
        host: String,
        udpPort: UInt16,
        offer: CastStreamingOffer,
        receiverSSRC: UInt32,
        framesPerPacket: Int,
        bitRate: Int,
        log: @escaping (String) -> Void
    ) throws {
        self.host = host
        self.udpPort = udpPort
        self.offer = offer
        self.receiverSSRC = receiverSSRC
        self.framesPerPacket = framesPerPacket
        self.encoder = try CastOpusEncoder(framesPerPacket: framesPerPacket, bitRate: bitRate)
        self.logSink = log
    }

    public var stats: Stats {
        let now = CastNTP.monotonicNanos()
        return statsLock.withLock {
            var stats = _stats
            stats.lastFeedbackAgeSeconds = lastFeedbackNanos.map { Double(now &- $0) / 1e9 }
            return stats
        }
    }

    public func start() {
        queue.async { [self] in
            origin = .now()
            startedNanos = origin.monotonicNanos
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: udpPort) ?? .any,
                using: .udp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.logSink("udp_failed error=\(error)") }
            }
            connection.start(queue: queue)
            receive(on: connection)

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.reportInterval, repeating: Self.reportInterval)
            timer.setEventHandler { [weak self] in self?.onReportTimer() }
            timer.resume()
            reportTimer = timer
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            reportTimer?.cancel()
            reportTimer = nil
            connection?.cancel()
            connection = nil
        }
    }

    /// `pcm` is exactly one frame of interleaved stereo; `pts` is when its
    /// first sample was captured, on `CLOCK_MONOTONIC`.
    public func enqueue(pcm: [Float], pts monotonicNanos: UInt64) {
        queue.async { [self] in
            guard !stopped, connection != nil else { return }
            let frameID = nextFrameID
            guard frameID - checkpoint <= Self.maxUnackedFrames else {
                logSink("span_limit frame=\(frameID) checkpoint=\(checkpoint)")
                return
            }
            guard let opus = encoder.encode(pcm) else { return }
            guard opus.count <= Self.maxPayload else {
                logSink("payload_too_large frame=\(frameID) bytes=\(opus.count)")
                return
            }
            nextFrameID += 1
            let rtp = UInt32(truncatingIfNeeded: frameID * framesPerPacket)
            let isFirst = lastFrame == nil
            lastFrame = (rtp, monotonicNanos)
            // A receiver drops packet 0 of every frame until it has one Sender
            // Report, so the very first one goes out ahead of any RTP.
            if isFirst { sendSenderReport() }
            let now = CastNTP.monotonicNanos()
            let slot = Slot(frameID: frameID, rtpTimestamp: rtp,
                            encrypted: offer.crypto.crypt(frameID: UInt32(truncatingIfNeeded: frameID), opus),
                            lastSendNanos: now)
            slots[frameID % Self.maxUnackedFrames] = slot
            send(slot)
            statsLock.withLock { _stats.framesSent += 1 }
        }
    }

    // MARK: - Sending (queue-confined)

    private func send(_ slot: Slot) {
        let packet = CastRTPPacket.encode(
            payloadType: offer.rtpPayloadType, sequence: sequence, rtpTimestamp: slot.rtpTimestamp,
            ssrc: offer.ssrc, frameID: UInt8(truncatingIfNeeded: slot.frameID),
            packetID: 0, maxPacketID: 0, referencedFrameID: UInt8(truncatingIfNeeded: slot.frameID),
            payload: slot.encrypted)
        sequence &+= 1
        packetCount &+= 1
        octetCount &+= UInt32(slot.encrypted.count)
        connection?.send(content: packet, completion: .idempotent)
    }

    /// The RTP position is the last frame's, advanced by the time since that
    /// frame's pts: the mapping the receiver schedules every frame by.
    private func sendSenderReport() {
        guard let lastFrame else { return }
        let now = CastNTP.monotonicNanos()
        let ntp = CastNTP.timestamp(monotonicNanos: now, origin: origin)
        let ticks = (Int64(bitPattern: now) - Int64(bitPattern: lastFrame.pts)) * 48_000 / 1_000_000_000
        let rtp = UInt32(truncatingIfNeeded: Int64(lastFrame.rtp) + ticks)
        reportSendTimes.append((CastNTP.reportID(ntp), now))
        if reportSendTimes.count > 32 { reportSendTimes.removeFirst() }
        connection?.send(
            content: CastSenderReport.encode(ssrc: offer.ssrc, ntp: ntp, rtpTimestamp: rtp,
                                             packetCount: packetCount, octetCount: octetCount),
            completion: .idempotent)
    }

    private func onReportTimer() {
        guard !stopped else { return }
        sendSenderReport()
        let now = CastNTP.monotonicNanos()
        let heard = statsLock.withLock { lastFeedbackNanos } ?? startedNanos
        if !silenceLogged, now &- heard > Self.silenceLimitNanos {
            silenceLogged = true
            logSink("receiver_silent seconds=\(Double(now &- heard) / 1e9)")
        }
    }

    // MARK: - Feedback (queue-confined)

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty, !CastStreamingRTP.isRTP(data) { self.handleFeedback(data) }
            if error == nil { self.receive(on: connection) }
        }
    }

    private func handleFeedback(_ data: Data) {
        let arrival = CastNTP.monotonicNanos()
        guard let feedback = CastReceiverFeedback.parse(
            data, senderSSRC: offer.ssrc, receiverSSRC: receiverSSRC, maxFrameID: nextFrameID - 1) else { return }
        statsLock.withLock { lastFeedbackNanos = arrival }

        if let block = feedback.reportBlock,
           let sent = reportSendTimes.last(where: { $0.id == block.lastSenderReportID }) {
            let total = Int64(arrival &- sent.nanos)
            let held = Int64(block.delaySinceLastReport) * 1_000_000_000 / 65_536
            rttNanos = UInt64(max(total - held, 75_000))
            statsLock.withLock { _stats.lastRTTMs = Double(rttNanos) / 1e6 }
        }
        if let delay = feedback.playoutDelayMs {
            statsLock.withLock { _stats.receiverPlayoutDelayMs = Int(delay) }
        }
        if let newCheckpoint = feedback.checkpointFrameID, newCheckpoint > checkpoint {
            // Only the last `maxUnackedFrames` ids can still hold a slot.
            for id in max(checkpoint + 1, newCheckpoint - Self.maxUnackedFrames + 1)...newCheckpoint { free(id) }
            checkpoint = newCheckpoint
        }
        for id in feedback.acks { free(id) }

        var resent = 0
        for nack in feedback.nacks where nack.packetID == 0 || nack.packetID == CastReceiverFeedback.Nack.allPackets {
            let index = nack.frameID % Self.maxUnackedFrames
            guard nack.frameID > checkpoint, nack.frameID >= 0,
                  var slot = slots[index], slot.frameID == nack.frameID,
                  slot.lastSendNanos < arrival &- min(rttNanos, arrival) else { continue }
            slot.lastSendNanos = arrival
            slots[index] = slot
            send(slot)
            resent += 1
        }
        if resent > 0 { statsLock.withLock { _stats.packetsResent += resent } }

        if resent > 0 || arrival &- lastFeedbackLogNanos >= 1_000_000_000 {
            lastFeedbackLogNanos = arrival
            logSink("feedback checkpoint=\(feedback.checkpointFrameID.map(String.init) ?? "nil")"
                + " playout_delay=\(feedback.playoutDelayMs.map(String.init) ?? "nil")"
                + String(format: " rtt_ms=%.2f", Double(rttNanos) / 1e6)
                + " nacks=\(feedback.nacks.count)" + (resent > 0 ? " resent=\(resent)" : ""))
        }
    }

    private func free(_ frameID: Int) {
        guard frameID >= 0 else { return }
        let index = frameID % Self.maxUnackedFrames
        if slots[index]?.frameID == frameID { slots[index] = nil }
    }
}
