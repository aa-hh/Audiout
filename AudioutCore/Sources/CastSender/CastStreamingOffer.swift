// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation

/// The sender's OFFER for one Opus audio stream in mirroring mode, sent on
/// ``CastNamespace/webrtc`` to the launched mirroring app.
public struct CastStreamingOffer {
    public var index = 0
    public var ssrc: UInt32
    public var rtpPayloadType: UInt8
    public var targetDelayMs: Int
    public var bitRate: Int
    public var channels = 2
    public var sampleRate = 48_000
    public var crypto: CastFrameCrypto

    public init(
        targetDelayMs: Int,
        rtpPayloadType: UInt8 = 127,
        bitRate: Int = 128_000,
        ssrc: UInt32 = UInt32.random(in: 1...50_000),
        crypto: CastFrameCrypto = .random()
    ) {
        self.targetDelayMs = targetDelayMs
        self.rtpPayloadType = rtpPayloadType
        self.bitRate = bitRate
        self.ssrc = ssrc
        self.crypto = crypto
    }

    public func message(seqNum: Int) -> [String: Any] {
        let stream: [String: Any] = [
            "index": index,
            "type": "audio_source",
            "channels": channels,
            "rtpPayloadType": Int(rtpPayloadType),
            "rtpProfile": "cast",
            "ssrc": Int(ssrc),
            "targetDelay": targetDelayMs,
            "aesKey": crypto.hexKey,
            "aesIvMask": crypto.hexIVMask,
            "receiverRtcpEventLog": false,
            "timeBase": "1/\(sampleRate)",
            "codecParameter": "",
            "codecName": "opus",
            // openscreen's own sender never offers less than 32 kb/s.
            "bitRate": max(bitRate, 32_000),
        ]
        return [
            "type": "OFFER",
            "seqNum": seqNum,
            "offer": ["castMode": "mirroring", "supportedStreams": [stream]] as [String: Any],
        ]
    }
}

/// The receiver's ANSWER: where to send RTP/RTCP and the SSRC it reports as.
public struct CastStreamingAnswer: Equatable {
    public var seqNum: Int
    public var udpPort: UInt16
    public var sendIndexes: [Int]
    public var ssrcs: [UInt32]
    /// `constraints.audio.maxDelay`, when the receiver sent one.
    public var maxDelayMs: Int?

    public static func parse(_ json: [String: Any]) -> Result<CastStreamingAnswer, CastError> {
        guard (json["type"] as? String) == "ANSWER" else {
            return .failure(.protocolViolation("expected ANSWER, got \(json["type"] ?? "nil")"))
        }
        let seqNum = json["seqNum"] as? Int ?? -1
        switch json["result"] as? String {
        case "ok":
            guard let answer = json["answer"] as? [String: Any],
                  let port = answer["udpPort"] as? Int, (1...65_535).contains(port),
                  let indexes = answer["sendIndexes"] as? [Int],
                  let ssrcs = answer["ssrcs"] as? [Int] else {
                return .failure(.protocolViolation("ANSWER without udpPort/sendIndexes/ssrcs"))
            }
            let audio = (answer["constraints"] as? [String: Any])?["audio"] as? [String: Any]
            return .success(CastStreamingAnswer(
                seqNum: seqNum, udpPort: UInt16(port), sendIndexes: indexes,
                ssrcs: ssrcs.map { UInt32(truncatingIfNeeded: $0) },
                maxDelayMs: audio?["maxDelay"] as? Int))
        case "error":
            let error = json["error"] as? [String: Any]
            let code = error?["code"] as? Int ?? 0
            let description = error?["description"] as? String ?? ""
            return .failure(.receiverError(type: "ANSWER", reason: "\(code): \(description)"))
        default:
            return .failure(.protocolViolation("ANSWER result \(json["result"] ?? "nil")"))
        }
    }
}
