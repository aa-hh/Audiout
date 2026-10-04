// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation
import Testing
@testable import CastSender

/// Cast Streaming's byte layouts, pure: RTP, Sender Report, NTP, AES-CTR,
/// receiver feedback, OFFER/ANSWER, and the Opus encoder. Nothing but a real
/// receiver can otherwise tell these bytes are right.
@Suite struct CastStreamingWireTests {

    // Turns red if any RTP header field moves, the marker bit is set on a
    // packet that is not the frame's last, or the playout-delay extension
    // changes shape.
    @Test func rtpPacketHasTheExactCastLayout() throws {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let last = CastRTPPacket.encode(
            payloadType: 127, sequence: 0x1234, rtpTimestamp: 0x0001_0000, ssrc: 7,
            frameID: 5, packetID: 1, maxPacketID: 1, referencedFrameID: 5, payload: payload)
        let expected: [UInt8] = [
            0x80, 0xFF,             // version 2; marker | payload type 127
            0x12, 0x34,             // sequence
            0x00, 0x01, 0x00, 0x00, // RTP timestamp
            0x00, 0x00, 0x00, 0x07, // SSRC
            0xC0,                   // key frame | has reference id, 0 extensions
            0x05,                   // frame id
            0x00, 0x01,             // packet id
            0x00, 0x01,             // max packet id
            0x05,                   // referenced frame id
            0xAA, 0xBB, 0xCC,
        ]
        #expect([UInt8](last) == expected)

        let first = CastRTPPacket.encode(
            payloadType: 127, sequence: 0x1233, rtpTimestamp: 0x0001_0000, ssrc: 7,
            frameID: 5, packetID: 0, maxPacketID: 1, referencedFrameID: 5,
            newPlayoutDelayMs: 300, payload: payload)
        let bytes = [UInt8](first)
        #expect(bytes[1] == 0x7F)
        #expect(bytes[12] == 0xC1)
        #expect(Array(bytes[19..<23]) == [0x04, 0x02, 0x01, 0x2C])
        #expect(Array(bytes[23...]) == [0xAA, 0xBB, 0xCC])

        let decoded = try #require(CastRTPPacket.decode(first))
        #expect(decoded.frameID == 5 && decoded.packetID == 0 && decoded.maxPacketID == 1)
        #expect(decoded.sequence == 0x1233 && decoded.ssrc == 7 && decoded.rtpTimestamp == 0x0001_0000)
        #expect(decoded.newPlayoutDelayMs == 300 && !decoded.marker && decoded.keyFrame)
        #expect(decoded.payload == payload)

        var corrupt = expected
        corrupt[16] = 0xFF
        corrupt[17] = 0xFF
        #expect(CastRTPPacket.decode(Data(corrupt)) == nil)
        #expect(CastStreamingRTP.isRTP(last))
    }

