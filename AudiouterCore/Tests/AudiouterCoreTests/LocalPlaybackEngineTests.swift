// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import XCTest
@testable import AudiouterCore

#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// Tests for ``LocalPlaybackEngine`` — specifically the per-app RMS metering
/// hook (T10, the Current-Device app-bar meter): ``LocalPlaybackEngine/onAppLevel``
/// + ``LocalPlaybackEngine/setMeteringActive(_:)``. These drive the REAL
/// `AVAudioEngine`-backed engine (no fake/spy — `LocalPlaybackControlling` is
/// what `NativeBackend` fakes in its own tests; this file tests the concrete
/// type those fakes stand in for), so `addApp`/`start` exercise the real Core
/// Audio graph and the real RMS path.
///
/// The engine is created with `offlineRenderingForTests: true`, so it runs in
/// `AVAudioEngine`'s OFFLINE manual-rendering mode: the graph starts, players
/// schedule buffers, and the metering path fires exactly as in production — but
/// NO hardware is touched and no buffer reaches a speaker. That keeps the
/// full-suite run from clicking the Mac's built-in speakers mid live-session
/// (the metering assertions never needed real output — they read RMS off the
/// captured buffer). One opt-in test (`testRealEngineComesUpOnBuiltInOutput`,
/// gated behind `AUDIOUTER_LPE_REAL_OUTPUT=1`) keeps the real-hardware
/// integration smoke available on demand.
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

    /// Add `bundleID` as a local player and start the engine OFFLINE (no
    /// hardware). A helper so every test starts from the same known-good state;
    /// a failure here would mean the offline graph itself won't come up, not a
    /// T10 bug. Uses `offlineRenderingForTests: true` so the suite never grabs
    /// the audio device — the metering path under test reads RMS off the
    /// captured buffer and is identical whether output is real or offline.
    private func makeStartedEngine() throws -> LocalPlaybackEngine {
        let engine = LocalPlaybackEngine(offlineRenderingForTests: true)
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

    // MARK: - Real-hardware integration smoke (opt-in)

    /// OPT-IN: the only test that drives the engine against REAL Core Audio
    /// output (`offlineRenderingForTests: false`), verifying the production path
    /// actually comes up on the Mac's built-in device. Skipped unless
    /// `AUDIOUTER_LPE_REAL_OUTPUT=1` so a normal full-suite run — including the
    /// pre-commit gate during a live session — never touches the audio device.
    /// Feeds nothing but a single silent (zero-amplitude) buffer, so even when
    /// opted in it can't emit an audible tone.
    func testRealEngineComesUpOnBuiltInOutput() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AUDIOUTER_LPE_REAL_OUTPUT"] == "1",
            "Real-hardware smoke is opt-in (set AUDIOUTER_LPE_REAL_OUTPUT=1) — it touches the audio device")

        let engine = LocalPlaybackEngine()   // real output path
        try engine.addApp(bundleID: bundleID, tapFormat: tapFormat, volume: 1.0)
        defer { engine.stop() }

        // A zero buffer keeps it silent while still exercising the real schedule
        // path; the metering hook still reports the (zero) RMS, proving the real
        // graph runs end to end.
        let recorder = LevelRecorder()
        engine.onAppLevel = { recorder.record($0, $1) }
        engine.setMeteringActive(true)
        engine.receive(buffer: constantBuffer(amplitude: 0.0), for: bundleID)

        let level = try XCTUnwrap(recorder.last, "real engine must run so the metering path fires")
        XCTAssertEqual(level.rms, 0.0, accuracy: 0.001, "silent buffer reads as zero RMS")
    }

    // MARK: - Anti-feedback follow guard (transport type)

    #if canImport(AudioToolbox)

    /// Real local-hardware transports are FOLLOWED: "Current Device" plays out
    /// wherever the user is actually listening (built-in, Bluetooth headphones,
    /// USB, HDMI, Thunderbolt, …), which is the whole point of the bug fix.
    func testFollowableTransportsAreFollowed() {
        for transport in [
            kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeFireWire,
        ] {
            XCTAssertTrue(LocalPlaybackEngine.isFollowableTransport(transport),
                          "transport \(transport) is real local hardware — must be followed")
        }
    }

    /// The anti-feedback guard: AirPlay and virtual/aggregate defaults are REFUSED
    /// (local playback stays on the built-in speakers), because this app may be
    /// streaming the whole-system mix into exactly that device — following it would
    /// loop local playback back into the capture.
    func testFeedbackRiskTransportsAreRefused() {
        for transport in [
            kAudioDeviceTransportTypeAirPlay,
            kAudioDeviceTransportTypeVirtual,
            kAudioDeviceTransportTypeAggregate,
            kAudioDeviceTransportTypeAutoAggregate,
        ] {
            XCTAssertFalse(LocalPlaybackEngine.isFollowableTransport(transport),
                           "transport \(transport) is AirPlay/virtual — must be refused (anti-feedback)")
        }
    }

    /// An unreadable transport (`nil`) is treated conservatively as not-followable,
    /// so the safe built-in fallback is used rather than risking a feedback loop.
    func testUnreadableTransportIsNotFollowed() {
        XCTAssertFalse(LocalPlaybackEngine.isFollowableTransport(nil),
                       "an unreadable transport must fall back to the safe built-in target")
    }

    #endif
}
