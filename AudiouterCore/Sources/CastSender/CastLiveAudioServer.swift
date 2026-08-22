// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation
import Network

/// Where the served audio comes from. Interleaved signed 16-bit little-endian
/// stereo at 44 100 Hz — 4 bytes per frame.
public protocol CastPCMSource: AnyObject {
    func render(frames: Int) -> Data
}

/// A continuous test tone. Phase carries across calls, so the stream has no
/// clicks at chunk boundaries however the caller slices it.
///
/// razor: sine only — that is all a "does the receiver play what we send, and
/// how long does it take to start" measurement needs. A click track or a real
/// capture feed slots in behind ``CastPCMSource`` unchanged.
public final class SineSource: CastPCMSource {

    private let frequencyHz: Double
    private let amplitude: Double
    private var phase: Double = 0

    public init(frequencyHz: Double = 440, amplitude: Double = 0.25) {
        self.frequencyHz = frequencyHz
        self.amplitude = amplitude
    }

    public func render(frames: Int) -> Data {
        let increment = 2 * Double.pi * frequencyHz / 44_100
        var out = Data(capacity: frames * 4)
        for _ in 0..<frames {
            let scaled = (sin(phase) * amplitude * 32_767).rounded()
            let sample = Int16(max(-32_768, min(32_767, scaled)))
            let low = UInt8(UInt16(bitPattern: sample) & 0xFF)
            let high = UInt8((UInt16(bitPattern: sample) >> 8) & 0xFF)
            out.append(low)
            out.append(high)
            out.append(low)
            out.append(high)
            phase += increment
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
        return out
    }
}

/// The HTTP server the receiver fetches audio from.
///
/// A Cast receiver does not accept pushed audio — it is handed a URL and pulls.
/// So "sending" system audio means serving it: an endless chunked response
/// whose WAV header declares an unknown length (`0xFFFFFFFF`), which every
/// streaming client treats as "read until the socket closes". WAV first
/// (roadmap 006 brief): no encoder, no licensing, and the Default Media
/// Receiver plays it.
public final class CastLiveAudioServer: @unchecked Sendable {

    private static let sampleRate = 44_100
    private static let framesPerChunk = 882          // 20 ms
    private static let chunkInterval = 0.020

    private let source: CastPCMSource
    private let loopbackOnly: Bool
    private let primeMilliseconds: Int
    /// Experiment knob: serve 8-bit mono 22.05 kHz instead of 16-bit stereo
    /// 44.1 kHz — same seconds, one eighth of the bytes. Tells a byte-based
    /// receiver buffer target apart from a time-based one.
    private let liteWAV: Bool
    /// Experiment knob: answer like AirConnect does — `HTTP/1.0 200 OK`, no
    /// Content-Length, no chunked framing, raw body until close.
    private let rawHTTP10: Bool
    /// Experiment knob: answer a `Range:` request with 206 + `Content-Range:
    /// bytes 0-/*` like AirConnect, instead of 200.
    public var range206 = false
    /// Experiment knob: instead of the built-in WAV, run this shell command
    /// per GET and relay its stdout (e.g. ffmpeg emitting FLAC at real time).
    private let pipeCommand: String?
    private let contentType: String
    private var pipes: [ObjectIdentifier: Process] = [:]
    private var streamStartedAt: DispatchTime?
    /// Every request head the receiver sends, for the spike log.
    public var onRequest: ((String) -> Void)?
    private let queue = DispatchQueue(label: "CastLiveAudioServer")

    /// Lock-guarded for the same reason ``CastChannel``'s accessors are: the
    /// caller reads the port from inside ``start(completion:)``'s completion,
    /// which already runs on ``queue``.
    private let portLock = NSLock()
    private var _port: UInt16 = 0
    private var _framesSent = 0

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var timers: [ObjectIdentifier: DispatchSourceTimer] = [:]

    public init(source: CastPCMSource, loopbackOnly: Bool, primeMilliseconds: Int = 0, liteWAV: Bool = false, rawHTTP10: Bool = false, pipeCommand: String? = nil, contentType: String = "audio/wav") {
        self.source = source
        self.loopbackOnly = loopbackOnly
        self.primeMilliseconds = primeMilliseconds
        self.liteWAV = liteWAV
        self.rawHTTP10 = rawHTTP10
        self.pipeCommand = pipeCommand
        self.contentType = contentType
    }

