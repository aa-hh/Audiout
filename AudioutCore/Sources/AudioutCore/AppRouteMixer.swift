// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation

#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// Combines the individually-captured audio of per-app-routed apps into the
/// mixed stream(s) that actually reach the AirPlay destinations, applying each
/// app's own volume for the first time (T5).
///
/// ## Where this sits in the pipeline
/// ```
/// AppRoutingController.appRoutes ──updateRoutes──▶ ┌──────────────┐
///                                                  │              │──onDestinationSetsChanged──▶ T6
/// PerAppCaptureCoordinator.onStateChange ─────────▶│ AppRouteMixer│
/// PerAppCaptureCoordinator.onBuffer ──────────────▶│              │──onMixedBuffer──▶ T6
///                                                  └──────────────┘
/// ```
/// T6 delivers each mixed buffer to whichever destinations that stream actually
/// has: the AirPlay engine (`engine.write(pcm:streamId:pts:)`) for its
/// engine-bound devices, and the Bluetooth sink manager for the speakers on it
/// that render through their own delay lines. One stream can have both, and gets
/// both.
///
/// The mixer consumes only apps the backend resolved to at least one live
/// speaker — a `.device(id:)` route, or a `.group(id:)` route's surviving
/// members. Apps on `.noRedirect` OR
/// `.currentDevice` (both "plays locally" — see `AppRouteDestination`'s doc)
/// never appear in its input and never appear in its output. The whole-system
/// "Selected Devices" mix (stream_id 0, produced by the existing
/// ``NativeCaptureCoordinator`` and trimmed by T4) is a wholly separate stream
/// the mixer knows nothing about — its stream_ids start at 1.
///
/// ## Two responsibilities, both pure computation
/// 1. **Destination-set topology.** From the current routes it derives which
///    devices share a mixed stream: devices fed the *exact same* apps at the
///    *exact same* gains are fed one stream (saves redundant encoding), and
///    each distinct non-empty signature gets a stable `stream_id`. See
///    ``updateRoutes(_:)``.
/// 2. **Buffer mixing.** Per-app captured buffers are converted to the engine's
///    one accepted PCM format (S16LE / 44100 / 2ch), scaled by the app's own
///    gain on that stream, summed onto a shared frame-indexed timeline per stream (so
///    independently-clocked taps line up by presentation time, not arrival
///    order), clipped, and emitted. See ``handleBuffer(bundleID:buffer:)``.
///
/// ## No Core Audio / engine calls live here
/// The only format-dependent step (resample + Float→Int16 + interleave) is
/// delegated to an injected ``PCMConverting`` (production wires the same
/// `AVFormatConverter` the system tap uses; tests inject a trivial one). Nothing
/// in this file touches Core Audio, AVFoundation, or the engine directly, so the
/// whole mixer — topology math AND sample math — runs hermetically under test.
public final class AppRouteMixer: @unchecked Sendable {

    // MARK: Output types

    /// One app summed into a stream, at the gain its audio is mixed at there.
    /// The gain is part of the identity because two speakers fed the same apps
    /// at DIFFERENT levels (a group whose members carry different per-speaker
    /// levels) cannot share one mixed buffer.
    public struct Contributor: Hashable, Sendable {
        public let bundleID: String
        /// 0–100 — see ``AppRouteMixer/composedGain(routeVolume:memberVolume:)``.
        public let gain: Int

        public init(bundleID: String, gain: Int) {
            self.bundleID = bundleID
            self.gain = gain
        }
    }

    /// One mixed stream and everything the backend coordinator (T6) needs to
    /// route it: its `streamID`, the apps summed into it with their gains (the
    /// membership signature), and the device IDs it must be sent to (one stream,
    /// possibly several devices fed identically).
    public struct DestinationSet: Equatable, Sendable {
        /// Stable per-signature stream id, ≥ 1 (0 is reserved for the legacy
        /// whole-system path). Stays constant while this exact app-set persists.
        public let streamID: Int
        /// The apps whose audio is summed into this stream, each with the gain
        /// it is mixed at. This set is the signature that keys ``streamID``
        /// stability.
        public let contributors: Set<Contributor>
        /// Every device that receives this stream (all fed the same apps at the
        /// same gains, so they get one encode instead of one each).
        public let deviceIDs: Set<String>

