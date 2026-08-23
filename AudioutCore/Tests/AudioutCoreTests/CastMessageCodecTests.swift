// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation
import Testing
@testable import CastSender

/// The hand-rolled CASTV2 protobuf codec (roadmap 006 Phase 0). Pure — no
/// sockets. These are the exact bytes a Cast receiver expects on the wire, so
/// the byte-for-byte assertion below is the whole point of the suite: nothing
/// else in this project can tell us the encoding is right until real hardware
/// arrives.
@Suite struct CastMessageCodecTests {

    private let message = CastMessage(source: "a", destination: "b", namespace: "c", payload: .utf8("d"))

    @Test func encodesTheExactWireBytes() {
        let expected: [UInt8] = [
            0x08, 0x00,             // 1 protocol_version = CASTV2_1_0
            0x12, 0x01, 0x61,       // 2 source_id = "a"
            0x1A, 0x01, 0x62,       // 3 destination_id = "b"
            0x22, 0x01, 0x63,       // 4 namespace = "c"
            0x28, 0x00,             // 5 payload_type = STRING
            0x32, 0x01, 0x64,       // 6 payload_utf8 = "d"
        ]
        #expect([UInt8](message.encode()) == expected)
        #expect([UInt8](CastMessage.frame(message)) == [0, 0, 0, 16] + expected)
    }

    @Test func roundTripsBothPayloadKinds() throws {
        #expect(try CastMessage.decode(message.encode()) == message)

        let binary = CastMessage(
            source: "sender-0",
            destination: "receiver-0",
            namespace: CastNamespace.connection,
            payload: .binary(Data([0x00, 0xFF, 0x10]))
        )
        #expect(try CastMessage.decode(binary.encode()) == binary)
    }

    @Test func reassemblesFramesAcrossArbitraryChunking() throws {
        var reader = CastFrameReader()
        var collected: [CastMessage] = []
        for byte in CastMessage.frame(message) {
            collected += try reader.append(Data([byte]))
        }
        #expect(collected == [message])

        var pair = CastFrameReader()
        var twoFrames = CastMessage.frame(message)
        twoFrames.append(CastMessage.frame(message))
        #expect(try pair.append(twoFrames).count == 2)
    }

    @Test func skipsUnknownFields() throws {
        // Field 8, varint — what a newer receiver's added field looks like to us.
        var extended = message.encode()
        extended.append(contentsOf: [0x40, 0x01])
        #expect(try CastMessage.decode(extended) == message)
    }

    @Test func rejectsAMessageWithoutANamespace() {
        let bytes = Data([
            0x08, 0x00,
            0x12, 0x01, 0x61,
            0x1A, 0x01, 0x62,
            0x28, 0x00,
            0x32, 0x01, 0x64,
        ])
        #expect(throws: CastError.self) { try CastMessage.decode(bytes) }
    }

    @Test func rejectsALengthThatWouldOverflowTheCursor() {
        // Field 2, length-delimited, with a declared length of `Int.max` — the
        // bounds check has to reject it rather than trap adding it to a cursor.
        let bytes = Data([0x08, 0x00, 0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
        #expect(throws: CastError.self) { try CastMessage.decode(bytes) }
    }

    @Test func rejectsAnOversizedFrame() {
        var reader = CastFrameReader()
        // 65 537 — one byte past the cap, i.e. a desynchronised stream.
        #expect(throws: CastError.self) { try reader.append(Data([0x00, 0x01, 0x00, 0x01])) }
    }
}
