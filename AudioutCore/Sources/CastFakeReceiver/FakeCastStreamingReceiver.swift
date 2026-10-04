// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import CastSender
import Foundation
import Network

/// A Cast Streaming (mirroring) receiver, faked on loopback UDP: answers the
/// OFFER, reassembles and decrypts frames, sends feedback, and estimates when
/// each frame would play. No decoding, no playback.
///
/// The listener binds 127.0.0.1 only, for the same firewall reason as
/// ``FakeCastReceiver``. Callbacks are weak; the owner stops it.
@available(macOS 15, *)
public final class FakeCastStreamingReceiver: @unchecked Sendable {

    public struct Frame: Equatable {
        public var frameID: Int
        public var rtpTimestamp: UInt32
        public var arrivalNanos: UInt64
        public var estimatedPlayoutNanos: UInt64
        public var bytes: Data
    }

    /// Set before `start`: every Nth RTP packet is discarded, each one once,
    /// so the sender's NACK handling is exercised.
    public var dropEveryNthPacket: Int?

    private static let feedbackInterval: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "FakeCastStreamingReceiver")
    private let stateLock = NSLock()
    private var _port: UInt16 = 0
    private var _stream: Stream?
    private var _frames: [Frame] = []
    private var _senderReports: [CastSenderReport] = []
    private var _droppedBeforeFirstSR = 0
    private var _retransmitsSeen = 0
    private var _checkpoint = -1

    /// What the OFFER asked for, read by the datagram path.
    private struct Stream {
        var senderSSRC: UInt32
        var receiverSSRC: UInt32
        var crypto: CastFrameCrypto
        var targetDelayMs: Int
    }

    /// Packets of one frame as they arrive.
    private struct Assembly {
        var rtpTimestamp: UInt32
        var chunks: [Data?]
    }

    // Queue-confined below this line.
    private var listener: NWListener?
    private var peer: NWConnection?
    private var timer: DispatchSourceTimer?
    private var origin = CastNTP.Origin.now()
    private var lastSR: (report: CastSenderReport, arrivalNanos: UInt64)?
    private var assemblies: [Int: Assembly] = [:]
    private var complete: Set<Int> = []
    private var highestFrame = -1
    private var highestSequence: UInt32 = 0
    private var rtpPacketsSeen = 0
    private var dropped: Set<[Int]> = []
    private var feedbackCount: UInt8 = 0

    public init() {}

    public var frames: [Frame] { stateLock.withLock { _frames } }
    public var senderReports: [CastSenderReport] { stateLock.withLock { _senderReports } }
    public var droppedBeforeFirstSR: Int { stateLock.withLock { _droppedBeforeFirstSR } }
    public var retransmitsSeen: Int { stateLock.withLock { _retransmitsSeen } }
    /// Highest frame id below which every frame arrived complete.
    public var checkpointFrameID: Int { stateLock.withLock { _checkpoint } }

    public func start(completion: @escaping (Result<UInt16, Error>) -> Void) {
        queue.async { [self] in
            let listener: NWListener
            do {
                let params = NWParameters.udp
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
                listener = try NWListener(using: params)
            } catch {
                completion(.failure(error))
                return
            }
            var reported = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !reported else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue, port != 0 else { return }
                    reported = true
                    self?.stateLock.withLock { self?._port = port }
                    completion(.success(port))
                case .failed(let error):
                    reported = true
                    completion(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.feedbackInterval, repeating: Self.feedbackInterval)
            timer.setEventHandler { [weak self] in self?.sendFeedback() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            listener?.cancel()
            listener = nil
            peer?.cancel()
            peer = nil
        }
    }

    /// The ANSWER for an OFFER: the first `audio_source` stream, at this
    /// listener's port, reported back with receiver SSRC = sender SSRC + 1.
    public func answer(for offerJSON: [String: Any]) -> [String: Any] {
        let seqNum = offerJSON["seqNum"] as? Int ?? 0
        let streams = ((offerJSON["offer"] as? [String: Any])?["supportedStreams"] as? [[String: Any]]) ?? []
        guard let audio = streams.first(where: { ($0["type"] as? String) == "audio_source" }),
              let index = audio["index"] as? Int,
              let ssrc = audio["ssrc"] as? Int,
              let crypto = CastFrameCrypto(hexKey: audio["aesKey"] as? String ?? "",
                                           hexIVMask: audio["aesIvMask"] as? String ?? "") else {
            return ["type": "ANSWER", "seqNum": seqNum, "result": "error",
                    "error": ["code": 0, "description": "no audio_source stream"]]
        }
        let senderSSRC = UInt32(truncatingIfNeeded: ssrc)
        let stream = Stream(senderSSRC: senderSSRC, receiverSSRC: senderSSRC &+ 1, crypto: crypto,
                            targetDelayMs: audio["targetDelay"] as? Int ?? 400)
        let port = stateLock.withLock { () -> UInt16 in
            _stream = stream
            return _port
        }
        return ["type": "ANSWER", "seqNum": seqNum, "result": "ok",
                "answer": ["udpPort": Int(port), "sendIndexes": [index], "ssrcs": [Int(stream.receiverSSRC)]] as [String: Any]]
    }

    // MARK: - Datagrams (queue-confined)

    private func accept(_ connection: NWConnection) {
        guard peer == nil else { connection.cancel(); return }
        peer = connection
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, connection === self.peer else { return }
            if let data, !data.isEmpty { self.handle(data) }
            if error == nil { self.receive(on: connection) }
        }
    }

    private func handle(_ data: Data) {
        guard let stream = stateLock.withLock({ _stream }) else { return }
        let arrival = CastNTP.monotonicNanos()
        if CastStreamingRTP.isRTP(data) {
            guard let packet = CastRTPPacket.decode(data), packet.ssrc == stream.senderSSRC else { return }
            handle(packet, stream: stream, arrival: arrival)
        } else if let report = CastSenderReport.decode(data), report.ssrc == stream.senderSSRC {
            lastSR = (report, arrival)
            stateLock.withLock { _senderReports.append(report) }
            sendFeedback()
        }
    }

    private func handle(_ packet: CastRTPPacket, stream: Stream, arrival: UInt64) {
        let frameID = highestFrame < 0
            ? Int(packet.frameID)
            : CastStreamingRTP.expand(packet.frameID, above: highestFrame - 128)
        let key = [frameID, Int(packet.packetID)]
        rtpPacketsSeen += 1
        let alreadyFilled = complete.contains(frameID) || frameID <= checkpointLocked()
            || assemblies[frameID]?.chunks[Int(packet.packetID)] != nil
        if alreadyFilled || dropped.contains(key) {
            stateLock.withLock { _retransmitsSeen += 1 }
        }
        if let n = dropEveryNthPacket, n > 0, rtpPacketsSeen % n == 0, !dropped.contains(key) {
            dropped.insert(key)
            highestFrame = max(highestFrame, frameID)
            return
        }
        if packet.packetID == 0, lastSR == nil {
            stateLock.withLock { _droppedBeforeFirstSR += 1 }
            return
        }
        highestFrame = max(highestFrame, frameID)
        // razor: not extended across the 16-bit wrap; nothing here reads it back.
        highestSequence = max(highestSequence, UInt32(packet.sequence))
        guard !alreadyFilled else { return }

        var assembly = assemblies[frameID]
            ?? Assembly(rtpTimestamp: packet.rtpTimestamp, chunks: Array(repeating: nil, count: Int(packet.maxPacketID) + 1))
        guard Int(packet.packetID) < assembly.chunks.count else { return }
        assembly.chunks[Int(packet.packetID)] = packet.payload
        guard assembly.chunks.allSatisfy({ $0 != nil }) else {
            assemblies[frameID] = assembly
            return
        }
        assemblies[frameID] = nil
        complete.insert(frameID)
        let encrypted = assembly.chunks.reduce(into: Data()) { $0.append($1!) }
        let plain = stream.crypto.crypt(frameID: UInt32(truncatingIfNeeded: frameID), encrypted)
        // openscreen's rule with the clock offset taken raw from the last
        // Sender Report (arrival − its reference time), not smoothed.
        let sr = lastSR!
        let ticks = Int64(Int32(bitPattern: assembly.rtpTimestamp &- sr.report.rtpTimestamp))
        let playout = Int64(sr.arrivalNanos) + ticks * 1_000_000_000 / 48_000 + Int64(stream.targetDelayMs) * 1_000_000
        stateLock.withLock {
            _frames.append(Frame(frameID: frameID, rtpTimestamp: assembly.rtpTimestamp, arrivalNanos: arrival,
                                 estimatedPlayoutNanos: UInt64(max(playout, 0)), bytes: plain))
        }
        advanceCheckpoint()
    }

    private func checkpointLocked() -> Int { stateLock.withLock { _checkpoint } }

    private func advanceCheckpoint() {
        var checkpoint = checkpointLocked()
        while complete.remove(checkpoint + 1) != nil { checkpoint += 1 }
        stateLock.withLock { _checkpoint = checkpoint }
    }

    /// Report block for the last SR, reference time, checkpoint, NACKs for
    /// what is missing above it, ACKs for complete frames past checkpoint + 1.
    private func sendFeedback() {
        guard let peer, let stream = stateLock.withLock({ _stream }) else { return }
        let now = CastNTP.monotonicNanos()
        let checkpoint = checkpointLocked()
        var feedback = CastReceiverFeedback(
            receiverReferenceNTP: CastNTP.timestamp(monotonicNanos: now, origin: origin),
            checkpointFrameID: checkpoint,
            playoutDelayMs: UInt16(clamping: stream.targetDelayMs))
        if let sr = lastSR {
            feedback.reportBlock = .init(
                lastSenderReportID: CastNTP.reportID(sr.report.ntp),
                delaySinceLastReport: UInt32(clamping: (now &- sr.arrivalNanos) * 65_536 / 1_000_000_000),
                extendedHighestSequence: highestSequence, cumulativeLost: 0)
        }
        if highestFrame > checkpoint {
            for id in (checkpoint + 1)...highestFrame where !complete.contains(id) {
                if let assembly = assemblies[id] {
                    for (packetID, chunk) in assembly.chunks.enumerated() where chunk == nil {
                        feedback.nacks.append(.init(frameID: id, packetID: UInt16(packetID)))
                    }
                } else {
                    feedback.nacks.append(.init(frameID: id, packetID: CastReceiverFeedback.Nack.allPackets))
                }
            }
            feedback.acks = complete.filter { $0 > checkpoint + 1 }.sorted()
        }
        peer.send(content: feedback.encode(senderSSRC: stream.senderSSRC, receiverSSRC: stream.receiverSSRC,
                                           feedbackCount: feedbackCount),
                  completion: .idempotent)
        feedbackCount &+= 1
    }
}