        /// The bundle IDs summed into this stream, gains dropped — what the
        /// `.routedApps` UI signal names.
        public var bundleIDs: Set<String> { Set(contributors.map(\.bundleID)) }

        public init(streamID: Int, contributors: Set<Contributor>, deviceIDs: Set<String>) {
            self.streamID = streamID
            self.contributors = contributors
            self.deviceIDs = deviceIDs
        }

        /// Convenience for the plain full-volume case: every app mixed at 100.
        public init(streamID: Int, bundleIDs: Set<String>, deviceIDs: Set<String>) {
            self.init(streamID: streamID,
                      contributors: Set(bundleIDs.map { Contributor(bundleID: $0, gain: 100) }),
                      deviceIDs: deviceIDs)
        }
    }

    /// One app's routing as the mixer consumes it: which devices its audio goes
    /// to, and at what gain on each. Built by the backend, which is the layer
    /// that knows whether a route names one device or a whole saved group and
    /// which of those speakers are actually available right now.
    public struct RoutedApp: Equatable, Sendable {
        public let bundleID: String
        /// device id → 0–100 gain. Empty means "not routed anywhere" and is
        /// simply ignored.
        public let deviceGains: [String: Int]

        public init(bundleID: String, deviceGains: [String: Int]) {
            self.bundleID = bundleID
            self.deviceGains = deviceGains
        }
    }

    /// One block of finished mixed PCM for a stream: interleaved S16LE / 44100 /
    /// 2ch (``AirPlayEngine.PCMFormat.airplay``), tagged with the `streamID` it
    /// belongs to and the presentation timestamp of its first frame. T6 hands
    /// `pcm`/`pts` straight to `engine.write(pcm:streamId:pts:)`.
    public struct MixedBuffer: Sendable {
        public let streamID: Int
        public let pcm: Data
        public let frameCount: Int
        public let pts: timespec

        public init(streamID: Int, pcm: Data, frameCount: Int, pts: timespec) {
            self.streamID = streamID
            self.pcm = pcm
            self.frameCount = frameCount
            self.pts = pts
        }
    }

    // MARK: Callbacks (T6's consumption seam)

    /// Fired whenever the destination-set topology changes (an app's route
    /// changed the set of distinct streams, or a stream's device membership
    /// changed). NOT fired for volume-only changes or for route edits that
    /// leave the distinct app-sets identical. Called on the mixer's serial
    /// queue.
    public var onDestinationSetsChanged: (@Sendable ([DestinationSet]) -> Void)?

    /// Fired for each finished mixed buffer, tagged with its `streamID`. Called
    /// on the mixer's serial queue.
    public var onMixedBuffer: (@Sendable (MixedBuffer) -> Void)?

    /// Fired once per handled buffer, while metering is active, with the PRE-
    /// volume SOURCE RMS (0…1) of the ONE app whose buffer was just handled — how
    /// loud that app is actually playing, NOT scaled by its routing-volume slider
    /// (the meter shows the program level, not the attenuated output). Not the
    /// summed mix. Called on the mixer's serial queue. See ``setMeteringActive(_:)``.
    public var onAppLevel: (@Sendable (_ bundleID: String, _ rms: Float) -> Void)?

    // MARK: Tunables

    /// The engine's fixed output format. All mixing happens in these units.
    private static let outputSampleRate = 44100
    private static let outputChannels = 2

    /// How long a frame is held on the timeline before it is emitted, giving a
    /// slightly-late member tap time to add its contribution for the same
    /// presentation instant. 10 ms ≫ the sub-millisecond jitter between two
    /// taps rebased onto the same CLOCK_MONOTONIC clock, yet negligible latency.
    /// A member that lags by more than this drops its late frames (rare; same
    /// class of accepted trade-off as the ~1 s reconnect on a set change).
    private static let holdFrames: Int64 = 441

    /// Hard cap on a single stream's pending timeline (1 s). A tap that races
    /// far ahead in presentation time (clock glitch) can't grow the accumulator
    /// unbounded; the ready prefix is force-flushed instead.
    private static let maxPendingFrames: Int64 = Int64(outputSampleRate)

    // MARK: Injected dependency

    private let makeConverter: @Sendable (TapFormat) -> PCMConverting

    // MARK: State (confined to `queue`)

    private let queue = DispatchQueue(label: "AppRouteMixer.state")

