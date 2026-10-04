// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation

/// Cast Streaming's RTP and RTCP byte layouts. Pure: no sockets, no clocks
/// beyond ``CastNTP/monotonicNanos()``. Everything is big-endian.
public enum CastStreamingRTP {

    /// Payload types a Cast receiver accepts: the audio and video ranges plus
    /// 127, the Android TV value openscreen sends for every audio stream.
    static func isPayloadType(_ value: UInt8) -> Bool {
        (96...104).contains(value) || value == 127
    }

    /// RTP when the first byte is `0x80`, the packet is at least the minimum
    /// Cast header, and the 7-bit payload type is one Cast uses; anything else
    /// on the shared socket is treated as RTCP.
    public static func isRTP(_ data: Data) -> Bool {
        guard data.count >= 18 else { return false }
        let bytes = [UInt8](data.prefix(2))
        return bytes[0] == 0x80 && isPayloadType(bytes[1] & 0x7F)
    }

    /// The largest frame id ≤ `max` whose low 8 bits are `low`.
    public static func expand(_ low: UInt8, atMost max: Int) -> Int {
        max - Int(UInt8(truncatingIfNeeded: max) &- low)
    }

    /// The smallest frame id > `base` whose low 8 bits are `low`.
    public static func expand(_ low: UInt8, above base: Int) -> Int {
        base + 1 + Int(low &- UInt8(truncatingIfNeeded: base + 1))
    }
}

// MARK: - RTP

/// One Cast RTP packet. Every audio frame is a key frame that references
/// itself, so the "has reference frame id" bit is always set on encode.
public struct CastRTPPacket: Equatable {
    public var payloadType: UInt8
    public var marker: Bool
    public var sequence: UInt16
    public var rtpTimestamp: UInt32
    public var ssrc: UInt32
    public var keyFrame: Bool
    public var frameID: UInt8
    public var packetID: UInt16
    public var maxPacketID: UInt16
    public var referencedFrameID: UInt8
    public var newPlayoutDelayMs: UInt16?
    public var payload: Data

    public static func encode(
        payloadType: UInt8,
        sequence: UInt16,
        rtpTimestamp: UInt32,
        ssrc: UInt32,
        frameID: UInt8,
        packetID: UInt16,
        maxPacketID: UInt16,
        referencedFrameID: UInt8,
        keyFrame: Bool = true,
        newPlayoutDelayMs: UInt16? = nil,
        payload: Data
    ) -> Data {
        var out = Data(capacity: 23 + payload.count)
        out.append(0x80)
        out.append((packetID == maxPacketID ? 0x80 : 0) | (payloadType & 0x7F))
        out.appendBE(sequence)
        out.appendBE(rtpTimestamp)
        out.appendBE(ssrc)
        out.append((keyFrame ? 0x80 : 0) | 0x40 | (newPlayoutDelayMs == nil ? 0 : 1))
        out.append(frameID)
        out.appendBE(packetID)
        out.appendBE(maxPacketID)
        out.append(referencedFrameID)
        if let delay = newPlayoutDelayMs {
            out.appendBE(UInt16(1 << 10 | 2))
            out.appendBE(delay)
        }
        out.append(payload)
        return out
    }

    public static func decode(_ data: Data) -> CastRTPPacket? {
        var reader = ByteReader(data)
        guard data.count >= 18,
              let first = reader.u8(), first == 0x80,
              let second = reader.u8(), CastStreamingRTP.isPayloadType(second & 0x7F),
              let sequence = reader.u16(), let timestamp = reader.u32(), let ssrc = reader.u32(),
              let flags = reader.u8(), let frameID = reader.u8(),
              let packetID = reader.u16(), let maxPacketID = reader.u16(),
              maxPacketID != 0xFFFF, packetID <= maxPacketID else { return nil }
        var referenced = frameID
        if flags & 0x40 != 0 {
            guard let value = reader.u8() else { return nil }
            referenced = value
        }
        var playoutDelay: UInt16?
        for _ in 0..<Int(flags & 0x3F) {
            guard let typeAndSize = reader.u16() else { return nil }
            let size = Int(typeAndSize & 0x3FF)
            guard let body = reader.bytes(size) else { return nil }
            if typeAndSize >> 10 == 1, size == 2 { playoutDelay = UInt16(body[0]) << 8 | UInt16(body[1]) }
        }
        return CastRTPPacket(
            payloadType: second & 0x7F, marker: second & 0x80 != 0, sequence: sequence,
            rtpTimestamp: timestamp, ssrc: ssrc, keyFrame: flags & 0x80 != 0, frameID: frameID,
            packetID: packetID, maxPacketID: maxPacketID, referencedFrameID: referenced,
            newPlayoutDelayMs: playoutDelay, payload: reader.rest())
    }
}

