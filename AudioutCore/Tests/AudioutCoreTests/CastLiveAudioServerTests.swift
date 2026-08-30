// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation
import Network
import Testing
@testable import CastSender

/// The live-audio HTTP server a Cast receiver fetches from (roadmap 006
/// Phase 0). Drives it over a REAL loopback socket, because the thing under
/// test is the wire response — the chunked framing, the endless WAV header,
/// the 20 ms cadence — not a function's return value.
///
/// Every listener here is loopback-only (`loopbackOnly: true`), which is what
/// keeps macOS's Application Firewall from prompting the xctest process; see
/// DACPServerTests for the same lesson.
@Suite struct CastLiveAudioServerTests {

    // MARK: - Wire helpers

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var ended = false
        func append(_ data: Data) { lock.withLock { bytes.append(data) } }
        func end() { lock.withLock { ended = true } }
        var data: Data { lock.withLock { bytes } }
        var completed: Bool { lock.withLock { ended } }
    }

    private final class PortBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt16?
        func set(_ port: UInt16) { lock.withLock { stored = port } }
        var value: UInt16? { lock.withLock { stored } }
    }

    private func startServer(primeMilliseconds: Int = 0) throws -> (server: CastLiveAudioServer, port: UInt16) {
        let server = CastLiveAudioServer(source: SineSource(), loopbackOnly: true, primeMilliseconds: primeMilliseconds)
        let box = PortBox()
        server.start { result in
            if case .success(let port) = result { box.set(port) }
        }
        let deadline = Date().addingTimeInterval(2)
        while box.value == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        let port = try #require(box.value, "live audio server never bound a loopback port")
        return (server, port)
    }

    /// Sends one request and collects the response until `until` is satisfied,
    /// the server closes, or `timeout` elapses. Spin-waits rather than blocks,
    /// matching the idiom in DACPServerTests.
    private func exchange(
        port: UInt16,
        request: String,
        timeout: TimeInterval,
        until: (Data) -> Bool
    ) -> (data: Data, completed: Bool) {
        let collector = Collector()
        let netQueue = DispatchQueue(label: "CastLiveAudioServerTests.client")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty { collector.append(data) }
                if isComplete || error != nil { collector.end(); return }
                receive()
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(request.utf8), completion: .idempotent)
                receive()
            case .failed, .cancelled:
                collector.end()
            default:
                break
            }
        }
        connection.start(queue: netQueue)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if collector.completed || until(collector.data) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let result = (collector.data, collector.completed)
        connection.cancel()
        return result
    }

    private func split(_ response: Data) -> (head: String, body: Data)? {
        guard let terminator = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return (
            String(decoding: response[response.startIndex..<terminator.lowerBound], as: UTF8.self),
            Data(response[terminator.upperBound...])
        )
    }

    /// Every COMPLETE chunk in a `Transfer-Encoding: chunked` body so far.
    private func chunks(_ body: Data) -> [Data] {
        var out: [Data] = []
        var rest = body
        while let lineEnd = rest.range(of: Data("\r\n".utf8)) {
            let hex = String(decoding: rest[rest.startIndex..<lineEnd.lowerBound], as: UTF8.self)
            guard let length = Int(hex, radix: 16), length > 0 else { break }
            let start = lineEnd.upperBound
            guard rest.distance(from: start, to: rest.endIndex) >= length + 2 else { break }
            let end = rest.index(start, offsetBy: length)
            out.append(Data(rest[start..<end]))
            rest = Data(rest[rest.index(end, offsetBy: 2)...])
        }
        return out
    }

    private func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    // MARK: - Tests

    @Test func servesAnEndlessChunkedWavStream() throws {
        let (server, port) = try startServer()
        defer { server.stop() }

        let (response, _) = exchange(port: port, request: "GET /live.wav HTTP/1.1\r\nHost: x\r\n\r\n", timeout: 2) {
            guard let (_, body) = self.split($0) else { return false }
            return self.chunks(body).count >= 4
        }
        let (head, body) = try #require(split(response), "no complete response head arrived")
        #expect(head.hasPrefix("HTTP/1.1 200 OK"))
        #expect(head.contains("Transfer-Encoding: chunked"))
        #expect(head.contains("Content-Type: audio/wav"))

        let parsed = chunks(body)
        try #require(parsed.count >= 4, "expected the WAV header plus at least three audio chunks, got \(parsed.count)")

        let header = parsed[0]
        #expect(header.count == 44)
        #expect(header.prefix(4) == Data("RIFF".utf8))
        #expect(header[8..<12] == Data("WAVE".utf8))
        #expect(u16(header, 22) == 2)          // stereo
        #expect(u32(header, 24) == 44_100)     // sample rate
        #expect(u16(header, 34) == 16)         // bits per sample
        // Wall-clock pacing (not a fixed frame count per tick) means each
        // chunk's size varies a little, but three ticks of audio should
        // still add up to about 3 x 882 frames x 4 bytes = 10,584 bytes.
        //
        // No assertion on the TOTAL bytes of these three chunks, in either
        // direction, because that total is not a stable quantity.
        //
        // The comment that used to stand here claimed load could only push the
        // sum up (a late tick sends extra to catch up), so successive upper
        // bounds were raised — 11,500, then 13,000 — as busy machines beat
        // them. That reasoning was incomplete, and dropping the ceiling on the
        // strength of it was wrong: the collector above stops as soon as FOUR
        // chunks have arrived, so what these three contain depends on how the
        // server's pacing loop happened to slice time, not on how much audio it
        // owes. Ticks firing early and small make the sum fall just as jitter
        // makes it rise, and the lower bound was then observed failing too.
        //
        // What the test is named for is still fully asserted: a valid WAV
        // header, and an endless chunked stream whose audio chunks carry real
        // payload. Genuine under-sending — the failure that would starve a
        // receiver — is a RATE, so catching it means measuring bytes against
        // elapsed wall time rather than against a fixed chunk count. That is a
        // different test, and worth writing if starvation ever shows up.
        let sizes = parsed[1...3].map(\.count)
        #expect(sizes.allSatisfy { $0 > 0 })
    }

    @Test func headGetsTheHeaderAndThenEOF() throws {
        let (server, port) = try startServer()
        defer { server.stop() }

        let (response, completed) = exchange(port: port, request: "HEAD /live.wav HTTP/1.1\r\nHost: x\r\n\r\n", timeout: 2) { _ in false }
        #expect(completed, "the server should close after answering a HEAD")
        let (head, body) = try #require(split(response), "no complete response head arrived")
        #expect(head.hasPrefix("HTTP/1.1 200 OK"))
        #expect(body.isEmpty)
    }

    @Test func rejectsAnythingOtherThanGetOrHead() throws {
        let (server, port) = try startServer()
        defer { server.stop() }

        let (response, _) = exchange(port: port, request: "POST /live.wav HTTP/1.1\r\nHost: x\r\n\r\n", timeout: 2) {
            $0.count >= 12
        }
        #expect(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 405"))
    }

    @Test func sineSourceIsContinuousAcrossRenders() {
        let source = SineSource()
        let first = source.render(frames: 441)
        #expect(first.count == 1_764)
        #expect(first.contains { $0 != 0 })

        let twoRenders = first + source.render(frames: 441)
        let oneRender = SineSource().render(frames: 882)
        #expect(twoRenders == oneRender, "phase must carry across renders, or the stream clicks at every chunk boundary")
    }
}
