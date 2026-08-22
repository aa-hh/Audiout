// razor: spike diagnostics — replays a phone-captured WAV through the
// analyzer's stages with everything printed. Runs only when PROBE_WAV names a
// file; delete with the debug surface once the probe graduates or dies.
import XCTest
@testable import ProbeKit

final class RealRecordingDiagnostics: XCTestCase {

    func testReplayCapturedWAV() throws {
        guard let path = ProcessInfo.processInfo.environment["PROBE_WAV"] else {
            throw XCTSkip("Set PROBE_WAV=/path/to/probe-take.wav to run the replay.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let (samples, sampleRate) = try Self.readWAV(data)
        print("DIAG wav: \(samples.count) samples @ \(sampleRate) Hz = \(Double(samples.count) / sampleRate)s")

        let pattern = ProbePattern.spike
        let template = TickTemplate.render(sampleRate: sampleRate)
        print("DIAG template: \(template.count) samples")
        let correlation = MatchedFilter(template: template, sampleRate: sampleRate)
            .correlationMagnitudes(of: samples)
        let arrivals = TickPicker(sampleRate: sampleRate).arrivals(in: correlation)
        print("DIAG arrivals: \(arrivals.count)")
        for a in arrivals {
            print(String(format: "DIAG   t=%8.3fs strength=%.4f", a.seconds, a.strength))
        }

        // Re-cluster exactly as the analyzer does, printed.
        let gap = pattern.beatPeriodSeconds * 1.2
        var clusters: [[TickArrival]] = []
        for a in arrivals {
            if let last = clusters.last?.last, a.seconds - last.seconds <= gap {
                clusters[clusters.count - 1].append(a)
            } else {
                clusters.append([a])
            }
        }
        print("DIAG clusters: \(clusters.count)")
        for (i, c) in clusters.enumerated() {
            let span = (c.last?.seconds ?? 0) - (c.first?.seconds ?? 0)
            print(String(format: "DIAG   block %d: %d ticks, %8.3fs → %8.3fs (span %.3fs)",
                         i, c.count, c.first?.seconds ?? 0, c.last?.seconds ?? 0, span))
        }

        do {
            let analysis = try ProbeAnalyzer(sampleRate: sampleRate, pattern: pattern)
                .analyze(recording: samples)
            print("DIAG analyze: offset=\(analysis.offsetMs)ms spread=\(analysis.spreadMs)ms pairs=\(analysis.usedPairs) confident=\(analysis.confident)")
        } catch {
            print("DIAG analyze threw: \(error)")
        }
    }

    /// Minimal 16-bit mono PCM WAV reader (the debug view's own writer format).
    private static func readWAV(_ data: Data) throws -> ([Float], Double) {
        guard data.count > 44 else { throw NSError(domain: "wav", code: 1) }
        func u32(_ offset: Int) -> UInt32 {
            data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        let rate = Double(u32(24))
        // Find the "data" chunk (usually at 36, but scan to be safe).
        var offset = 12
        while offset + 8 < data.count {
            let id = String(decoding: data.subdata(in: offset..<offset + 4), as: UTF8.self)
            let size = Int(u32(offset + 4))
            if id == "data" {
                let payload = data.subdata(in: offset + 8..<min(offset + 8 + size, data.count))
                let samples = payload.withUnsafeBytes { raw -> [Float] in
                    let int16s = raw.bindMemory(to: Int16.self)
                    return int16s.map { Float(Int16(littleEndian: $0)) / Float(Int16.max) }
                }
                return (samples, rate)
            }
            offset += 8 + size + (size % 2)
        }
        throw NSError(domain: "wav", code: 2)
    }
}