// MARK: - Sender Report

/// RTCP Sender Report with no report blocks: 4-byte header plus 24 bytes.
public struct CastSenderReport: Equatable {
    public var ssrc: UInt32
    public var ntp: UInt64
    public var rtpTimestamp: UInt32
    public var packetCount: UInt32
    public var octetCount: UInt32

    public static func encode(ssrc: UInt32, ntp: UInt64, rtpTimestamp: UInt32, packetCount: UInt32, octetCount: UInt32) -> Data {
        var out = Data(capacity: 28)
        out.append(0x80)
        out.append(200)
        out.appendBE(UInt16(6))
        out.appendBE(ssrc)
        out.appendBE(ntp)
        out.appendBE(rtpTimestamp)
        out.appendBE(packetCount)
        out.appendBE(octetCount)
        return out
    }

    public static func decode(_ data: Data) -> CastSenderReport? {
        var reader = ByteReader(data)
        guard let first = reader.u8(), first & 0xE0 == 0x80,
              let type = reader.u8(), type == 200,
              let words = reader.u16(), words >= 6,
              let ssrc = reader.u32(), let ntp = reader.u64(), let rtp = reader.u32(),
              let packets = reader.u32(), let octets = reader.u32() else { return nil }
        return CastSenderReport(ssrc: ssrc, ntp: ntp, rtpTimestamp: rtp, packetCount: packets, octetCount: octets)
    }
}

// MARK: - NTP

/// NTP timestamps on the sender's monotonic clock: whole seconds since 1900
/// in the high 32 bits, 2^-32 fractions in the low 32. Only forward ticking
/// matters to the receiver; a constant offset from true wall time is fine.
public enum CastNTP {

    public struct Origin: Equatable, Sendable {
        public var monotonicNanos: UInt64
        public var unixSeconds: UInt64

        public init(monotonicNanos: UInt64, unixSeconds: UInt64) {
            self.monotonicNanos = monotonicNanos
            self.unixSeconds = unixSeconds
        }

        /// Both clocks, read once at session start.
        public static func now() -> Origin {
            Origin(monotonicNanos: CastNTP.monotonicNanos(), unixSeconds: UInt64(time(nil)))
        }
    }

    /// `clock_gettime(CLOCK_MONOTONIC)` in nanoseconds — the clock capture pts
    /// ride on, so every timestamp in a session is on one timeline.
    public static func monotonicNanos() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    public static func timestamp(monotonicNanos: UInt64, origin: Origin) -> UInt64 {
        let elapsed = monotonicNanos >= origin.monotonicNanos ? monotonicNanos - origin.monotonicNanos : 0
        let seconds = origin.unixSeconds + 2_208_988_800 + elapsed / 1_000_000_000
        let fraction = (elapsed % 1_000_000_000) << 32 / 1_000_000_000
        return seconds << 32 | fraction
    }

    /// The middle 32 bits: how a Receiver Report names the Sender Report it answers.
    public static func reportID(_ ntp: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: ntp >> 16)
    }
}

// MARK: - Receiver feedback

/// What a receiver's compound RTCP packet says to the sender: Receiver Report
/// block, reference time, Cast feedback (checkpoint, NACKs, ACKs), picture loss.
public struct CastReceiverFeedback: Equatable {

    public struct ReportBlock: Equatable {
        public var lastSenderReportID: UInt32
        /// In 1/65536 s.
        public var delaySinceLastReport: UInt32
        public var extendedHighestSequence: UInt32
        public var cumulativeLost: UInt32

        public init(lastSenderReportID: UInt32, delaySinceLastReport: UInt32, extendedHighestSequence: UInt32, cumulativeLost: UInt32) {
            self.lastSenderReportID = lastSenderReportID
            self.delaySinceLastReport = delaySinceLastReport
            self.extendedHighestSequence = extendedHighestSequence
            self.cumulativeLost = cumulativeLost
        }
    }

    public struct Nack: Equatable {
        public var frameID: Int
        /// `allPackets` means the whole frame.
        public var packetID: UInt16

        public static let allPackets: UInt16 = 0xFFFF

        public init(frameID: Int, packetID: UInt16) {
            self.frameID = frameID
            self.packetID = packetID
        }
    }

    public var reportBlock: ReportBlock?
    public var receiverReferenceNTP: UInt64?
    /// Every frame at or below this one has been received. -1 before any.
    public var checkpointFrameID: Int?
    public var playoutDelayMs: UInt16?
    public var nacks: [Nack]
    public var acks: [Int]
    public var pictureLoss: Bool