    /// S16LE stereo 44.1 kHz → unsigned 8-bit mono 22.05 kHz (lite mode only).
    private func wire(_ pcm: Data) -> Data {
        guard liteWAV else { return pcm }
        var out = Data(capacity: pcm.count / 8)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var frame = 0
            while frame + 1 < samples.count / 2 {
                let mono = (Int(samples[frame * 2]) + Int(samples[frame * 2 + 1])) / 2
                out.append(UInt8(clamping: (mono >> 8) + 128))
                frame += 2
            }
        }
        return out
    }

    public var port: UInt16 { portLock.withLock { _port } }

    /// Audio seconds handed to the most recent GET, prime included. Against
    /// the receiver's reported `currentTime` this is its buffered lead.
    public var secondsSent: Double {
        portLock.withLock {
            // A piped encoder is paced by its own clock (ffmpeg -re), so the
            // wall clock since the stream began is the only count we have.
            if pipeCommand != nil, let started = streamStartedAt {
                return Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
            }
            return Double(_framesSent) / Double(Self.sampleRate)
        }
    }

    private func countSent(frames: Int) { portLock.withLock { _framesSent += frames } }

    public func url(host: String) -> URL {
        let ext = ["audio/flac": "flac", "audio/mpeg": "mp3", "audio/aac": "aac", "audio/ogg": "ogg", "audio/webm": "webm"][contentType] ?? "wav"
        return URL(string: "http://\(host):\(port)/live.\(ext)")!
    }

    public func start(completion: @escaping (Result<UInt16, Error>) -> Void) {
        queue.async { [self] in
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            if loopbackOnly {
                // Binding all interfaces is what trips the Application
                // Firewall prompt on a test run (see DACPServerTests).
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            }
            let listener: NWListener
            do {
                listener = try NWListener(using: params)
            } catch {
                completion(.failure(error))
                return
            }
            var reported = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !reported else { return }
                switch state {
                case .ready:
                    guard let bound = listener.port, bound.rawValue != 0 else { return }
                    reported = true
                    self.portLock.withLock { self._port = bound.rawValue }
                    completion(.success(bound.rawValue))
                case .failed(let error):
                    reported = true
                    completion(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for (_, timer) in timers { timer.cancel() }
            timers.removeAll()
            for (_, connection) in connections { connection.cancel() }
            connections.removeAll()
            for (_, process) in pipes { process.terminate() }
            pipes.removeAll()
        }
    }

    // MARK: - One client

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.drop(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func drop(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        timers.removeValue(forKey: key)?.cancel()
        pipes.removeValue(forKey: key)?.terminate()
        if connections.removeValue(forKey: key) != nil { connection.cancel() }
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil { self.drop(connection); return }
            if let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<terminator.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
                return
            }
            // A request head this long is not a media client.
            if isComplete || buffer.count > 8192 { self.drop(connection); return }
            self.readRequest(connection, buffer: buffer)
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let method = head.split(separator: "\r\n").first?.split(separator: " ").first.map(String.init) ?? ""
        onRequest?(head)
        switch method {
        case "GET", "HEAD":
            // Any path is served: the receiver only ever fetches the one URL
            // we handed it, and matching on the path adds a failure mode.
            // AirConnect answers a `Range:` request with 206 + Content-Range;
            // whether that changes the receiver's buffering is the experiment.
            let ranged = range206 && head.split(separator: "\r\n").contains { $0.lowercased().hasPrefix("range:") }
            let status = ranged ? "206 Partial Content" : "200 OK"
            let contentRange = ranged ? "Content-Range: bytes 0-/*\r\n" : ""
            let header = rawHTTP10
                ? "HTTP/1.0 \(status)\r\nServer: Audiouter\r\nContent-Type: \(contentType)\r\n\(contentRange)Connection: close\r\n\r\n"
                : "HTTP/1.1 \(status)\r\n"
                + "Content-Type: \(contentType)\r\n"
                + contentRange
                + "Transfer-Encoding: chunked\r\n"
                + "Cache-Control: no-cache\r\n"
                + "Accept-Ranges: none\r\n"
                + "Connection: close\r\n"
                + "\r\n"
            // A HEAD answer is the header and nothing else — but the close has
            // to wait for the send to actually flush, or `cancel()` takes the
            // bytes with it and the client sees an empty response.
            guard method == "GET" else { send(Data(header.utf8), on: connection, thenClose: true); return }
            send(Data(header.utf8), on: connection)
            if let command = pipeCommand { startPipe(command, on: connection); return }
            sendChunk(wavHeader(), on: connection)
            portLock.withLock { _framesSent = 0 }
            if primeMilliseconds > 0 {
                let frames = Int(Double(primeMilliseconds) * Double(Self.sampleRate) / 1000)
                sendChunk(wire(source.render(frames: frames)), on: connection)
                countSent(frames: frames)
            }
            startStreaming(on: connection)
        default:
            send(Data("HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n".utf8), on: connection, thenClose: true)
        }
    }

    private func startPipe(_ command: String, on connection: NWConnection) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async {
                guard self.pipes[ObjectIdentifier(connection)] != nil else { return }
                if data.isEmpty { handle.readabilityHandler = nil; return }
                self.sendChunk(data, on: connection)
            }
        }
        do {
            try process.run()
        } catch {
            drop(connection)
            return
        }
        pipes[ObjectIdentifier(connection)] = process
        portLock.withLock { streamStartedAt = DispatchTime.now() }
    }