    /// Monotonic stream-id allocator. IDs are never reused: a signature that
    /// vanishes doesn't free its id, so a genuinely-different app-set can never
    /// silently inherit a prior set's id (which would hide a membership change
    /// from T6, defeating the reconnect it must trigger). The engine's stream_id
    /// is a free-form `UInt32` device tag with no fixed capacity, so monotonic
    /// growth is safe. Starts at 1 (0 is the reserved legacy whole-system id).
    private var nextStreamID = 1

    /// Current published topology. Also the id-reuse table
    /// (``assignStreamIDs(_:)`` matches new sets against it).
    private var currentSets: [DestinationSet] = []

    /// bundleID → (stream it feeds → the gain it is mixed at there). One app can
    /// feed SEVERAL streams: a group route whose members carry different levels
    /// splits into one stream per distinct gain.
    private var streamGainsForBundle: [String: [Int: Int]] = [:]

    /// bundleID → converter built from that app's captured `TapFormat` (learned
    /// via ``handleStateChange(bundleID:state:)``). A buffer for a bundle with
    /// no converter yet is dropped (the first frames at startup, before the
    /// `.capturing(format)` transition lands).
    private var converterForBundle: [String: PCMConverting] = [:]

    /// streamID → its running mix timeline.
    private var timelines: [Int: MixTimeline] = [:]

    /// Whether per-app PRE-volume source RMS should be computed and handed to
    /// ``onAppLevel`` (T2 — the per-app-routed meter). `false` until
    /// ``setMeteringActive(_:)`` first flips it on, so the common case (no
    /// meter shown) costs nothing extra in the mixing hot path. Confined to
    /// `queue`, same as every other piece of state here.
    private var meteringActive = false

    // MARK: Init

    /// Injectable initializer. Production supplies an `AVFormatConverter`
    /// factory via ``init(name:)``; tests inject a trivial converter so the
    /// sample math runs without AVFoundation.
    init(makeConverter: @escaping @Sendable (TapFormat) -> PCMConverting) {
        self.makeConverter = makeConverter
    }

    #if canImport(AudioToolbox)
    /// Production initializer: wires the same `AVFormatConverter` the system tap
    /// uses to bring each app's tap-native buffers into the engine's S16LE /
    /// 44100 / 2ch format before summing.
    public convenience init(name: String = "AirPlayController") {
        self.init(makeConverter: { format in AVFormatConverter(from: format) })
    }
    #endif

    // MARK: Topology

    /// The current destination sets (thread-safe snapshot).
    public var destinationSets: [DestinationSet] {
        queue.sync { currentSets }
    }

    /// The streams a bundle currently feeds — empty if it isn't routed to any
    /// device (i.e. it's on `.noRedirect`/`.currentDevice`, or unknown). More
    /// than one when a routed group's members carry different levels.
    public func streamIDs(for bundleID: String) -> [Int] {
        queue.sync { streamGainsForBundle[bundleID].map { $0.keys.sorted() } ?? [] }
    }

    /// The gain one app's audio is mixed at on ONE speaker: the app's own route
    /// slider scaled by that speaker's level inside the group the app is routed
    /// to (100 — no change — for a plain single-device route). THE one place the
    /// two levels compose; the group's own master volume deliberately does not
    /// apply, because the app's slider is the master for the app's own stream.
    public static func composedGain(routeVolume: Int, memberVolume: Int) -> Int {
        let route = routeVolume.clampedToVolume
        let member = memberVolume.clampedToVolume
        return member == 100 ? route : (route * member + 50) / 100
    }

