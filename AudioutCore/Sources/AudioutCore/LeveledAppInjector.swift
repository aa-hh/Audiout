// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation

#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// Sums a LEVELED app's own captured audio back into the whole-system mix at
/// that app's volume — the per-app volume slider for apps that are not
/// redirected anywhere.
///
/// ## What "leveled" means
/// An app on "No Redirect" whose volume is BELOW 100. At exactly 100 the app is
/// not leveled at all: it is not tapped, not excluded, not touched. Below 100 it
/// is tapped `.mutedWhenTapped` (so it is silent at its normal output and out of
/// the whole-system tap, exactly like a `.currentDevice` app) and its audio
/// re-enters the program HERE, scaled — so it keeps playing everywhere the
/// system mix goes, just quieter.
///
/// ## Where this sits
/// ```
/// PerAppCaptureCoordinator.onBuffer ──▶ handleBuffer ──▶ per-app FIFO ring
///                                                             │
///        NativeCaptureCoordinator.handleBuffer ──── mix(into:) ┘ (before Main Out EQ,
///                                                                before every fan-out)
/// ```
/// One injection point feeds the AirPlay engine, the synced-local sink, the
/// Bluetooth sinks and Cast identically — the same property the align tick
/// relies on. Leveled audio is PROGRAM material, so it goes in before the user's
/// Main Out tone stage (unlike the tick, which is deliberately after).
///
/// Sibling of ``AppRouteMixer`` and deliberately simpler: no destination-set
/// topology (there is one destination — the whole-system program) and no
/// presentation-time alignment.
///
/// razor: plain FIFO, no pts math. Both the per-app tap and the system tap run
/// off the same output device's clock, so their rates cannot drift apart and an
/// arrival-ordered queue is enough; a ring that runs dry contributes silence for
/// the missing frames. If alignment ever does matter (independently-clocked
/// sources), the upgrade is `AppRouteMixer`'s frame-indexed `MixTimeline`, not a
/// second alignment scheme here.
///
/// ## Threading
/// Configuration and per-app buffers are confined to `queue` (the
/// ``AppRouteMixer`` discipline). The rings are shared with the whole-system
/// tap's REAL-TIME delivery thread, so they live under their own short-held
/// `mixLock`, taken NON-blockingly (`try()`) on that thread: a contended read
/// drops one buffer's contribution rather than parking the audio thread — the
/// same shape ``LocalPlaybackEngine/receive(buffer:for:)`` and
/// ``NativeCaptureCoordinator/handleBuffer(_:)`` already use.
public final class LeveledAppInjector: @unchecked Sendable {

    /// Fired once per handled buffer, while metering is active, with the PRE-
    /// volume SOURCE RMS (0…1) of the app whose buffer was just handled — how
    /// loud that app is actually playing, NOT scaled by its volume slider (the
    /// meter shows the program level, not the attenuated output). Same contract
    /// as ``AppRouteMixer/onAppLevel``. Called on this injector's serial queue.
    public var onAppLevel: (@Sendable (_ bundleID: String, _ rms: Float) -> Void)?

    // MARK: Tunables

    /// The engine's fixed output format. All mixing happens in these units.
    private static let outputSampleRate = 44_100
    private static let outputChannels = 2

    /// Per-app ring depth: 250 ms of stereo samples. Deep enough to absorb the
    /// jitter between two taps' delivery cadences, shallow enough that a stalled
    /// system tap can never bank a noticeable lag; a full ring drops its OLDEST
    /// samples, so what plays is always the freshest audio.
    static let ringCapacitySamples = outputSampleRate / 4 * outputChannels

    // MARK: Injected dependency

    private let makeConverter: @Sendable (TapFormat) -> PCMConverting

    // MARK: State (confined to `queue`)

    private let queue = DispatchQueue(label: "LeveledAppInjector.state")

    /// bundleID → its route volume, 0…100. A bundle absent from this map is not
    /// leveled, and every other table is keyed the same way.
    private var volumeForBundle: [String: Int] = [:]

    /// bundleID → converter built from that app's captured `TapFormat` (learned
    /// via ``handleStateChange(bundleID:state:)``). A buffer for a bundle with no
    /// converter yet is dropped, as in ``AppRouteMixer``.
    private var converterForBundle: [String: PCMConverting] = [:]

