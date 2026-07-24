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

    // MARK: - Memory leak: orphaned player node on engine start failure

    /// When ``startEngineOnGraphQueue()`` throws (e.g., during device config
    /// churn), the freshly-attached player node MUST be detached — not orphaned
    /// in the engine's graph. This test forces a start failure via the
    /// `test_startOverride` seam and verifies the error is re-thrown.
    func testAddAppDetachesPlayerOnStartFailure() throws {
        // Reference engine: a normal, successful add-then-remove. This tells us
        // what "internal engine bookkeeping only, zero app players" looks like
        // as an attached-node COUNT, without guessing at AVAudioEngine's own
        // lazy mixer/output-node creation (which `startEngineOnGraphQueue()`
        // triggers via `_ = engine.mainMixerNode` BEFORE it ever calls
        // `engine.start()` — so that internal setup happens identically whether
        // start succeeds or fails, and a bare pre-`addApp` baseline of 0 does
        // NOT account for it). `removeApp` only ever detaches the app's own
        // player (verified by reading its body), never the engine's own nodes,
        // so this is a clean "player added, then correctly removed" reference.
        let referenceEngine = LocalPlaybackEngine()
        try referenceEngine.addApp(bundleID: bundleID, tapFormat: tapFormat, volume: 1.0)
        referenceEngine.removeApp(bundleID: bundleID)
        let noOrphanNodeCount = referenceEngine.test_attachedNodeCount

        let engine = LocalPlaybackEngine()

        // Force engine.start() to throw via the test seam.
        struct TestError: Error { let message: String }
        let testError = TestError(message: "test override")
        engine.test_startOverride = {
            throw testError
        }

        // Attempt to add an app — this should throw when start fails.
        var errorThrown = false
        do {
            try engine.addApp(bundleID: bundleID, tapFormat: tapFormat, volume: 1.0)
        } catch is TestError {
            errorThrown = true
        } catch {
            XCTFail("Expected TestError, got \(type(of: error)): \(error)")
        }

        XCTAssertTrue(errorThrown, "addApp must throw when engine start fails")

        // DIRECT proof of the fix: after a failed start, the attached-node count
        // must match the "no orphan" reference exactly. `addApp`'s idempotency
        // guard (`nodes[bundleID]`) never got populated by the failed call, so a
        // second `addApp` for the same bundle ID would attach a brand-new,
        // independently-tracked player node regardless of whether the first one
        // was ever cleaned up — a "second call succeeds" check alone would pass
        // even with the leak present (confirmed: the delta between a failed and
        // a subsequent successful call is always +1 either way). Comparing
        // against the engine's real attached-node count is what actually rules
        // out the orphan.
        XCTAssertEqual(engine.test_attachedNodeCount, noOrphanNodeCount,
                       "a failed engine start must leave no orphaned player node attached")

        // Secondary check: a retry with the override cleared should also work
        // end-to-end (proves the failed attempt left no stale bookkeeping either).
        engine.test_startOverride = nil
        try engine.addApp(bundleID: bundleID, tapFormat: tapFormat, volume: 1.0)
        engine.stop()  // Clean up
        referenceEngine.stop()
    }

    // MARK: - Config-change debounce (redirect-churn burst coalescing)

    /// A burst of `AVAudioEngineConfigurationChange` notifications (redirect
    /// churn — routing/unrouting several apps in quick succession, each
    /// creating/destroying its own Core Audio tap+aggregate device) must
    /// collapse into exactly ONE call to the reconnect handler, not one per
    /// notification. Drives ``LocalPlaybackEngine/test_triggerConfigChangeDebounce()``
    /// — the same trailing-edge debounce path `init`'s real observer closure
    /// uses — three times a few ms apart (a real notification burst is at
    /// least this tight: several taps torn down/created back-to-back on the
    /// same churn event), then proves via
    /// ``LocalPlaybackEngine/test_configChangeHandlerFireCount`` (a plain
    /// counter, not real engine/playback state — this test only needs to prove
    /// coalescing, not exercise the reconnect sequence itself) that the
    /// handler fired once, and only after settling. No `addApp` is called, so
    /// `nodes` stays empty and the real handler takes its early-return branch
    /// (`engineRunning = false`) — no Core Audio interaction, no audio, on a
    /// worker thread that reads real hardware.
    func testConfigChangeBurstCoalescesIntoOneHandlerCall() throws {
        let engine = LocalPlaybackEngine()
        defer { engine.stop() }

        engine.test_triggerConfigChangeDebounce()
        Thread.sleep(forTimeInterval: 0.01)
        engine.test_triggerConfigChangeDebounce()
        Thread.sleep(forTimeInterval: 0.01)
        engine.test_triggerConfigChangeDebounce()

        XCTAssertEqual(engine.test_configChangeHandlerFireCount, 0,
                       "the handler must not have fired yet — still inside the ~300ms debounce window")

        // Wait past the debounce interval (300ms) with margin, then check.
        let settled = XCTestExpectation(description: "debounce settles")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)

        XCTAssertEqual(engine.test_configChangeHandlerFireCount, 1,
                       "a burst of 3 rapid notifications must collapse into exactly ONE handler call")
    }

    /// The debounce must not weaken responsiveness for the common case: ONE
    /// isolated config-change notification (not part of a burst) still
    /// recovers — the handler still fires — after roughly the debounce
    /// interval. Guards against a broken implementation that only fires on a
    /// SUBSEQUENT notification (a true "N-th event" throttle) rather than
    /// timing off the single call actually made.
    func testSingleConfigChangeStillFiresHandlerAfterDebounceInterval() throws {
        let engine = LocalPlaybackEngine()
        defer { engine.stop() }

        engine.test_triggerConfigChangeDebounce()

        let settled = XCTestExpectation(description: "single debounce settles")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)

        XCTAssertEqual(engine.test_configChangeHandlerFireCount, 1,
                       "a single, isolated notification must still recover on its own — the debounce " +
                       "delays and coalesces, it must never indefinitely postpone recovery")
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