    /// Recompute the destination-set topology from the apps' resolved targets.
    /// Fires ``onDestinationSetsChanged`` iff the published topology actually
    /// changed — which now includes a gain-only change, since the gain is what
    /// each stream is mixed at.
    public func updateRoutes(_ routed: [RoutedApp]) {
        let changed: [DestinationSet]? = queue.sync {
            // deviceID -> the apps it is fed, each with its gain on THIS device.
            var appsByDevice: [String: Set<Contributor>] = [:]
            for app in routed {
                for (deviceID, gain) in app.deviceGains {
                    appsByDevice[deviceID, default: []]
                        .insert(Contributor(bundleID: app.bundleID, gain: gain))
                }
            }

            // Group devices by identical app-set AND gains (the signature):
            // anything short of identical can't share one mixed buffer.
            var devicesBySignature: [Set<Contributor>: Set<String>] = [:]
            for (deviceID, apps) in appsByDevice where !apps.isEmpty {
                devicesBySignature[apps, default: []].insert(deviceID)
            }

            let newSets = assignStreamIDs(devicesBySignature)

            // Rebuild bundle -> (stream, gain) map from the fresh topology.
            var newStreamGains: [String: [Int: Int]] = [:]
            for set in newSets {
                for contributor in set.contributors {
                    newStreamGains[contributor.bundleID, default: [:]][set.streamID] = contributor.gain
                }
            }
            streamGainsForBundle = newStreamGains

            // Drop timelines for streams that no longer exist.
            let liveStreamIDs = Set(newSets.map { $0.streamID })
            for streamID in timelines.keys where !liveStreamIDs.contains(streamID) {
                timelines.removeValue(forKey: streamID)
            }

            guard newSets != currentSets else { return nil }
            currentSets = newSets
            return newSets
        }
        if let changed { onDestinationSetsChanged?(changed) }
    }

    /// Assign a stream id to each signature, reusing the published id wherever
    /// the stream is recognisably the same one so the backend's binding diff
    /// stays empty and no receiver is needlessly rebound. A signature matches a
    /// published set when it holds the same apps AND either the same gains (the
    /// ordinary case, including a device joining or leaving the stream) or an
    /// overlapping device set (a pure gain edit — a group member's level moved,
    /// which is a mixer change, not a topology change). Anything else is a
    /// genuinely different stream and takes the next monotonic id; vanished ids
    /// are never recycled (see ``nextStreamID``), so a changed app-set can never
    /// silently inherit a prior set's id and hide the reconnect it must trigger.
    /// Deterministic (signatures ordered by their sorted contents) so a given
    /// topology always yields the same assignment. MUST hold `queue`.
    private func assignStreamIDs(_ devicesBySignature: [Set<Contributor>: Set<String>]) -> [DestinationSet] {
        let signatures = devicesBySignature.keys.sorted { Self.sortKey($0) < Self.sortKey($1) }
        var reusable = currentSets
        var assigned: [DestinationSet] = []

        func take(_ index: Int) -> Int {
            reusable.remove(at: index).streamID   // one published id, claimed once
        }

        for signature in signatures {
            let devices = devicesBySignature[signature]!
            let bundleIDs = Set(signature.map(\.bundleID))
            let streamID: Int
            if let i = reusable.firstIndex(where: { $0.contributors == signature }) {
                streamID = take(i)
            } else if let i = reusable.firstIndex(where: {
                $0.bundleIDs == bundleIDs && !$0.deviceIDs.isDisjoint(with: devices)
            }) {
                streamID = take(i)
            } else {
                streamID = nextStreamID
                nextStreamID += 1
            }
            assigned.append(DestinationSet(
                streamID: streamID, contributors: signature, deviceIDs: devices))
        }
        return assigned.sorted { $0.streamID < $1.streamID }
    }

    /// A signature's deterministic ordering key — sorted `bundle@gain` pairs.
    private static func sortKey(_ signature: Set<Contributor>) -> String {
        signature.map { "\($0.bundleID)@\($0.gain)" }.sorted().joined(separator: "\u{0}")
    }

    /// Gate per-app RMS computation/emission on or off (T2). Independent of
    /// routing/capture: apps may be actively routed and mixing while metering
    /// stays off (no meter shown), and vice versa is harmless (metering active
    /// with nothing routed just means ``onAppLevel`` never fires).
    public func setMeteringActive(_ active: Bool) {
        queue.async { self.meteringActive = active }
    }

    // MARK: Capture wiring

    /// Observe a per-app tap's state so the mixer learns each app's real
    /// captured ``TapFormat`` (only available on the `.capturing` transition)
    /// and can build the right converter. On any non-capturing state the app's
    /// converter is dropped and its still-pending contribution is flushed out of
    /// its stream, so a stopped app leaves no stale samples behind.
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

