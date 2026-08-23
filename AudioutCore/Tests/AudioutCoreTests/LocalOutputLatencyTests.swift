import Foundation
import Testing
@testable import AudioutCore

#if canImport(AudioToolbox)
/// Hoists the "no default output device available in this environment" skip
/// (cookbook §9's "awkward case that CAN be hoisted") into a suite-discovery-time
/// probe: the condition doesn't depend on state built up during a test body, it's
/// discoverable by just trying the same real-hardware call once up front.
enum LocalOutputLatencyGate {
    static let hasDefaultOutputDevice: Bool = (try? LocalOutputLatency.measure()) != nil
}
#endif

/// T-LATENCY: `LocalOutputLatency.measure()` reads the CURRENT DEFAULT OUTPUT
/// DEVICE's safety offset + device latency + active-stream latency + buffer
/// frame size and converts frames→seconds via the nominal sample rate (brief
/// `dev/notes/p2b-synced-local-brief.md` §4b). This runs against the REAL
/// default output device — there is no fake/mock Core Audio seam here, so the
/// assertions are "plausible", not exact: a real Mac's built-in/USB/Bluetooth
/// output latency is on the order of a few ms to a few tens of ms, never zero
/// (the buffer-frame-size term alone guarantees a non-zero floor) and never
/// absurdly large (seconds).
@Suite final class LocalOutputLatencyTests: IsolatedSuite {

    #if canImport(AudioToolbox)
    @Test(.enabled(if: LocalOutputLatencyGate.hasDefaultOutputDevice,
                    "No default output device available in this environment"))
    func measureReturnsPlausibleNonZeroLatency() throws {
        let measurement = try LocalOutputLatency.measure()

        NSLog(
            """
            LocalOutputLatency measured: safetyOffset=%u deviceLatency=%u \
            streamLatency=%u bufferFrameSize=%u nominalSampleRate=%.1f \
            totalFrames=%u totalMs=%.3f
            """,
            measurement.safetyOffsetFrames, measurement.deviceLatencyFrames,
            measurement.streamLatencyFrames, measurement.bufferFrameSizeFrames,
            measurement.nominalSampleRate, measurement.totalFrames, measurement.totalMilliseconds)

        #expect(measurement.nominalSampleRate > 0)
        #expect(measurement.totalFrames > 0)
        #expect(measurement.totalMilliseconds > 0)
        // A real device's total output latency is well under one second —
        // this catches a unit-conversion bug (e.g. frames treated as ms).
        #expect(measurement.totalMilliseconds < 1000)
    }

    @Test(.enabled(if: LocalOutputLatencyGate.hasDefaultOutputDevice,
                    "No default output device available in this environment"))
    func defaultOutputDeviceIDMatchesMeasuredDevice() throws {
        let deviceID = try LocalOutputLatency.defaultOutputDeviceID()
        let measurement = try LocalOutputLatency.measure(deviceID: deviceID)
        #expect(measurement.nominalSampleRate > 0)
    }
    #else
    @Test(.disabled("AudioToolbox unavailable on this platform"))
    func measureReturnsPlausibleNonZeroLatency() throws {}

    @Test(.disabled("AudioToolbox unavailable on this platform"))
    func defaultOutputDeviceIDMatchesMeasuredDevice() throws {}
    #endif
}
