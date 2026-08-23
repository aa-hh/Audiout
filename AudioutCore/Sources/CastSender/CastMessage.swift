// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation

/// The four `urn:x-cast:` namespaces this sender speaks.
public enum CastNamespace {
    public static let connection = "urn:x-cast:com.google.cast.tp.connection"
    public static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    public static let receiver = "urn:x-cast:com.google.cast.receiver"
    public static let media = "urn:x-cast:com.google.cast.media"
}

/// The two well-known endpoint ids on the control channel. Application
/// endpoints ("transport ids") are handed out by the receiver at LAUNCH.
public enum CastIDs {
    public static let sender = "sender-0"
    public static let platform = "receiver-0"
}

public enum CastError: Error {
    case connectionFailed(String)
    case timeout
    case closed
    case protocolViolation(String)
    case receiverError(type: String, reason: String?)
    case applicationNotInStatus(appID: String)
    case noLocalAddress
}

/// One CASTV2 `CastMessage`, encoded by hand.
///
/// The wire format is proto2 with seven fields, five of them required:
/// 1 `protocol_version` (enum, CASTV2_1_0 = 0), 2 `source_id`,
/// 3 `destination_id`, 4 `namespace`, 5 `payload_type` (STRING = 0,
/// BINARY = 1), 6 `payload_utf8`, 7 `payload_binary`. Every message is framed
/// by a 4-byte big-endian length prefix. That is the entire schema — small
/// enough that hand-rolling it is cheaper than taking on SwiftProtobuf and its
/// code generation step (roadmap 006 brief, decision 4).
public struct CastMessage: Equatable {

    public enum Payload: Equatable {
        case utf8(String)
        case binary(Data)
    }

    public var sourceID: String
    public var destinationID: String
    public var namespace: String
    public var payload: Payload

    public init(source: String, destination: String, namespace: String, payload: Payload) {
        self.sourceID = source
        self.destinationID = destination
        self.namespace = namespace
        self.payload = payload
    }

    /// A JSON-payload message — the form every namespace here actually uses.
    public init(source: String, destination: String, namespace: String, json: [String: Any]) {
        let text = (try? JSONSerialization.data(withJSONObject: json))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.init(source: source, destination: destination, namespace: namespace, payload: .utf8(text))
    }

    // MARK: - Encoding

    /// Field tags are `(fieldNumber << 3) | wireType`. Required fields are
    /// emitted even when their value is the proto default (a real receiver
    /// rejects a message whose `protocol_version` or `payload_type` is absent).
    public func encode() -> Data {
        var out = Data()
        out.append(0x08)                                    // 1, varint
        Self.appendVarint(0, to: &out)                      // CASTV2_1_0
        Self.append(string: sourceID, tag: 0x12, to: &out)  // 2, length-delimited
        Self.append(string: destinationID, tag: 0x1A, to: &out)
        Self.append(string: namespace, tag: 0x22, to: &out)
        out.append(0x28)                                    // 5, varint
        switch payload {
        case .utf8(let text):
            Self.appendVarint(0, to: &out)
            Self.append(string: text, tag: 0x32, to: &out)  // 6
        case .binary(let data):
            Self.appendVarint(1, to: &out)
            out.append(0x3A)                                // 7
            Self.appendVarint(UInt64(data.count), to: &out)
            out.append(data)
        }
        return out
    }

