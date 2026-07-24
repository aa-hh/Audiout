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

    // MARK: - Follow-real-output-with-guard (R13)

    /// A fake ``LocalOutputResolving`` so the follow-with-guard decision +
    /// compare-before-rebuild are assertable without any real Core Audio: the test
    /// dictates the "default output", the "built-in", and which ids are loop
    /// risks. `@unchecked Sendable` (mutated across the listener contract) with a
    /// lock, like the other fakes in this suite.
    private final class FakeOutputResolver: LocalOutputResolving, @unchecked Sendable {
        private let lock = NSLock()
        private var _defaultDevice: UInt32?
        private let _builtIn: UInt32?
        private let _loopRiskIDs: Set<UInt32>
        init(defaultDevice: UInt32?, builtIn: UInt32?, loopRiskIDs: Set<UInt32> = []) {
            self._defaultDevice = defaultDevice
            self._builtIn = builtIn
            self._loopRiskIDs = loopRiskIDs
        }
        func setDefaultDevice(_ id: UInt32?) { lock.withLock { _defaultDevice = id } }
        func defaultOutputDevice() -> UInt32? { lock.withLock { _defaultDevice } }
        func builtInOutputDevice() -> UInt32? { _builtIn }
        func isLoopRisk(_ device: UInt32) -> Bool { _loopRiskIDs.contains(device) }
    }

    private let builtInID: UInt32 = 1

    /// (a) Default = Bluetooth headphones (non-AirPlay, non-aggregate) → the engine
    /// FOLLOWS it. This is the R13 fix: a "Current Device" app must play where the
    /// user is actually listening, not blast out the built-in speakers.
    func testFollowsPlainDefaultOutput() {
        let bt: UInt32 = 42
        let resolver = FakeOutputResolver(defaultDevice: bt, builtIn: builtInID)
        let engine = LocalPlaybackEngine(outputResolver: resolver)
        XCTAssertEqual(engine.resolveTargetDeviceID(), bt,
                       "a plain (BT/USB/wired) default output must be followed")
    }

    /// (b) Default = an AirPlay-class device → the engine STAYS on built-in (loop
    /// guard). Following the AirPlay default would feed the whole-system AirPlay
    /// path back into playback in a loop.
    func testAirPlayDefaultFallsBackToBuiltIn() {
        let airplay: UInt32 = 99
        let resolver = FakeOutputResolver(defaultDevice: airplay, builtIn: builtInID, loopRiskIDs: [airplay])
        let engine = LocalPlaybackEngine(outputResolver: resolver)
        XCTAssertEqual(engine.resolveTargetDeviceID(), builtInID,
                       "an AirPlay-class default must fall back to built-in (loop guard)")
    }

    /// (c) Default = one of our OWN aggregate devices → the engine STAYS on
    /// built-in (loop guard).
    func testOwnAggregateDefaultFallsBackToBuiltIn() {
        let ourAggregate: UInt32 = 77
        let resolver = FakeOutputResolver(defaultDevice: ourAggregate, builtIn: builtInID, loopRiskIDs: [ourAggregate])
        let engine = LocalPlaybackEngine(outputResolver: resolver)
        XCTAssertEqual(engine.resolveTargetDeviceID(), builtInID,
                       "one of our own tap aggregates as the default must fall back to built-in (loop guard)")
    }

    /// When neither the default nor built-in resolves, the target is `nil` (the
    /// engine keeps `AVAudioEngine`'s own default — best effort).
    func testNoResolvableDeviceYieldsNilTarget() {
        let resolver = FakeOutputResolver(defaultDevice: nil, builtIn: nil)
        let engine = LocalPlaybackEngine(outputResolver: resolver)
        XCTAssertNil(engine.resolveTargetDeviceID())
    }

    /// The loop-guard name classification, tested against the EXACT names the app's
    /// three aggregate-creation sites build — so the prefix set can't silently
    /// drift out of sync with them, while ordinary output devices are never
    /// mistaken for ours.
    func testOwnAggregateNamePrefixesMatchRealCreationSiteNames() {
        let prefixes = LocalPlaybackEngine.ownAggregateNamePrefixes
        func isOurs(_ name: String) -> Bool { prefixes.contains { name.hasPrefix($0) } }
        // Exact names from NativeCaptureCoordinator / PerAppCaptureCoordinator /
        // AudioCapturePermissionProbe:
        XCTAssertTrue(isOurs("Tap-Audiouter"))
        XCTAssertTrue(isOurs("PerAppTap-Audiouter-com.example.app"))
        XCTAssertTrue(isOurs("SetupProbe-Audiouter"))
        // Ordinary hardware outputs must not be classified as ours:
        XCTAssertFalse(isOurs("MacBook Pro Speakers"))
        XCTAssertFalse(isOurs("External Headphones"))
        XCTAssertFalse(isOurs("Sonos Living Room"))
    }

    /// (d) The default output changes (BT connects) → the engine re-points exactly
    /// once; a follow-up notification whose resolved target is UNCHANGED does ZERO
    /// rebuilds (the compare-before-rebuild loop-breaker).
    func testDefaultOutputChangeRepointsOnceThenZeroOnUnchanged() throws {
        // Start with no resolvable device so the real engine boots on AVAudioEngine's
        // own default (no fake device id is ever actually applied to hardware).
        let resolver = FakeOutputResolver(defaultDevice: nil, builtIn: nil)
        let engine = LocalPlaybackEngine(outputResolver: resolver)
        try engine.addApp(bundleID: bundleID, tapFormat: tapFormat, volume: 1.0)
        defer { engine.stop() }
        XCTAssertNil(engine.test_configuredTargetDevice)
        XCTAssertEqual(engine.test_repointCount, 0)

        // BT connects: the default output now resolves to a new device.
        resolver.setDefaultDevice(200)
        engine.handleDefaultOutputChange()
        engine.test_flushGraphQueue()
        XCTAssertEqual(engine.test_repointCount, 1, "a changed default output must repoint exactly once")
        XCTAssertEqual(engine.test_configuredTargetDevice, 200)

        // A duplicate/spurious notification resolving to the SAME target: no work.
        // (Fired twice to be sure the guard is stable, not one-shot.)
        engine.handleDefaultOutputChange()
        engine.handleDefaultOutputChange()
        engine.test_flushGraphQueue()
        XCTAssertEqual(engine.test_repointCount, 1,
                       "an unchanged resolved target must do zero rebuilds (compare-before-rebuild)")
        XCTAssertEqual(engine.test_configuredTargetDevice, 200)
    }

    /// (e) An output config-change event (the "dies through mic" trigger: the mic
    /// engaging voice-processing mode stops `AVAudioEngine`) must REBUILD the graph
    /// and keep playing — not die. Proven by a buffer still scheduling + metering
    /// after the change.
    func testConfigurationChangeRebuildsInsteadOfDying() throws {
        let engine = try makeStartedEngine()
        defer { engine.stop() }
        let recorder = LevelRecorder()
        engine.onAppLevel = { recorder.record($0, $1) }
        engine.setMeteringActive(true)

        // Simulate the AVAudioEngineConfigurationChange the mic (or a device switch)
        // fires — the engine has stopped itself.
        engine.test_simulateConfigurationChange()

        // Playback survived: the node is still alive and engineRunning was restored,
        // so a captured buffer still schedules and meters.
        engine.receive(buffer: constantBuffer(amplitude: 0.5), for: bundleID)
        XCTAssertEqual(recorder.count, 1,
                       "receive() after a config change must still fire — the engine rebuilt, it did not die")
    }
}