    /// Whether PRE-volume source RMS should be computed and handed to
    /// ``onAppLevel``. `false` until a meter asks for it, so the common case
    /// costs nothing in the buffer path.
    private var meteringActive = false

    // MARK: State shared with the real-time mix path (`mixLock`)

    /// Guards ONLY `rings` and `active` — the two things the whole-system tap's
    /// delivery thread reads. Critical sections are a bounded sample copy and
    /// nothing else: never a Core Audio call, never a wait on `queue`.
    private let mixLock = NSLock()

    /// bundleID → its pending audio, already converted and volume-scaled.
    private var rings: [String: SampleRing] = [:]

    /// Whether the whole-system capture is running. While false there is nobody
    /// to mix into — the leveled app renders locally instead
    /// (`LocalPlaybackEngine`), so accumulating here would only bank stale audio
    /// for the next start.
    private var active = false

    // MARK: Diagnostic counters

    /// Where the leveled path is losing audio, counted rather than guessed. All
    /// are monotonic since the last ``takeDiagnostics()``; the RT-thread ones are
    /// touched only while `mixLock` is already held, so they cost nothing extra.
    struct Diagnostics {
        var mixCalls = 0
        var mixInactive = 0
        var mixNoRings = 0
        var samplesMixed = 0
        var buffersIn = 0
        var droppedInactive = 0
        var droppedNotLeveled = 0
        var droppedNoConverter = 0
        var droppedConvertFailed = 0
        var pendingSamples = 0
        var ringCount = 0
        var isActive = false
    }

    private var diag = Diagnostics()

    /// The write-side counters, confined to `queue` like every other field the
    /// buffer path touches. Deliberately NOT under `mixLock`: counting a dropped
    /// buffer must not lengthen the critical section the real-time `mix(into:)`
    /// is trying to take, or the instrument starts causing the contention it is
    /// there to measure.
    private var buffersIn = 0
    private var droppedInactive = 0
    private var droppedNotLeveled = 0
    private var droppedNoConverter = 0
    private var droppedConvertFailed = 0

    /// Read the counters and reset them. Called off the audio thread (the 5 s
    /// telemetry poll), under `mixLock` so the RT increments are not torn.
    func takeDiagnostics() -> Diagnostics {
        queue.sync {
            mixLock.lock()
            var out = diag
            out.isActive = active
            out.ringCount = rings.count
            out.pendingSamples = rings.values.reduce(0) { $0 + $1.count }
            diag = Diagnostics()
            mixLock.unlock()

            out.buffersIn = buffersIn
            out.droppedInactive = droppedInactive
            out.droppedNotLeveled = droppedNotLeveled
            out.droppedNoConverter = droppedNoConverter
            out.droppedConvertFailed = droppedConvertFailed
            buffersIn = 0
            droppedInactive = 0
            droppedNotLeveled = 0
            droppedNoConverter = 0
            droppedConvertFailed = 0
            return out
        }
    }

    // MARK: Init

    /// Injectable initializer. Production supplies an `AVFormatConverter`
    /// factory via ``init()``; tests inject a trivial converter so the sample
    /// math runs without AVFoundation.
    init(makeConverter: @escaping @Sendable (TapFormat) -> PCMConverting) {
        self.makeConverter = makeConverter
    }

    #if canImport(AudioToolbox)
    /// Production initializer: the same `AVFormatConverter` both taps use, to
    /// bring each app's tap-native buffers into the engine's S16LE / 44100 / 2ch
    /// format before summing.
    public convenience init() {
        self.init(makeConverter: { format in AVFormatConverter(from: format) })
    }
    #endif

    // MARK: Configuration