    private func startStreaming(on connection: NWConnection) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.chunkInterval, repeating: Self.chunkInterval, leeway: .milliseconds(1))
        // Pace by the wall clock, not by tick count: a 20 ms timer fires a
        // little under 50 Hz (measured 0.44 % slow on a 3-minute soak), and a
        // fixed 882 frames per tick then falls behind real time for good.
        let startedAt = DispatchTime.now()
        var streamedFrames = 0
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000
            let due = Int(elapsed * Double(Self.sampleRate)) - streamedFrames
            guard due > 0 else { return }
            self.sendChunk(self.wire(self.source.render(frames: due)), on: connection)
            self.countSent(frames: due)
            streamedFrames += due
        }
        timers[ObjectIdentifier(connection)] = timer
        timer.resume()
    }

    /// One `Transfer-Encoding: chunked` chunk. The terminating `0\r\n\r\n` is
    /// never sent — the stream is endless by construction.
    private func sendChunk(_ payload: Data, on connection: NWConnection) {
        if rawHTTP10 { send(payload, on: connection); return }
        var frame = Data(String(format: "%X\r\n", payload.count).utf8)
        frame.append(payload)
        frame.append(Data("\r\n".utf8))
        send(frame, on: connection)
    }

    private func send(_ data: Data, on connection: NWConnection, thenClose: Bool = false) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error != nil || thenClose else { return }
            self?.drop(connection)
        })
    }

    /// 44 bytes of canonical WAV, with both size fields set to `0xFFFFFFFF`
    /// because the stream never ends.
    private func wavHeader() -> Data {
        var out = Data()
        func append(_ text: String) { out.append(Data(text.utf8)) }
        func append32(_ value: UInt32) {
            out.append(UInt8(value & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF))
            out.append(UInt8((value >> 16) & 0xFF))
            out.append(UInt8((value >> 24) & 0xFF))
        }
        func append16(_ value: UInt16) {
            out.append(UInt8(value & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF))
        }
        append("RIFF")
        append32(0xFFFF_FFFF)
        append("WAVE")
        append("fmt ")
        append32(16)                              // PCM chunk size
        append16(1)                               // PCM
        append16(liteWAV ? 1 : 2)                 // channels
        append32(UInt32(liteWAV ? Self.sampleRate / 2 : Self.sampleRate))
        append32(UInt32(liteWAV ? Self.sampleRate / 2 : Self.sampleRate * 4))  // byte rate
        append16(liteWAV ? 1 : 4)                 // block align
        append16(liteWAV ? 8 : 16)                // bits per sample
        append("data")
        append32(0xFFFF_FFFF)
        return out
    }
}