    public init(
        reportBlock: ReportBlock? = nil,
        receiverReferenceNTP: UInt64? = nil,
        checkpointFrameID: Int? = nil,
        playoutDelayMs: UInt16? = nil,
        nacks: [Nack] = [],
        acks: [Int] = [],
        pictureLoss: Bool = false
    ) {
        self.reportBlock = reportBlock
        self.receiverReferenceNTP = receiverReferenceNTP
        self.checkpointFrameID = checkpointFrameID
        self.playoutDelayMs = playoutDelayMs
        self.nacks = nacks
        self.acks = acks
        self.pictureLoss = pictureLoss
    }

    private static let castWord: UInt32 = 0x4341_5354  // 'CAST'
    private static let cst2Word: UInt32 = 0x4353_5432  // 'CST2'

    /// Walks a compound packet. `maxFrameID` is the newest frame the sender
    /// has enqueued: the 8-bit checkpoint expands to the largest id ≤ it.
    /// Unknown packet types (application-defined `'TIME'`, receiver logs) are
    /// skipped; nil means the packet was malformed.
    public static func parse(_ data: Data, senderSSRC: UInt32, receiverSSRC: UInt32, maxFrameID: Int) -> CastReceiverFeedback? {
        var feedback = CastReceiverFeedback()
        var reader = ByteReader(data)
        while !reader.isAtEnd {
            guard let first = reader.u8(), first & 0xE0 == 0x80,
                  let type = reader.u8(), let words = reader.u16(),
                  let body = reader.bytes(Int(words) * 4) else { return nil }
            let countOrSubtype = first & 0x1F
            var packet = ByteReader(body)
            switch type {
            case 201:
                guard let ssrc = packet.u32() else { return nil }
                guard ssrc == receiverSSRC else { continue }
                for _ in 0..<Int(countOrSubtype) {
                    guard let to = packet.u32(), let lost = packet.u32(), let highest = packet.u32(),
                          packet.u32() != nil, let lastSR = packet.u32(), let delay = packet.u32() else { return nil }
                    if to == senderSSRC {
                        feedback.reportBlock = ReportBlock(
                            lastSenderReportID: lastSR, delaySinceLastReport: delay,
                            extendedHighestSequence: highest, cumulativeLost: lost & 0x00FF_FFFF)
                    }
                }
            case 207:
                guard let ssrc = packet.u32() else { return nil }
                guard ssrc == receiverSSRC else { continue }
                while !packet.isAtEnd {
                    guard let blockType = packet.u8(), packet.u8() != nil, let blockWords = packet.u16(),
                          let block = packet.bytes(Int(blockWords) * 4) else { return nil }
                    if blockType == 4, blockWords == 2 {
                        var ntp = ByteReader(block)
                        feedback.receiverReferenceNTP = ntp.u64()
                    }
                }
            case 206 where countOrSubtype == 1:
                guard let from = packet.u32(), let to = packet.u32() else { return nil }
                if from == receiverSSRC, to == senderSSRC { feedback.pictureLoss = true }
            case 206 where countOrSubtype == 15:
                guard let from = packet.u32(), let to = packet.u32() else { return nil }
                guard from == receiverSSRC, to == senderSSRC else { continue }
                guard let word = packet.u32(), word == castWord,
                      let checkpointLow = packet.u8(), let lossCount = packet.u8(),
                      let delay = packet.u16() else { return nil }
                let checkpoint = CastStreamingRTP.expand(checkpointLow, atMost: maxFrameID)
                feedback.checkpointFrameID = checkpoint
                feedback.playoutDelayMs = delay
                for _ in 0..<Int(lossCount) {
                    guard let frameLow = packet.u8(), var packetID = packet.u16(), var bits = packet.u8() else { return nil }
                    let frameID = CastStreamingRTP.expand(frameLow, above: checkpoint)
                    feedback.nacks.append(Nack(frameID: frameID, packetID: packetID))
                    guard packetID != Nack.allPackets else { continue }
                    while bits != 0 {
                        packetID &+= 1
                        if bits & 1 != 0 { feedback.nacks.append(Nack(frameID: frameID, packetID: packetID)) }
                        bits >>= 1
                    }
                }
                guard let word2 = packet.u32(), word2 == cst2Word, packet.u8() != nil,
                      let octets = packet.u8() else { continue }
                guard let vector = packet.bytes(Int(octets)) else { return nil }
                for (index, octet) in vector.enumerated() {
                    for bit in 0..<8 where octet & (1 << bit) != 0 {
                        feedback.acks.append(checkpoint + 2 + index * 8 + bit)
                    }
                }
            default:
                continue
            }
        }
        return feedback
    }