    /// Replace the leveled table with `apps` (bundle id + 0…100 volume) and
    /// refresh every volume. An app that drops out loses its ring and its
    /// converter; a new one gets an empty ring.
    public func updateLeveled(_ apps: [(bundleID: String, volume: Int)]) {
        queue.sync {
            volumeForBundle = Dictionary(
                apps.map { ($0.bundleID, $0.volume) }, uniquingKeysWith: { _, new in new })
            let live = Set(volumeForBundle.keys)
            for bundleID in converterForBundle.keys where !live.contains(bundleID) {
                converterForBundle.removeValue(forKey: bundleID)
            }
            mixLock.lock()
            for bundleID in rings.keys where !live.contains(bundleID) {
                rings.removeValue(forKey: bundleID)
            }
            for bundleID in live where rings[bundleID] == nil {
                rings[bundleID] = SampleRing(capacity: Self.ringCapacitySamples)
            }
            mixLock.unlock()
        }
    }

    /// Low-latency volume update — the popover slider's drag path, which must not
    /// wait on a route-table round trip. A no-op for a bundle that isn't leveled.
    public func setVolume(_ volume: Int, for bundleID: String) {
        queue.async {
            guard self.volumeForBundle[bundleID] != nil else { return }
            self.volumeForBundle[bundleID] = volume
        }
    }

    /// Follow the whole-system capture gate. Every ring is emptied on a genuine
    /// flip: audio captured while nothing was mixing is stale by the time the
    /// gate opens, and audio left behind when it closes would replay minutes
    /// later. Same-value calls are ignored, so a route edit mid-stream never
    /// drops the pending audio.
    public func setActive(_ active: Bool) {
        queue.sync {
            mixLock.lock()
            defer { mixLock.unlock() }
            guard self.active != active else { return }
            self.active = active
            for ring in rings.values { ring.clear() }
        }
    }

    /// Gate per-app RMS computation/emission on or off. Independent of routing
    /// and capture, exactly like ``AppRouteMixer/setMeteringActive(_:)``.
    public func setMeteringActive(_ active: Bool) {
        queue.async { self.meteringActive = active }
    }

    // MARK: Capture wiring

    /// Observe a per-app tap's state so the injector learns each app's real
    /// captured ``TapFormat`` (only available on the `.capturing` transition) and
    /// can build the right converter; any other state drops it.
    public func handleStateChange(bundleID: String, state: PerAppCaptureCoordinator.State) {
        queue.sync {
            switch state {
            case .capturing(let format):
                converterForBundle[bundleID] = makeConverter(format)
            case .idle, .resolvingProcess, .creatingTap, .stopping, .failed:
                converterForBundle.removeValue(forKey: bundleID)
            }
        }
    }

    /// Feed one captured buffer for `bundleID` into its ring. Dropped (silently,
    /// correctly) when the injector is inactive, the app isn't leveled, it has no
    /// converter yet, or the buffer can't be converted. Otherwise: convert to
    /// S16LE/44100/2ch, scale by the app's volume, append. Called from the
    /// per-app tap's delivery thread; hops to `queue` like ``AppRouteMixer``.
    public func handleBuffer(bundleID: String, buffer: CapturedBuffer) {
        let level: Float? = queue.sync {
            mixLock.lock()
            let isActive = active
            mixLock.unlock()
            guard isActive else { droppedInactive += 1; return nil }
            guard let volume = volumeForBundle[bundleID] else {
                droppedNotLeveled += 1; return nil
            }
            guard let converter = converterForBundle[bundleID] else {
                droppedNoConverter += 1; return nil
            }
            guard let pcm = converter.convertToAirPlayPCM(buffer), !pcm.isEmpty else {
                droppedConvertFailed += 1; return nil
            }

            let scaled = AppRouteMixer.scaledStereoSamples(pcm, volumePercent: volume)
            guard !scaled.isEmpty else {
                droppedConvertFailed += 1; return nil
            }
            buffersIn += 1
            mixLock.lock()
            rings[bundleID]?.write(scaled)
            mixLock.unlock()
            // The meter is a SOURCE/program level: RMS the PRE-volume converted
            // buffer, so the bar reflects how loud the app is actually playing
            // rather than how far its slider is pulled down.
            return meteringActive ? NativeCaptureCoordinator.rmsOfS16LE(pcm) : nil
        }
        if let level { onAppLevel?(bundleID, level) }
    }

    // MARK: The real-time mix