    /// Feed one captured buffer for `bundleID` into its stream's mix. Dropped
    /// (silently, correctly) when the app isn't routed to a device, has no
    /// converter yet, or the buffer can't be converted. Otherwise: convert to
    /// S16LE/44100/2ch, scale by the app's volume, sum onto its stream's
    /// frame-indexed timeline, and emit whatever prefix is now old enough to be
    /// final. Safe to call concurrently from several taps' IOProc threads.
    public func handleBuffer(bundleID: String, buffer: CapturedBuffer) {
        let (emissions, level): ([MixedBuffer], Float?) = queue.sync {
            guard let streamGains = streamGainsForBundle[bundleID], !streamGains.isEmpty,
                  let converter = converterForBundle[bundleID],
                  let pcm = converter.convertToAirPlayPCM(buffer),
                  !pcm.isEmpty
            else { return ([], nil) }

            // The per-app meter is a SOURCE/program level: RMS the PRE-volume
            // converted buffer (`pcm`), so the bar reflects how loud the app is
            // actually playing, independent of its routing-volume slider — the
            // meter shows the source, not the attenuated output (ahh's meter
            // feedback: a low slider used to leave the bar stuck near-empty even
            // when the source was loud). Skipped entirely unless a meter listens.
            let level: Float? = meteringActive ? NativeCaptureCoordinator.rmsOfS16LE(pcm) : nil

            // One converted buffer, mixed into every stream this app feeds — a
            // routed group whose members carry different levels is several
            // streams, at one gain each.
            var emissions: [MixedBuffer] = []
            for streamID in streamGains.keys.sorted() {
                let gain = streamGains[streamID]!
                emissions.append(contentsOf: mixLocked(
                    pcm: pcm, gain: gain, streamID: streamID, pts: buffer.pts))
            }
            return (emissions, level)
        }
        for emission in emissions { onMixedBuffer?(emission) }
        if let level { onAppLevel?(bundleID, level) }
    }

    /// Mix one app's already-converted buffer into ONE stream at `gain`, and
    /// return whatever that stream is now ready to emit. MUST hold `queue`.
    private func mixLocked(
        pcm: Data, gain: Int, streamID: Int, pts: timespec
    ) -> [MixedBuffer] {
        let contributorCount = currentSets.first(where: { $0.streamID == streamID })?
            .contributors.count ?? 1

        // SINGLE-contributor stream: pass the converted buffer STRAIGHT
        // through with its own capture pts — identical to the shipping
        // whole-system path (`NativeCaptureCoordinator.handleBuffer` →
        // `engine.write(pcm:pts:)`). Deliberately NO frame-index timeline:
        // audio must stay clocked by its own capture clock, not re-quantized
        // onto a wall-clock-derived grid. That re-gridding (the timeline path
        // below) turns the drift/jitter between the audio clock and the
        // system clock into periodic gaps/overlaps — the "slowed / warbling"
        // artifact — and it degrades badly the moment the output device
        // changes sample rate (e.g. the mic engaging voice-processing mode),
        // which is why it bit even a single redirected app. The engine's PTP
        // timing and the tap aggregate's drift compensation own sync.
        if contributorCount <= 1 {
            // A stream that just dropped from 2 contributors back to 1 may
            // have a stale accumulator — clear it so no held frames leak out.
            timelines.removeValue(forKey: streamID)
            let out = gain == 100
                ? pcm
                : Self.packClipped(Self.scaledStereoSamples(pcm, volumePercent: gain)[...])
            guard !out.isEmpty else { return [] }
            // S16LE stereo == 4 bytes per frame.
            return [MixedBuffer(streamID: streamID, pcm: out,
                                frameCount: out.count / 4, pts: pts)]
        }

        // MULTI-contributor stream (2+ apps summed onto ONE device): the
        // frame-indexed accumulator aligns independently-clocked taps by
        // presentation time before summing. Known-imperfect and gated to the
        // genuinely-shared case only; dual-stream mixing is a tracked
        // follow-up (single-stream routing is the shipping priority).
        let scaled = Self.scaledStereoSamples(pcm, volumePercent: gain)
        guard !scaled.isEmpty else { return [] }
        let timeline = timelines[streamID] ?? {
            let t = MixTimeline()
            timelines[streamID] = t
            return t
        }()
        timeline.add(firstFrame: Self.frameIndex(of: pts), stereo: scaled)
        return timeline.drainReady(
            streamID: streamID,
            holdFrames: Self.holdFrames,
            maxPendingFrames: Self.maxPendingFrames)
    }

    /// Emit every stream's still-pending mixed audio immediately (end-of-run,
    /// teardown, or deterministic test drain). Leaves timelines empty.
    public func flush() {
        let emissions: [MixedBuffer] = queue.sync {
            timelines.flatMap { streamID, timeline in
                timeline.drainAll(streamID: streamID)
            }
        }
        for emission in emissions { onMixedBuffer?(emission) }
    }

