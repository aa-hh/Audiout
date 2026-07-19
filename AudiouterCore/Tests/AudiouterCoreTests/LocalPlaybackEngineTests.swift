// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import XCTest
@testable import AudiouterCore

/// Tests for ``LocalPlaybackEngine`` — specifically the per-app RMS metering
/// hook (T10, the Current-Device app-bar meter): ``LocalPlaybackEngine/onAppLevel``
/// + ``LocalPlaybackEngine/setMeteringActive(_:)``. These drive the REAL
/// `AVAudioEngine`-backed engine (no fake/spy — `LocalPlaybackControlling` is
/// what `NativeBackend` fakes in its own tests; this file tests the concrete
/// type those fakes stand in for), so `addApp`/`start` exercise real Core Audio
/// against the Mac's built-in output.
final class LocalPlaybackEngineTests: XCTestCase {

    /// Records every ``LocalPlaybackEngine/onAppLevel`` call under a lock — the
    /// closure is `@Sendable` (fired from `receive`'s thread), so a plain
    /// captured `var` is rejected by the compiler; mirrors `SpySink`/`SpyLocalPlayback`
    /// in the sibling capture-coordinator/backend test files.
    private final class LevelRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(bundleID: String, rms: Float)] = []
        func record(_ bundleID: String, _ rms: Float) { lock.withLock { calls.append((bundleID, rms)) } }
        var all: [(bundleID: String, rms: Float)] { lock.withLock { calls } }
        var count: Int { lock.withLock { calls.count } }
        var last: (bundleID: String, rms: Float)? { lock.withLock { calls.last } }
    }

    private let bundleID = "com.example.testapp"

    /// Real per-app taps are Float32 non-interleaved (planar) stereo — the same
    /// default every `SystemAudioTap`/`CoreAudioProcessTap` reports (see
    /// `NativeCaptureCoordinatorTests.buffer(hostTime:frames:)` and
    /// `PerAppCaptureCoordinator`'s tap description). `AVAudioFormat(standardFormatWithSampleRate:channels:)`
    /// (what `LocalPlaybackEngine.avFormat(from:)` builds the connection format
    /// with) is ALSO deinterleaved Float32 — so this tap format needs no
    /// converter, keeping the test buffer's samples exactly traceable through
    /// `receive(buffer:for:)` into the RMS computation.
    private let tapFormat = TapFormat(
        sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)

    /// A planar stereo Float32 buffer of `frames` samples per channel, every
    /// sample set to `amplitude` — so the expected RMS is exactly `abs(amplitude)`
    /// regardless of channel/frame count, independent of `rmsOfFloat32`'s own
    /// implementation (a black-box expectation, not a mirror of its code).
    private func constantBuffer(amplitude: Float, frames: Int = 16) -> CapturedBuffer {
        var channel = Data(capacity: frames * MemoryLayout<Float32>.size)
        for _ in 0..<frames {
            withUnsafeBytes(of: amplitude) { channel.append(contentsOf: $0) }
        }
        let pts = timespec(tv_sec: 0, tv_nsec: 0)
        return CapturedBuffer(channelData: [channel, channel], frameCount: frames, pts: pts)
    }

    /// Add `bundleID` as a real local player and start the engine. A helper so
    /// every test starts from the same known-good state; failures here would
    /// mean the environment has no usable audio output at all, not a T10 bug.
    private func makeStartedEngine() throws -> LocalPlaybackEngine {
        let engine = LocalPlaybackEngine()
        try engine.addApp(bundleID: bundleID, tapFormat: tapFormat, volume: 1.0)
        return engine
    }

    // MARK: - Metering active → fires

    func testMeteringActiveFiresOnAppLevelWithPlausibleRMS() throws {
        let engine = try makeStartedEngine()
        defer { engine.stop() }

        let recorder = LevelRecorder()
        engine.onAppLevel = { recorder.record($0, $1) }
        engine.setMeteringActive(true)

        engine.receive(buffer: constantBuffer(amplitude: 0.5), for: bundleID)

        let level = try XCTUnwrap(recorder.last, "onAppLevel must fire while metering is active")
        XCTAssertEqual(level.bundleID, bundleID)
        XCTAssertEqual(level.rms, 0.5, accuracy: 0.001,
                        "RMS of a constant 0.5 Float32 buffer must be ~0.5 — RAW captured level, " +
                        "not scaled by the player's volume (product decision: pre-volume metering)")
    }

    /// The pre-volume product decision, made concrete: a quiet player volume must
    /// NOT change the reported level for the identical captured buffer.
    func testRMSIsPreVolumeNotScaledByPlayerVolume() throws {
        let engine = try makeStartedEngine()
        defer { engine.stop() }
        engine.setVolume(0.1, for: bundleID)

        let recorder = LevelRecorder()
        engine.onAppLevel = { recorder.record($0, $1) }
        engine.setMeteringActive(true)

        engine.receive(buffer: constantBuffer(amplitude: 0.5), for: bundleID)

        let rms = try XCTUnwrap(recorder.last?.rms)
        XCTAssertEqual(rms, 0.5, accuracy: 0.001,
                        "a low player volume must not attenuate the reported RMS — it is the RAW tap level")
    }

    // MARK: - Metering inactive → does not fire

    func testMeteringInactiveDoesNotFireOnAppLevel() throws {
        let engine = try makeStartedEngine()
        defer { engine.stop() }

        let recorder = LevelRecorder()
        engine.onAppLevel = { recorder.record($0, $1) }
        // Metering defaults to off; never call setMeteringActive(true).

        engine.receive(buffer: constantBuffer(amplitude: 0.5), for: bundleID)

        XCTAssertEqual(recorder.count, 0, "onAppLevel must not fire while metering is inactive (default state)")
    }

    func testMeteringTurnedOffAfterBeingOnStopsFiring() throws {
        let engine = try makeStartedEngine()
        defer { engine.stop() }

        let recorder = LevelRecorder()
        engine.onAppLevel = { recorder.record($0, $1) }
        engine.setMeteringActive(true)
        engine.receive(buffer: constantBuffer(amplitude: 0.5), for: bundleID)
        XCTAssertEqual(recorder.count, 1)

        engine.setMeteringActive(false)
        engine.receive(buffer: constantBuffer(amplitude: 0.5), for: bundleID)
        XCTAssertEqual(recorder.count, 1, "flipping metering back off must stop further onAppLevel calls")
    }

    // MARK: - Unknown bundle ID / stopped engine → never fires

    func testUnknownBundleIDDoesNotFireOnAppLevelEvenWhileMeteringActive() throws {
        let engine = try makeStartedEngine()
        defer { engine.stop() }

        let recorder = LevelRecorder()
        engine.onAppLevel = { recorder.record($0, $1) }
        engine.setMeteringActive(true)

        engine.receive(buffer: constantBuffer(amplitude: 0.9), for: "com.example.unregistered")

        XCTAssertEqual(recorder.count, 0, "an unknown bundle ID must never fire onAppLevel, metering or not")
    }

    func testStoppedEngineDoesNotFireOnAppLevel() throws {
        let engine = try makeStartedEngine()
        let recorder = LevelRecorder()
        engine.onAppLevel = { recorder.record($0, $1) }
        engine.setMeteringActive(true)

        engine.stop()
        engine.receive(buffer: constantBuffer(amplitude: 0.9), for: bundleID)

        XCTAssertEqual(recorder.count, 0, "receive() after stop() must not fire onAppLevel (no node, engine not running)")
    }

    // MARK: - The hook does not disturb existing playback behavior

    /// Toggling metering on/off around normal `receive()` calls must not throw,
    /// crash, or otherwise perturb the existing scheduleBuffer path — the RMS
    /// pass is a side-read of the same buffer, never a gate on it.
    func testMeteringHookDoesNotDisturbNormalPlayback() throws {
        let engine = try makeStartedEngine()
        defer { engine.stop() }

        // Baseline: receive() with no listener at all (today's pre-T10 behavior).
        engine.receive(buffer: constantBuffer(amplitude: 0.3), for: bundleID)

        // With metering active and a listener installed.
        let recorder = LevelRecorder()
        engine.setMeteringActive(true)
        engine.onAppLevel = { recorder.record($0, $1) }
        engine.receive(buffer: constantBuffer(amplitude: 0.3), for: bundleID)

        // With metering turned back off, listener still installed.
        engine.setMeteringActive(false)
        engine.receive(buffer: constantBuffer(amplitude: 0.3), for: bundleID)

        // Volume/removeApp still behave normally after all the above.
        engine.setVolume(0.5, for: bundleID)
        engine.removeApp(bundleID: bundleID)

        // Re-adding after removal (idempotent add path) still works.
        try engine.addApp(bundleID: bundleID, tapFormat: tapFormat, volume: 1.0)
        engine.receive(buffer: constantBuffer(amplitude: 0.3), for: bundleID)
    }
}