    /// Sum every leveled app's pending audio onto `pcm` (interleaved S16LE
    /// stereo, `frameCount` frames), clipping each summed sample.
    ///
    /// REAL-TIME THREAD — the whole-system tap's delivery thread. It takes
    /// `mixLock` non-blockingly and gives up on a miss: one buffer without the
    /// leveled apps is strictly better than parking the audio thread behind a
    /// descheduled writer. A ring with fewer samples than asked for contributes
    /// silence for the remainder.
    public func mix(into pcm: inout Data, frameCount: Int) {
        guard frameCount > 0 else { return }
        // razor: a try-miss is deliberately NOT counted here — the only way to
        // record it is to take the very lock that just refused, which fails again
        // and reports a flat zero however bad contention gets. Derive misses
        // instead: the whole-system tap calls this exactly once per delivered
        // buffer, so `mix_calls` short of the coordinator's delivered count IS
        // the miss count.
        guard mixLock.try() else { return }
        defer { mixLock.unlock() }
        diag.mixCalls += 1
        guard active else { diag.mixInactive += 1; return }
        guard !rings.isEmpty else { diag.mixNoRings += 1; return }
        let sampleCount = Swift.min(frameCount * Self.outputChannels, pcm.count / 2)
        guard sampleCount > 0 else { return }
        var mixed = 0
        pcm.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for ring in rings.values {
                ring.read(sampleCount) { index, sample in
                    samples[index] = AppRouteMixer.clip(Int32(samples[index]) + Int32(sample))
                    mixed += 1
                }
            }
        }
        diag.samplesMixed += mixed
    }

    /// Whether any leveled app has audio waiting to be mixed. Read by the
    /// whole-system coordinator's fallback clock to decide whether it must
    /// produce a carrier block: the injector can only ADD to a block somebody
    /// else emits, so when the tap that normally emits them falls silent this is
    /// the only thing that says "there is audio here going nowhere".
    var hasPendingAudio: Bool {
        mixLock.lock(); defer { mixLock.unlock() }
        guard active else { return false }
        return rings.values.contains { $0.count > 0 }
    }

    // MARK: Test seams (pure reads)

    /// How many samples are currently banked for `bundleID` (0 when it has no
    /// ring at all).
    func test_pendingSamples(for bundleID: String) -> Int {
        mixLock.lock(); defer { mixLock.unlock() }
        return rings[bundleID]?.count ?? 0
    }

    /// Whether `bundleID` currently has a ring (i.e. is in the leveled table).
    func test_hasRing(for bundleID: String) -> Bool {
        mixLock.lock(); defer { mixLock.unlock() }
        return rings[bundleID] != nil
    }

    /// Whether `bundleID` currently has a converter (dropped on removal and on
    /// any non-capturing state).
    func test_hasConverter(for bundleID: String) -> Bool {
        queue.sync { converterForBundle[bundleID] != nil }
    }
}

// MARK: - Per-app FIFO ring

/// A fixed-capacity circular buffer of interleaved S16LE stereo samples. Written
/// from ``LeveledAppInjector``'s serial queue, read from the whole-system tap's
/// real-time thread, both under `mixLock` — so it allocates ONCE, at init, and
/// never again.
private final class SampleRing {
    private var storage: [Int16]
    /// Index of the oldest pending sample.
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = [Int16](repeating: 0, count: Swift.max(1, capacity))
    }

    func clear() {
        head = 0
        count = 0
    }

    /// Append volume-scaled samples, dropping the OLDEST on overflow — a
    /// stalled reader must cost freshness, never unbounded memory or a growing
    /// lag.
    func write(_ samples: [Int32]) {
        let capacity = storage.count
        for sample in samples {
            if count == capacity {
                storage[head] = Int16(clamping: sample)
                head = (head + 1) % capacity
            } else {
                storage[(head + count) % capacity] = Int16(clamping: sample)
                count += 1
            }
        }
    }

    /// Pop up to `n` samples, handing each to `consume` with its index in the
    /// output block. Fewer than `n` available simply means the tail of the block
    /// gets nothing from this app (silence), which is the correct thing to hear.
    func read(_ n: Int, _ consume: (Int, Int16) -> Void) {
        let capacity = storage.count
        let take = Swift.min(n, count)
        for i in 0..<take {
            consume(i, storage[(head + i) % capacity])
        }
        head = (head + take) % capacity
        count -= take
    }
}