    /// One framed message: 4-byte big-endian length, then the encoding.
    public static func frame(_ message: CastMessage) -> Data {
        let body = message.encode()
        var out = Data(capacity: body.count + 4)
        let length = UInt32(body.count)
        out.append(UInt8((length >> 24) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(body)
        return out
    }

    private static func append(string: String, tag: UInt8, to data: inout Data) {
        let bytes = Data(string.utf8)
        data.append(tag)
        appendVarint(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }

    // MARK: - Decoding

    public static func decode(_ data: Data) throws -> CastMessage {
        let bytes = [UInt8](data)
        var cursor = 0
        var source: String?
        var destination: String?
        var namespace: String?
        var payloadType: UInt64 = 0
        var utf8Payload: String?
        var binaryPayload: Data?

        while cursor < bytes.count {
            let tag = try readVarint(bytes, &cursor)
            let field = tag >> 3
            let wireType = tag & 0x07
            switch (field, wireType) {
            case (1, 0): _ = try readVarint(bytes, &cursor)
            case (2, 2): source = try readString(bytes, &cursor)
            case (3, 2): destination = try readString(bytes, &cursor)
            case (4, 2): namespace = try readString(bytes, &cursor)
            case (5, 0): payloadType = try readVarint(bytes, &cursor)
            case (6, 2): utf8Payload = try readString(bytes, &cursor)
            case (7, 2): binaryPayload = Data(try readLengthDelimited(bytes, &cursor))
            default: try skip(wireType: wireType, bytes, &cursor)
            }
        }

        guard let source else { throw CastError.protocolViolation("CastMessage without source_id") }
        guard let destination else { throw CastError.protocolViolation("CastMessage without destination_id") }
        guard let namespace else { throw CastError.protocolViolation("CastMessage without namespace") }

        let payload: Payload
        switch payloadType {
        case 0:
            guard let utf8Payload else { throw CastError.protocolViolation("STRING CastMessage without payload_utf8") }
            payload = .utf8(utf8Payload)
        case 1:
            guard let binaryPayload else { throw CastError.protocolViolation("BINARY CastMessage without payload_binary") }
            payload = .binary(binaryPayload)
        default:
            throw CastError.protocolViolation("unknown payload_type \(payloadType)")
        }
        return CastMessage(source: source, destination: destination, namespace: namespace, payload: payload)
    }

    /// Unknown fields are skipped by wire type rather than rejected — that is
    /// what makes a proto2 reader forward-compatible with a newer receiver.
    private static func skip(wireType: UInt64, _ bytes: [UInt8], _ cursor: inout Int) throws {
        switch wireType {
        case 0: _ = try readVarint(bytes, &cursor)
        case 1: try advance(8, bytes, &cursor)
        case 2: _ = try readLengthDelimited(bytes, &cursor)
        case 5: try advance(4, bytes, &cursor)
        default: throw CastError.protocolViolation("unknown wire type \(wireType)")
        }
    }

    private static func advance(_ count: Int, _ bytes: [UInt8], _ cursor: inout Int) throws {
        guard count <= bytes.count - cursor else { throw CastError.protocolViolation("field ran past the end of the message") }
        cursor += count
    }

    private static func readVarint(_ bytes: [UInt8], _ cursor: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var read = 0
        while true {
            guard cursor < bytes.count else { throw CastError.protocolViolation("varint ran past the end of the message") }
            let byte = bytes[cursor]
            cursor += 1
            read += 1
            guard read <= 10 else { throw CastError.protocolViolation("varint longer than 10 bytes") }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private static func readLengthDelimited(_ bytes: [UInt8], _ cursor: inout Int) throws -> ArraySlice<UInt8> {
        let raw = try readVarint(bytes, &cursor)
        // `length <= bytes.count - cursor`, never `cursor + length <= …`: a
        // hostile varint can declare a length near `Int.max`, and the addition
        // would trap before the bounds check could reject it.
        guard let length = Int(exactly: raw), length <= bytes.count - cursor else {
            throw CastError.protocolViolation("length-delimited field ran past the end of the message")
        }
        let slice = bytes[cursor..<(cursor + length)]
        cursor += length
        return slice
    }

    private static func readString(_ bytes: [UInt8], _ cursor: inout Int) throws -> String {
        let slice = try readLengthDelimited(bytes, &cursor)
        guard let text = String(bytes: slice, encoding: .utf8) else {
            throw CastError.protocolViolation("field is not valid UTF-8")
        }
        return text
    }
}

/// Reassembles length-prefixed frames off a byte stream that arrives in
/// whatever chunks the socket hands us.
public struct CastFrameReader {

    /// A receiver never sends a control message anywhere near this big; a
    /// larger declared length means the stream has desynchronised (or is not a
    /// Cast stream at all), and reading it would mean buffering garbage.
    private static let maximumFrameLength = 65_536

    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [CastMessage] {
        buffer.append(data)
        var messages: [CastMessage] = []
        while buffer.count >= 4 {
            let header = [UInt8](buffer.prefix(4))
            let length = (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            guard length <= Self.maximumFrameLength else {
                throw CastError.protocolViolation("frame length \(length) exceeds \(Self.maximumFrameLength)")
            }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.dropFirst(4).prefix(length)
            messages.append(try CastMessage.decode(Data(body)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return messages
    }
}