    // Turns red if a Sender Report field moves or the report id stops being
    // the middle 32 bits of the NTP timestamp.
    @Test func senderReportHasTheExactLayout() throws {
        let ntp: UInt64 = 0x0192_A3B4_C5D6_E7F8
        let report = CastSenderReport.encode(ssrc: 1, ntp: ntp, rtpTimestamp: 48_000, packetCount: 10, octetCount: 1_000)
        #expect([UInt8](report) == [
            0x80, 0xC8, 0x00, 0x06,
            0x00, 0x00, 0x00, 0x01,
            0x01, 0x92, 0xA3, 0xB4, 0xC5, 0xD6, 0xE7, 0xF8,
            0x00, 0x00, 0xBB, 0x80,
            0x00, 0x00, 0x00, 0x0A,
            0x00, 0x00, 0x03, 0xE8,
        ])
        #expect(CastNTP.reportID(ntp) == 0xA3B4_C5D6)
        #expect(CastSenderReport.decode(report)?.rtpTimestamp == 48_000)
        #expect(!CastStreamingRTP.isRTP(report))
    }

    // Turns red if the 1900 epoch offset or the 2^-32 fraction scaling changes.
    @Test func ntpTimestampTicksFromTheOrigin() {
        let origin = CastNTP.Origin(monotonicNanos: 5_000_000_000, unixSeconds: 1_700_000_000)
        let atOrigin = CastNTP.timestamp(monotonicNanos: 5_000_000_000, origin: origin)
        #expect(atOrigin >> 32 == 1_700_000_000 + 2_208_988_800)
        #expect(atOrigin & 0xFFFF_FFFF == 0)
        let half = CastNTP.timestamp(monotonicNanos: 5_500_000_000, origin: origin)
        #expect(half >> 32 == atOrigin >> 32)
        #expect(half & 0xFFFF_FFFF == 0x8000_0000)
    }

    // Turns red if the nonce stops putting the frame id at offset 8, the CTR
    // counter is not restarted per frame, or decrypt stops undoing encrypt.
    @Test func frameCryptoRoundTripsAndVariesByFrame() {
        let crypto = CastFrameCrypto(key: Array(0..<16), ivMask: Array(16..<32))
        let plain = Data((0..<1_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let sealed = crypto.crypt(frameID: 1, plain)
        #expect(sealed != plain)
        #expect(crypto.crypt(frameID: 1, sealed) == plain)
        #expect(crypto.crypt(frameID: 2, plain) != sealed)
        #expect(CastFrameCrypto.nonce(frameID: 0x0102_0304, ivMask: Array(repeating: 0, count: 16))
            == [0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 0, 0, 0, 0])
        #expect(CastFrameCrypto(hexKey: crypto.hexKey, hexIVMask: crypto.hexIVMask) == crypto)
    }

    // Turns red if the feedback builder or parser disagree on loss-field bit
    // vectors, the CST2 ACK vector's checkpoint + 2 origin, the report block,
    // or if an application-defined 'TIME' packet stops being skipped.
    @Test func receiverFeedbackRoundTrips() throws {
        let block = CastReceiverFeedback.ReportBlock(
            lastSenderReportID: 0xA3B4_C5D6, delaySinceLastReport: 0x0001_8000,
            extendedHighestSequence: 4_242, cumulativeLost: 3)
        let feedback = CastReceiverFeedback(
            reportBlock: block, receiverReferenceNTP: 0x0102_0304_0506_0708,
            checkpointFrameID: 9, playoutDelayMs: 400,
            nacks: [.init(frameID: 10, packetID: 0xFFFF), .init(frameID: 11, packetID: 2), .init(frameID: 11, packetID: 4)],
            acks: [12, 13])
        let wire = feedback.encode(senderSSRC: 77, receiverSSRC: 78, feedbackCount: 1)
        let bytes = [UInt8](wire)
        // RR(32) + XR(20) + Cast header(20): the second loss field's bit vector.
        let secondLossField = Array(bytes[(32 + 20 + 20 + 4)..<(32 + 20 + 20 + 8)])
        #expect(secondLossField == [11, 0x00, 0x02, 0b0000_0010])

        let parsed = try #require(CastReceiverFeedback.parse(wire, senderSSRC: 77, receiverSSRC: 78, maxFrameID: 13))
        #expect(parsed == feedback)

        var time = Data([0x80, 204, 0x00, 0x02, 0, 0, 0, 78])
        time.append(contentsOf: Array("TIME".utf8))
        let withTime = try #require(CastReceiverFeedback.parse(time + wire, senderSSRC: 77, receiverSSRC: 78, maxFrameID: 13))
        #expect(withTime == feedback)
    }

    // Turns red if the OFFER drops or renames a key a receiver requires, or the
    // ANSWER parser stops turning `result: error` into a receiver error.
    @Test func offerCarriesEveryStreamKeyAndAnswerParses() throws {
        let offer = CastStreamingOffer(targetDelayMs: 400, ssrc: 1234)
        let message = offer.message(seqNum: 1)
        #expect(message["type"] as? String == "OFFER")
        #expect(message["seqNum"] as? Int == 1)
        let body = try #require(message["offer"] as? [String: Any])
        #expect(body["castMode"] as? String == "mirroring")
        let stream = try #require((body["supportedStreams"] as? [[String: Any]])?.first)
        #expect(stream["index"] as? Int == 0)
        #expect(stream["type"] as? String == "audio_source")
        #expect(stream["channels"] as? Int == 2)
        #expect(stream["rtpPayloadType"] as? Int == 127)
        #expect(stream["rtpProfile"] as? String == "cast")
        #expect(stream["ssrc"] as? Int == 1234)
        #expect(stream["targetDelay"] as? Int == 400)
        #expect(stream["receiverRtcpEventLog"] as? Bool == false)
        #expect(stream["timeBase"] as? String == "1/48000")
        #expect(stream["codecParameter"] as? String == "")
        #expect(stream["codecName"] as? String == "opus")
        #expect(stream["bitRate"] as? Int == 128_000)
        for key in ["aesKey", "aesIvMask"] {
            let hex = try #require(stream[key] as? String)
            #expect(hex.count == 32 && hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }

        let ok: [String: Any] = ["type": "ANSWER", "seqNum": 1, "result": "ok",
                                 "answer": ["udpPort": 2344, "sendIndexes": [0], "ssrcs": [264_891]]]
        let answer = try CastStreamingAnswer.parse(ok).get()
        #expect(answer == CastStreamingAnswer(seqNum: 1, udpPort: 2344, sendIndexes: [0], ssrcs: [264_891], maxDelayMs: nil))

        let refused: [String: Any] = ["type": "ANSWER", "seqNum": 1, "result": "error",
                                      "error": ["code": 3, "description": "nope"]]
        guard case .failure(.receiverError(let type, let reason)) = CastStreamingAnswer.parse(refused) else {
            Issue.record("an error ANSWER must parse to receiverError")
            return
        }
        #expect(type == "ANSWER" && reason == "3: nope")
    }

    // Turns red if AudioToolbox stops honouring 10 or 20 ms Opus packets, or
    // the one-frame-per-call input callback stops yielding a packet.
    @Test func opusEncoderEmitsOnePacketPerFrame() throws {
        for frames in [480, 960] {
            let encoder = try CastOpusEncoder(framesPerPacket: frames, bitRate: 128_000)
            var pcm = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                let value = Float(sin(Double(i) * 2 * .pi * 1_000 / 48_000)) * 0.3
                pcm[2 * i] = value
                pcm[2 * i + 1] = value
            }
            let packet = try #require(encoder.encode(pcm))
            #expect(!packet.isEmpty && packet.count <= 1_276)
        }
    }
}