    /// Forget an app entirely: its converter and (implicitly, on the next
    /// route update) its stream membership. Called when a route is removed.
    public func removeApp(bundleID: String) {
        queue.sync {
            converterForBundle.removeValue(forKey: bundleID)
            streamGainsForBundle.removeValue(forKey: bundleID)
        }
    }

    // MARK: Sample math (pure, static — the unit tests hammer these)

    /// Interpret interleaved S16LE stereo `pcm` as `[Int32]` samples pre-scaled
    /// by `volumePercent`/100 (rounded), ready to sum without Int16 clipping
    /// until the final combine. An odd trailing byte (never expected from a
    /// stereo S16 buffer) is ignored.
    static func scaledStereoSamples(_ pcm: Data, volumePercent: Int) -> [Int32] {
        let sampleCount = pcm.count / 2
        guard sampleCount > 0 else { return [] }
        let volume = max(0, min(100, volumePercent))
        var out = [Int32](repeating: 0, count: sampleCount)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<sampleCount {
                // S16LE == host-native little-endian on every macOS target.
                let lo = Int32(raw[i * 2])
                let hi = Int32(Int8(bitPattern: raw[i * 2 + 1]))
                let sample = (hi << 8) | lo
                // Round-to-nearest volume scale; volume 100 is exact identity.
                out[i] = volume == 100 ? sample : Int32((sample * Int32(volume) + 50) / 100)
            }
        }
        return out
    }

    /// Clamp one summed `Int32` sample to the Int16 range (hard limiter — the
    /// only defence against multiple loud apps wrapping into noise).
    static func clip(_ sample: Int32) -> Int16 {
        if sample > 32767 { return 32767 }
        if sample < -32768 { return -32768 }
        return Int16(sample)
    }

    /// Pack `[Int32]` accumulated samples into interleaved S16LE `Data`, clipping
    /// each. Inverse of ``scaledStereoSamples(_:volumePercent:)``.
    static func packClipped(_ samples: ArraySlice<Int32>) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            var byte = 0
            for sample in samples {
                let clipped = clip(sample)
                let bits = UInt16(bitPattern: clipped)
                raw[byte] = UInt8(bits & 0xFF)
                raw[byte + 1] = UInt8(bits >> 8)
                byte += 2
            }
        }
        return data
    }

    /// Absolute output-frame index of a presentation timestamp (round-to-
    /// nearest), the shared timebase every member tap's buffers land on.
    static func frameIndex(of pts: timespec) -> Int64 {
        let seconds = Double(pts.tv_sec) + Double(pts.tv_nsec) / 1_000_000_000
        return Int64((seconds * Double(outputSampleRate)).rounded())
    }

    /// Inverse of ``frameIndex(of:)`` — the timestamp of an absolute frame.
    static func timestamp(ofFrame frame: Int64) -> timespec {
        let rate = Int64(outputSampleRate)
        let sec = frame / rate
        let remFrames = frame - sec * rate
        let nsec = Int(Double(remFrames) / Double(outputSampleRate) * 1_000_000_000)
        return timespec(tv_sec: Int(sec), tv_nsec: nsec)
    }
}

// MARK: - Per-stream mix timeline

/// A single stream's running sum, addressed by ABSOLUTE output-frame index so
/// buffers from independently-clocked taps combine by presentation time rather
/// than arrival order. `acc` holds interleaved stereo `Int32` accumulators (2
/// per frame) for the half-open frame range `[startFrame, startFrame + frames)`;
/// an absent contribution is simply zero (a paused app is silence, which is the
/// correct thing to hear). Not thread-safe on its own — ``AppRouteMixer`` only
/// ever touches it while holding its serial queue.
private final class MixTimeline {
    private var startFrame: Int64 = 0
    private var acc: [Int32] = []          // interleaved L,R,L,R…  (2 * frames)
    private var hasData = false
    /// True once any frame has been emitted from the CURRENT accumulator run
    /// (reset when the run fully drains). While true, `startFrame` is a hard
    /// floor: frames before it have already been sent, so a late member's
    /// pre-`startFrame` contribution must be dropped, never re-inserted — see
    /// ``add(firstFrame:stereo:)``.
    private var hasEmitted = false

    private var frameCount: Int { acc.count / 2 }
    private var endFrame: Int64 { startFrame + Int64(frameCount) }

