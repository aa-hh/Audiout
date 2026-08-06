// Conservation property for AVFormatConverter: total output frames must stay
// within 1 frame of rounding error per call from the exact ratio × input total.
// A systematic short-fall here would be a root cause of the measured ~3.3 ms/s
// anchor slide (T-3, roadmap-016 judder investigation).
//
// These tests are headless — no hardware, no TCC, no real audio stack.

import Testing
import Foundation
@testable import AudiouterCore

@Suite struct AVFormatConverterConservationTests {

    // MARK: - helpers

    private func makePlanaBuffer(frameCount: Int) -> CapturedBuffer {
        let bytesPerChannel = frameCount * 4   // Float32 = 4 bytes/sample
        let ch = Data(repeating: 0, count: bytesPerChannel)
        return CapturedBuffer(
            channelData: [ch, ch],
            frameCount: frameCount,
            pts: timespec(tv_sec: 0, tv_nsec: 0))
    }

    // MARK: - 48 kHz → 44.1 kHz conservation

    /// 48 000 → 44 100 Hz resampling must not silently drop frames beyond
    // rounding: over 937 calls the cumulative output frame count must land
    // within ±callCount of ratio × totalInput.  A systematic short-fall is
    // the candidate cause of the measured ~3.3 ms/s anchor slide.
    @Test func conservation_48k_to_44k() throws {
        let tapFmt = TapFormat(
            sampleRate: 48_000,
            channels: 2,
            bitsPerSample: 32,
            isFloat: true,
            isInterleaved: false)

        let converter = AVFormatConverter(from: tapFmt)

        // Sanity: converter must initialise.  A nil internal converter means
        // TapFormat is mis-specified — this test is broken, not AVFormatConverter.
        let probe = converter.convertToAirPlayPCM(makePlanaBuffer(frameCount: 512))
        if probe == nil {
            Issue.record("AVFormatConverter init failed for 48 kHz / Float32 / non-interleaved TapFormat — test is misconfigured")
            return
        }

        let framesPerCall = 512
        let callCount = 937     // ≈ 10 s at 48 000 Hz
        let ratio = 44_100.0 / 48_000.0

        // S16LE interleaved: 2 bytes × 2 channels = 4 bytes per frame
        let bytesPerFrame = 4
        var sumActualFrames = Int(probe!.count / bytesPerFrame)

        for _ in 1..<callCount {
            let result = converter.convertToAirPlayPCM(makePlanaBuffer(frameCount: framesPerCall))
            guard let data = result else {
                Issue.record("convertToAirPlayPCM returned nil mid-run")
                return
            }
            sumActualFrames += data.count / bytesPerFrame
        }

        let totalInput = framesPerCall * callCount
        let expectedFrames = Int(round(Double(totalInput) * ratio))
        // Allow at most 1 frame of rounding error per call — not cumulative.
        let tolerance = callCount

        #expect(
            abs(sumActualFrames - expectedFrames) <= tolerance,
            "Conservation violation: got \(sumActualFrames) frames, expected \(expectedFrames) ±\(tolerance). Shortfall of \(expectedFrames - sumActualFrames) frames over \(callCount) calls.")
    }

    // MARK: - 44.1 kHz → 44.1 kHz passthrough

    /// Same-rate (passthrough) conversion must return exactly the input frame
    /// count on every call — no rounding, no loss.
    @Test func conservation_44k_passthrough() throws {
        let tapFmt = TapFormat(
            sampleRate: 44_100,
            channels: 2,
            bitsPerSample: 32,
            isFloat: true,
            isInterleaved: false)

        let converter = AVFormatConverter(from: tapFmt)

        let framesPerCall = 512
        let callCount = 100
        let bytesPerFrame = 4

        for callIndex in 0..<callCount {
            let result = converter.convertToAirPlayPCM(makePlanaBuffer(frameCount: framesPerCall))
            guard let data = result else {
                Issue.record("convertToAirPlayPCM returned nil at call \(callIndex)")
                return
            }
            let outputFrames = data.count / bytesPerFrame
            #expect(outputFrames == framesPerCall,
                    "Passthrough call \(callIndex): got \(outputFrames) frames, expected \(framesPerCall)")
        }
    }
}