    /// The receiver → sender compound packet: Receiver Report (with the block
    /// when there is one), reference-time Extended Report, Picture Loss when
    /// set, then Cast feedback when there is a checkpoint. Only the fake
    /// receiver builds these; the sender never does.
    public func encode(senderSSRC: UInt32, receiverSSRC: UInt32, feedbackCount: UInt8) -> Data {
        var out = Data()
        out.append(0x80 | (reportBlock == nil ? 0 : 1))
        out.append(201)
        out.appendBE(UInt16(reportBlock == nil ? 1 : 7))
        out.appendBE(receiverSSRC)
        if let block = reportBlock {
            out.appendBE(senderSSRC)
            out.appendBE(block.cumulativeLost & 0x00FF_FFFF)
            out.appendBE(block.extendedHighestSequence)
            out.appendBE(UInt32(0))
            out.appendBE(block.lastSenderReportID)
            out.appendBE(block.delaySinceLastReport)
        }
        if let ntp = receiverReferenceNTP {
            out.append(0x80)
            out.append(207)
            out.appendBE(UInt16(4))
            out.appendBE(receiverSSRC)
            out.append(4)
            out.append(0)
            out.appendBE(UInt16(2))
            out.appendBE(ntp)
        }
        if pictureLoss {
            out.append(0x80 | 1)
            out.append(206)
            out.appendBE(UInt16(2))
            out.appendBE(receiverSSRC)
            out.appendBE(senderSSRC)
        }
        guard let checkpoint = checkpointFrameID else { return out }

        var body = Data()
        body.appendBE(receiverSSRC)
        body.appendBE(senderSSRC)
        body.appendBE(Self.castWord)
        body.append(UInt8(truncatingIfNeeded: checkpoint))
        var lossFields = Data()
        var lossCount: UInt8 = 0
        let sorted = nacks.filter { $0.frameID > checkpoint }
            .sorted { ($0.frameID, $0.packetID) < ($1.frameID, $1.packetID) }
        var index = 0
        while index < sorted.count, lossCount < 255 {
            let head = sorted[index]
            var bits: UInt8 = 0
            index += 1
            while index < sorted.count, sorted[index].frameID == head.frameID {
                let shift = Int(sorted[index].packetID) - Int(head.packetID) - 1
                if shift >= 8 { break }
                bits |= 1 << shift
                index += 1
            }
            lossFields.append(UInt8(truncatingIfNeeded: head.frameID))
            lossFields.appendBE(head.packetID)
            lossFields.append(bits)
            lossCount += 1
        }
        body.append(lossCount)
        body.appendBE(playoutDelayMs ?? 0)
        body.append(lossFields)
        body.appendBE(Self.cst2Word)
        body.append(feedbackCount)
        var vector = [UInt8](repeating: 0, count: 2)
        for ack in acks.sorted() {
            let bit = ack - (checkpoint + 2)
            guard bit >= 0 else { continue }
            while bit / 8 >= vector.count {
                guard vector.count + 4 <= 254 else { break }
                vector += [0, 0, 0, 0]
            }
            guard bit / 8 < vector.count else { break }
            vector[bit / 8] |= 1 << (bit % 8)
        }
        body.append(UInt8(vector.count))
        body.append(contentsOf: vector)

        out.append(0x80 | 15)
        out.append(206)
        out.appendBE(UInt16(body.count / 4))
        out.append(body)
        return out
    }
}

// MARK: - Bytes

extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8(value >> 8)); append(UInt8(value & 0xFF))
    }

    mutating func appendBE(_ value: UInt32) {
        appendBE(UInt16(value >> 16)); appendBE(UInt16(value & 0xFFFF))
    }

    mutating func appendBE(_ value: UInt64) {
        appendBE(UInt32(value >> 32)); appendBE(UInt32(value & 0xFFFF_FFFF))
    }
}

/// Big-endian cursor; every read returns nil past the end.
struct ByteReader {
    private let bytes: [UInt8]
    private var cursor = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var isAtEnd: Bool { cursor >= bytes.count }

    mutating func u8() -> UInt8? {
        guard cursor < bytes.count else { return nil }
        defer { cursor += 1 }
        return bytes[cursor]
    }

    mutating func u16() -> UInt16? {
        guard let a = u8(), let b = u8() else { return nil }
        return UInt16(a) << 8 | UInt16(b)
    }

    mutating func u32() -> UInt32? {
        guard let a = u16(), let b = u16() else { return nil }
        return UInt32(a) << 16 | UInt32(b)
    }

    mutating func u64() -> UInt64? {
        guard let a = u32(), let b = u32() else { return nil }
        return UInt64(a) << 32 | UInt64(b)
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, cursor + count <= bytes.count else { return nil }
        defer { cursor += count }
        return Data(bytes[cursor..<cursor + count])
    }

    mutating func rest() -> Data {
        defer { cursor = bytes.count }
        return Data(bytes[min(cursor, bytes.count)...])
    }
}