    /// Sum a converted, volume-scaled interleaved-stereo buffer in at its
    /// absolute first-frame index. Frames older than `startFrame` (a member
    /// lagging past the hold window, after the head was already emitted) are
    /// dropped; newer frames extend the accumulator with leading/trailing zeros.
    func add(firstFrame: Int64, stereo: [Int32]) {
        guard !stereo.isEmpty else { return }
        let frames = stereo.count / 2
        guard frames > 0 else { return }

        if !hasData {
            startFrame = firstFrame
            acc = stereo
            hasData = true
            return
        }

        // Extend the front (buffer starts before the current head) ONLY while
        // nothing has been emitted from this run yet — a genuinely-earlier member
        // joining a still-unflushed head. Once emission has advanced `startFrame`,
        // the frames before it are already on the wire: a late member's
        // pre-`startFrame` portion MUST be dropped (the skip logic below handles
        // that), never re-inserted. Re-inserting them (the T1 bug) re-emits an
        // already-sent range at a rewound pts — which, when two apps share a
        // stream and one drains a buffer head before the other contributes,
        // over-delivers frames (playback slows/stretches) and hands the receiver
        // overlapping RTP timestamps. This restores this method's own contract:
        // "Frames older than startFrame … are dropped."
        if firstFrame < startFrame && !hasEmitted {
            let missing = Int(startFrame - firstFrame)
            acc.insert(contentsOf: [Int32](repeating: 0, count: missing * 2), at: 0)
            startFrame = firstFrame
        }
        // Extend the tail with zeros so the whole buffer fits.
        let neededEnd = firstFrame + Int64(frames)
        if neededEnd > endFrame {
            acc.append(contentsOf: [Int32](repeating: 0, count: Int(neededEnd - endFrame) * 2))
        }

        // Sum the buffer in at its offset; skip any portion already emitted.
        let offsetFrames = Int(firstFrame - startFrame)
        let startPair = max(0, offsetFrames)
        let skipFrames = startPair - offsetFrames        // >0 when firstFrame < startFrame
        var dst = startPair * 2
        var src = skipFrames * 2
        while src < stereo.count {
            acc[dst] &+= stereo[src]
            dst += 1
            src += 1
        }
    }

    /// Emit the prefix that is now final: everything older than `holdFrames`
    /// behind the newest frame written, plus a forced flush of the oldest frames
    /// if the pending span exceeds `maxPendingFrames`. Returns zero or one
    /// buffer (the ready prefix, coalesced).
    func drainReady(streamID: Int, holdFrames: Int64, maxPendingFrames: Int64) -> [AppRouteMixer.MixedBuffer] {
        guard hasData, frameCount > 0 else { return [] }

        var readyFrames = Int64(frameCount) - holdFrames
        // Force-flush the overflow if the timeline grew past the hard cap.
        if Int64(frameCount) > maxPendingFrames {
            readyFrames = max(readyFrames, Int64(frameCount) - maxPendingFrames)
        }
        guard readyFrames > 0 else { return [] }

        return [emit(streamID: streamID, frames: Int(readyFrames))]
    }

    /// Emit all pending frames (teardown / explicit flush) and reset.
    func drainAll(streamID: Int) -> [AppRouteMixer.MixedBuffer] {
        guard hasData, frameCount > 0 else { return [] }
        return [emit(streamID: streamID, frames: frameCount)]
    }

    /// Pop `frames` from the head: clip → pack → advance `startFrame`.
    private func emit(streamID: Int, frames: Int) -> AppRouteMixer.MixedBuffer {
        let sampleCount = frames * 2
        let pcm = AppRouteMixer.packClipped(acc[0..<sampleCount])
        let pts = AppRouteMixer.timestamp(ofFrame: startFrame)
        let emitted = AppRouteMixer.MixedBuffer(
            streamID: streamID, pcm: pcm, frameCount: frames, pts: pts)

        acc.removeFirst(sampleCount)
        startFrame += Int64(frames)
        hasEmitted = true
        // A fully-drained run resets the emitted floor: the next `add` starts a
        // fresh head (its `firstFrame` is in the future relative to everything
        // already sent), where a genuinely-earlier second member may again
        // legitimately extend the front before this run's first emission.
        if acc.isEmpty { hasData = false; hasEmitted = false }
        return emitted
    }
}
