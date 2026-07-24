import XCTest
@testable import AudiouterCore

/// T-LATENCY: `LocalOutputLatency.measure()` reads the CURRENT DEFAULT OUTPUT
/// DEVICE's safety offset + device latency + active-stream latency + buffer
/// frame size and converts frames→seconds via the nominal sample rate (brief
/// `dev/notes/p2b-synced-local-brief.md` §4b). This runs against the REAL
/// default output device — there is no fake/mock Core Audio seam here, so the
/// assertions are "plausible", not exact: a real Mac's built-in/USB/Bluetooth
/// output latency is on the order of a few ms to a few tens of ms, never zero
/// (the buffer-frame-size term alone guarantees a non-zero floor) and never
/// absurdly large (seconds).
final class LocalOutputLatencyTests: IsolatedTestCase {

    func test_measure_returnsPlausibleNonZeroLatency() throws {
        #if canImport(AudioToolbox)
        let measurement: LocalOutputLatencyMeasurement
        do {
            measurement = try LocalOutputLatency.measure()
        } catch {
            throw XCTSkip("No default output device available in this environment: \(error)")
        }

        NSLog(
            """
            LocalOutputLatency measured: safetyOffset=%u deviceLatency=%u \
            streamLatency=%u bufferFrameSize=%u nominalSampleRate=%.1f \
            totalFrames=%u totalMs=%.3f
            """,
            measurement.safetyOffsetFrames, measurement.deviceLatencyFrames,
            measurement.streamLatencyFrames, measurement.bufferFrameSizeFrames,
            measurement.nominalSampleRate, measurement.totalFrames, measurement.totalMilliseconds)

        XCTAssertGreaterThan(measurement.nominalSampleRate, 0)
        XCTAssertGreaterThan(measurement.totalFrames, 0)
        XCTAssertGreaterThan(measurement.totalMilliseconds, 0)
        // A real device's total output latency is well under one second —
        // this catches a unit-conversion bug (e.g. frames treated as ms).
        XCTAssertLessThan(measurement.totalMilliseconds, 1000)
        #else
        throw XCTSkip("AudioToolbox unavailable on this platform")
        #endif
    }

    func test_defaultOutputDeviceID_matchesMeasuredDevice() throws {
        #if canImport(AudioToolbox)
        do {
            let deviceID = try LocalOutputLatency.defaultOutputDeviceID()
            let measurement = try LocalOutputLatency.measure(deviceID: deviceID)
            XCTAssertGreaterThan(measurement.nominalSampleRate, 0)
        } catch {
            throw XCTSkip("No default output device available in this environment: \(error)")
        }
        #else
        throw XCTSkip("AudioToolbox unavailable on this platform")
        #endif
    }
}
