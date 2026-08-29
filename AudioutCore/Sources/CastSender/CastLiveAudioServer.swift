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
    /// Frames the source can hand over right now, or `nil` for a source that
    /// generates rather than buffers and is therefore never short.
    ///
    /// The pacing clock below refuses to start until a buffering source has a
    /// cushion. Without that, producer and consumer both run at exactly 1x
    /// with nothing between them: the ring sits at zero, every scheduling
    /// wobble on the capture side becomes silence the listener hears, and
    /// `streamedFrames` advances past it so the audio is not late, it is gone.
    var bufferedFrames: Int? { get }
}

public extension CastPCMSource {
    var bufferedFrames: Int? { nil }
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

    public init(source: CastPCMSource, loopbackOnly: Bool, primeMilliseconds: Int = 0) {
        self.source = source
        self.loopbackOnly = loopbackOnly
        self.primeMilliseconds = primeMilliseconds
    }

    public var port: UInt16 { portLock.withLock { _port } }

    /// Audio seconds handed to the most recent GET, prime included. Against
    /// the receiver's reported `currentTime` this is its buffered lead.
    public var secondsSent: Double {
        portLock.withLock { Double(_framesSent) / Double(Self.sampleRate) }
    }

    private func countSent(frames: Int) { portLock.withLock { _framesSent += frames } }

    public func url(host: String) -> URL {
        URL(string: "http://\(host):\(port)/live.wav")!
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
            let header = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: audio/wav\r\n"
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
            sendChunk(wavHeader(), on: connection)
            portLock.withLock { _framesSent = 0 }
            if primeMilliseconds > 0 {
                let frames = Int(Double(primeMilliseconds) * Double(Self.sampleRate) / 1000)
                sendChunk(source.render(frames: frames), on: connection)
                countSent(frames: frames)
            }
            startStreaming(on: connection)
        default:
            send(Data("HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n".utf8), on: connection, thenClose: true)
        }
    }

    /// How much the ring must hold before the pacing clock starts. Generous on
    /// purpose: the room-delay controller MEASURES whatever lead this produces
    /// and takes it out of the other outputs, so a cushion costs nothing in
    /// sync terms — only a little more total latency on a leg already seconds
    /// deep. The ring holds 2 s, so this leaves ample headroom.
    static let cushionFrames = sampleRate / 2          // 500 ms

    /// How long the clock will wait for that cushion before starting anyway.
    /// A cushion that never arrives must degrade to today's behaviour, not to
    /// silence: a source that cannot fill the ring is a reason to stream badly
    /// and log it, never a reason to stream nothing at all.
    static let cushionDeadline: TimeInterval = 2

    private func startStreaming(on connection: NWConnection) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.chunkInterval, repeating: Self.chunkInterval, leeway: .milliseconds(1))
        // Pace by the wall clock, not by tick count: a 20 ms timer fires a
        // little under 50 Hz (measured 0.44 % slow on a 3-minute soak), and a
        // fixed 882 frames per tick then falls behind real time for good.
        // Start the clock on the first tick that finds a cushion, NOT on the
        // GET. A buffering source is empty at this point — the ring was reset
        // to the live edge moments ago — so starting here means demanding
        // audio nobody has produced yet, forever.
        var startedAt: DispatchTime?
        var streamedFrames = 0
        let waitingSince = DispatchTime.now()
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let clockStart = startedAt else {
                let waited = Double(DispatchTime.now().uptimeNanoseconds
                    - waitingSince.uptimeNanoseconds) / 1_000_000_000
                if waited < Self.cushionDeadline,
                   let buffered = self.source.bufferedFrames,
                   buffered < Self.cushionFrames { return }
                startedAt = DispatchTime.now()
                return
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - clockStart.uptimeNanoseconds) / 1_000_000_000
            let due = Int(elapsed * Double(Self.sampleRate)) - streamedFrames
            guard due > 0 else { return }
            self.sendChunk(self.source.render(frames: due), on: connection)
            self.countSent(frames: due)
            streamedFrames += due
        }
        timers[ObjectIdentifier(connection)] = timer
        timer.resume()
    }

    /// One `Transfer-Encoding: chunked` chunk. The terminating `0\r\n\r\n` is
    /// never sent — the stream is endless by construction.
    private func sendChunk(_ payload: Data, on connection: NWConnection) {
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
        append16(2)                               // channels
        append32(UInt32(Self.sampleRate))
        append32(UInt32(Self.sampleRate * 4))     // byte rate
        append16(4)                               // block align
        append16(16)                              // bits per sample
        append("data")
        append32(0xFFFF_FFFF)
        return out
    }
}
