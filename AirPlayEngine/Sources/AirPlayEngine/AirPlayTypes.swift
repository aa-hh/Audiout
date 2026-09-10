// AirPlayEngine — public value types (T-API-1).
//
// These are the neutral, OwnTone-free Swift types the app (via NativeBackend,
// T-BACKEND-1) and the probe CLI use. They map onto the vendored C cluster's
// structs at the FFI boundary (see AirPlayEngine.swift) but never expose a C
// type in the public surface.
//
// SPEC.md §4: no OwnTone naming in any public symbol.

import Foundation

/// A stable identifier for a discovered/added output, echoing the AirPlay
/// device id (the 64-bit value parsed from the mDNS `deviceid` TXT key). The
/// app holds this opaque handle; the engine owns the underlying C device.
public struct OutputID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { String(format: "0x%016llX", rawValue) }
}

/// The address family of a resolved endpoint.
public enum AddressFamily: Sendable {
    case ipv4
    case ipv6
}

/// A resolved AirPlay receiver descriptor, produced by the app-side discovery
/// layer (an `NWBrowser` for `_airplay._tcp` — discovery is app-owned per the
/// RESOLVED Q5 decision) and fed to the engine via ``AirPlayEngine/addOutput(_:)``
/// or ``AirPlayEngine/updateDiscovery(_:)``.
///
/// The engine builds the vendored `output_device` from this by driving the
/// sender's own discovery callback (seam-map §4), so features/deviceid parsing,
/// the AP2 gate, and the reconnect/keep-alive heuristic all run in the vetted C
/// code rather than being reimplemented in Swift.
public struct DeviceDescriptor: Sendable {
    /// Which mDNS service (and therefore which vendored backend, T5's
    /// `output_raop` vs `output_airplay`) this descriptor was resolved from.
    public enum ServiceKind: Sendable, Equatable {
        /// `_raop._tcp` — classic AirPlay 1 / RAOP (AirTunes v2), routed to
        /// `output_raop` via `airplayengine_feed_raop_device`.
        case raop
        /// `_airplay._tcp` — AirPlay 2, routed to `output_airplay` via
        /// `airplayengine_feed_device`. The long-standing default.
        case airplay
    }

    /// The mDNS service instance name — also the identity key used when the
    /// device disappears (removal matches on this name; seam-map §4).
    public var name: String
    /// The resolved host name (informational; the engine connects by `address`).
    public var hostname: String
    /// The resolved numeric IP address string (v4 or v6 per `family`).
    public var address: String
    /// Address family of `address`.
    public var family: AddressFamily
    /// The RTSP port advertised by the receiver.
    public var port: Int
    /// Which backend this descriptor targets. Defaults to `.airplay` so
    /// existing AP2-only call sites are unaffected.
    public var kind: ServiceKind

    /// The raw DNS-SD TXT record key/value pairs. At minimum this must carry
    /// `deviceid` (colon-hex MAC form, e.g. `AA:BB:CC:DD:EE:FF`) and `features`
    /// (the AP2 feature bitmask string); `model` is used for the reconnect/
    /// keep-alive heuristic. The engine passes these verbatim into the sender's
    /// `keyval` so the vendored `features_parse`/`device_id_colon_parse` run.
    public var txtRecord: [String: String]

    public init(
        name: String,
        hostname: String = "",
        address: String,
        family: AddressFamily,
        port: Int,
        kind: ServiceKind = .airplay,
        txtRecord: [String: String]
    ) {
        self.name = name
        self.hostname = hostname
        self.address = address
        self.family = family
        self.port = port
        self.kind = kind
        self.txtRecord = txtRecord
    }

    /// The device id parsed from the `deviceid` TXT key, if present/valid.
    /// Convenience for the app to correlate a descriptor with an ``OutputID``.
    public var parsedID: OutputID? {
        guard let idStr = txtRecord["deviceid"] ?? txtRecord["DeviceID"] else { return nil }
        let hex = idStr.replacingOccurrences(of: ":", with: "")
        guard let value = UInt64(hex, radix: 16) else { return nil }
        return OutputID(rawValue: value)
    }
}

/// The lifecycle state of an output, mirroring the vendored
/// `enum output_device_state` (seam-map §2.1) but named neutrally.
public enum OutputState: Sendable, Equatable {
    case stopped
    case startup
    case connected
    case streaming
    case failed
    /// The receiver requires a password/PIN we don't have.
    case passwordRequired

    /// Terminal states an async op (`addOutput`/`removeOutput`/`setVolume`) can
    /// resolve to — i.e. the states the vendored sender reports via a *single*
    /// `outputs_cb` that spends its `callback_id` (sets it to -1).
    ///
    /// CRITICAL (2026-07-16 first-light fix): `.connected` IS terminal. For an
    /// AirPlay 2 buffered receiver (Sonos/HomePod/…), the `device_start` success
    /// callback is `OUTPUT_STATE_CONNECTED`, NOT `OUTPUT_STATE_STREAMING`. The
    /// sequence table wires `AIRPLAY_SEQ_START_PLAYBACK.on_success =
    /// session_connected` (airplay.c:3620), which sets state CONNECTED and fires
    /// `session_status()` exactly once, clearing `callback_id` to -1
    /// (airplay.c:1338-1343, 1094-1095). STREAMING is reached later *internally*
    /// by `airplay_write()` (airplay.c:4278, comment `// Make a cb?` — it does
    /// NOT), so no STREAMING callback ever arrives for `device_start`. Treating
    /// `.connected` as non-terminal dropped that sole completion and hung the
    /// `addOutput` waiter forever (and, once the id was spent, the later failure's
    /// `outputs_cb(-1,…)` no-op could not recover it). This matches OwnTone's
    /// player semantics (device_start's callback == "startup finished/failed") and
    /// docs/outputs-dispatcher-contract.md §6, which lists CONNECTED as terminal.
    ///
    /// Only `.startup` (the genuine INFO…RECORD progress state) stays
    /// non-terminal — but in this cluster `device_start` never reports it, since
    /// `session_status` is only called at sequence success/failure, never mid-way.
    var isTerminal: Bool {
        switch self {
        case .streaming, .connected, .stopped, .failed, .passwordRequired: return true
        case .startup: return false
        }
    }
}

/// A transport command a user pressed on a speaker's own playback controls.
/// macOS exposes a single Play/Pause *toggle* media key, and the vendored event
/// path collapses the device's distinct play/pause into one command, so both
/// arrive here as ``playPause``.
public enum TransportCommand: Sendable, Equatable {
    case playPause
    case next
    case previous
}

/// Something the user did ON THE SPEAKER itself, reported back to the sender over
/// the AirPlay reverse event channel (``AirPlayEngine/makeRemoteEventStream()``).
/// The app turns each into a local action — a Mac media key for ``transport``, a
/// slider move for ``volume``.
public enum RemoteEvent: Sendable, Equatable {
    /// A transport key (play/pause/next/previous). Global: it targets the Mac's
    /// single media session, not one speaker, so it carries no ``OutputID``.
    case transport(TransportCommand)
    /// The identified speaker changed its OWN volume to `level` (0.0…1.0) — e.g.
    /// its physical buttons or the Sonos app. Routed to that one output so only
    /// its slider follows.
    case volume(OutputID, level: Double)
}

/// Errors surfaced from the engine's async surface.
public enum AirPlayEngineError: Error, Sendable, Equatable {
    /// `start()`/init hasn't completed (or `stop()` already ran).
    case engineNotRunning
    /// The vendored `airplay_init` returned failure.
    case initFailed
    /// A device op returned "no callback promised" (N <= 0) unexpectedly, or the
    /// backend rejected the request outright.
    case operationRejected
    /// The session reached a terminal failure (`failed`).
    case sessionFailed
    /// The receiver requires a password/PIN (`passwordRequired`).
    case passwordRequired
    /// No output is registered for the given id.
    case unknownOutput(OutputID)
    /// The descriptor is missing a valid `deviceid` TXT key.
    case invalidDescriptor
    /// The engine thread's event base could not be created / dispatcher wiring failed.
    case engineThreadFailed
    /// An armed op's deferred completion never arrived within the bounded
    /// timeout window (the receiver's media/PTP path stalled mid-op). Surfaced as
    /// a normal thrown op failure so the awaiting continuation is resumed exactly
    /// once instead of leaking forever (toggle-spam session 2026-07-17: 177
    /// leaked `startOp` continuations when a receiver stalled during NORMAL
    /// running). `NativeBackend`'s existing failure/recovery path handles it like
    /// any other op failure.
    case opTimedOut
}

/// Audio format the engine's `write(pcm:)` expects: interleaved signed 16-bit
/// little-endian PCM. The AirPlay 2 sender is fixed at 44100 Hz / 16-bit / 2ch
/// (the ALAC frame is 352 samples; seam-map §5). Exposed as a constant so the
/// app can assert its capture pipeline matches.
public struct PCMFormat: Sendable, Equatable {
    public let sampleRate: Int
    public let bitsPerSample: Int
    public let channels: Int

    /// The one format the AirPlay 2 sender accepts (S16LE / 44100 / stereo).
    public static let airplay = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 2)
}

/// A diagnostic snapshot of the write-cadence tracker (T-ENG-CADENCE-1).
///
/// Models OwnTone's `player.c` `pb_write_deficit_max` bookkeeping: every write
/// on the hot path carries a fixed amount of "audio time" (`samples / rate`);
/// the tracker compares that against the WALL-CLOCK time actually elapsed
/// between writes and accumulates the running gap. A caller that writes slower
/// than real-time (capture underfeeding the engine — buffer starvation, a
/// stalled tap, GC/scheduling hiccups) falls BEHIND, growing `deficitSeconds`.
/// A caller that bursts writes faster than real-time (e.g. catching up after a
/// stall, or a buggy producer) runs AHEAD, growing `overrunSeconds`.
///
/// This is diagnostic-only: nothing here gates, throttles, or drops a write.
/// The tracker only counts and logs; playback timing itself is entirely the
/// vendored sender's (via the `pts` passed to `write`).
public struct WriteCadenceSnapshot: Sendable, Equatable {
    /// Total writes observed since the tracker was created/reset.
    public var writeCount: UInt64
    /// Cumulative wall-clock time the write cadence has run BEHIND the audio
    /// time actually DELIVERED (seconds) — includes the audio time of writes
    /// the engine's own backpressure guard refused (see `refusedSeconds`).
    /// Monotonically non-decreasing except across a `reset()`.
    ///
    /// NOT the receiver-visible shortfall on its own: this is a one-sided sum,
    /// so symmetric scheduling jitter inflates it with no audio lost. Read
    /// `netDriftSeconds` for the shortfall.
    public var deficitSeconds: Double
    /// Cumulative wall-clock time the write cadence has run AHEAD of the audio
    /// time it was claiming to deliver (seconds, i.e. bursty/overrunning
    /// writes). Monotonically non-decreasing except across a `reset()`.
    public var overrunSeconds: Double
    /// The gap (wall-clock elapsed minus audio-time delivered, seconds) as of
    /// the most recent write. Positive = currently behind (deficit), negative
    /// = currently ahead (overrun). Zero at/near steady state.
    public var lastGapSeconds: Double
    /// Writes the engine's own backpressure guard REFUSED (never delivered).
    /// Their audio time is already folded into `deficitSeconds` — these two
    /// fields exist so the engine's drop-site contribution to the deficit stays
    /// distinguishable from a slow producer. Monotonically non-decreasing
    /// except across a `reset()`.
    public var refusedWrites: UInt64
    /// Cumulative audio time (seconds) of the refused writes above.
    public var refusedSeconds: Double
    /// Cumulative time (seconds) spent in gaps too long to be slow feeding —
    /// playback paused, the Mac slept, the tap was rebuilt. Excluded from
    /// `deficitSeconds` so a lid-close cannot masquerade as audio loss.
    /// Monotonically non-decreasing except across a `reset()`.
    public var stalledSeconds: Double
    /// How many such discontinuities were observed.
    public var stallCount: UInt64

    /// The actual drift: how far the receiver has fallen behind, in seconds.
    /// Deficit minus overrun, so symmetric jitter cancels instead of
    /// accumulating. This is the number to read, chart, and alarm on.
    public var netDriftSeconds: Double { deficitSeconds - overrunSeconds }

    public init(
        writeCount: UInt64 = 0,
        deficitSeconds: Double = 0,
        overrunSeconds: Double = 0,
        lastGapSeconds: Double = 0,
        refusedWrites: UInt64 = 0,
        refusedSeconds: Double = 0,
        stalledSeconds: Double = 0,
        stallCount: UInt64 = 0
    ) {
        self.writeCount = writeCount
        self.deficitSeconds = deficitSeconds
        self.overrunSeconds = overrunSeconds
        self.lastGapSeconds = lastGapSeconds
        self.refusedWrites = refusedWrites
        self.refusedSeconds = refusedSeconds
        self.stalledSeconds = stalledSeconds
        self.stallCount = stallCount
    }
}

/// A diagnostic snapshot of the write-path backpressure guard (memory-leak
/// audit 2026-07-23 — the one unbounded-growth site found in this layer).
///
/// `write(streams:pts:)` heap-copies each PCM buffer and enqueues a closure onto
/// the single engine thread. With no cap, a thread that stops draining (see
/// `EngineThread.stop()`'s documented "vendored callback wedged in a blocking
/// call" mode) lets producers pile PCM-carrying closures onto libevent's pending
/// list without bound — hundreds of KB/s per active stream for as long as the
/// stall lasts. The guard bounds the *un-drained* audio queued per stream to a
/// fixed audio-time cap and drops further writes past it. Diagnostic-only, like
/// ``WriteCadenceSnapshot``: this snapshot reports what the guard did; it never
/// itself gates a write.
public struct WriteBacklogSnapshot: Sendable, Equatable {
    /// Cumulative `write(streams:pts:)` calls dropped (across all streams)
    /// because a stream's un-drained backlog was already at the cap. Zero in
    /// healthy operation. Monotonically non-decreasing except across a `reset()`.
    public var droppedWrites: UInt64
    /// The largest per-stream un-drained backlog right now (seconds of audio).
    /// Sits near zero when the engine thread is draining normally; approaches the
    /// cap only while a stream is stalled.
    public var maxInFlightSeconds: Double
    /// How many streams currently carry a non-zero un-drained backlog.
    public var streamsTracked: Int

    public init(
        droppedWrites: UInt64 = 0,
        maxInFlightSeconds: Double = 0,
        streamsTracked: Int = 0
    ) {
        self.droppedWrites = droppedWrites
        self.maxInFlightSeconds = maxInFlightSeconds
        self.streamsTracked = streamsTracked
    }
}

/// One metric family's aggregated stats from `WriteSchedulingProbe`
/// (T-ENG-SCHED-1, docs/plans/PLAN-AUDIO-THREAD-SCHEDULING.md task T1):
/// count/p50/p95/p99/max in milliseconds, computed over that probe's bounded
/// ring-buffer window (see `WriteSchedulingProbe` for why `count` is
/// cumulative-since-start while the percentiles are windowed).
public struct WriteSchedulingMetricSnapshot: Sendable, Equatable {
    /// Total samples recorded since the probe was created (not bounded by
    /// the percentile window).
    public var count: UInt64
    public var p50Ms: Double
    public var p95Ms: Double
    public var p99Ms: Double
    public var maxMs: Double

    public init(
        count: UInt64 = 0,
        p50Ms: Double = 0,
        p95Ms: Double = 0,
        p99Ms: Double = 0,
        maxMs: Double = 0
    ) {
        self.count = count
        self.p50Ms = p50Ms
        self.p95Ms = p95Ms
        self.p99Ms = p99Ms
        self.maxMs = maxMs
    }
}

/// A consistent snapshot of `WriteSchedulingProbe`'s three independent
/// metric families, each discriminating a different candidate cause of
/// audio dropouts under system load (plan §B.4):
///   - `wakeLatency` — enqueue instant to `body` start (H1: send-thread
///     starvation).
///   - `inCycleWork` — `body` entry to exit (in-cycle stalls; also
///     calibrates a future real-time `computation` budget, T14).
///   - `interArrivalGap` — gap between successive `write` calls (H2:
///     capture-side underrun, distinct from anything downstream of arrival).
///
/// Cheap to read from any thread (see `WriteSchedulingProbe.snapshot()`) —
/// T2 polls this every ~5s from a non-RT thread, never the engine thread.
public struct WriteSchedulingSnapshot: Sendable, Equatable {
    public var wakeLatency: WriteSchedulingMetricSnapshot
    public var inCycleWork: WriteSchedulingMetricSnapshot
    public var interArrivalGap: WriteSchedulingMetricSnapshot

    public init(
        wakeLatency: WriteSchedulingMetricSnapshot = WriteSchedulingMetricSnapshot(),
        inCycleWork: WriteSchedulingMetricSnapshot = WriteSchedulingMetricSnapshot(),
        interArrivalGap: WriteSchedulingMetricSnapshot = WriteSchedulingMetricSnapshot()
    ) {
        self.wakeLatency = wakeLatency
        self.inCycleWork = inCycleWork
        self.interArrivalGap = interArrivalGap
    }
}

/// What one content stream carried since the previous snapshot: the loudest
/// sample in the window as dBFS, and how long the stream has been silent in a
/// row (`silentSeconds`, running across windows until a write above −60 dBFS
/// resets it). A stream "connected" with packets flowing and `silentSeconds`
/// climbing is exactly the shape that could not be told apart from healthy
/// playback on 2026-09-05 (docs/plans/PLAN-LIVE-DIAGNOSTICS.md C3).
/// `peakDBFS` floors at −120 for an all-zero window.
public struct StreamLevelSnapshot: Sendable, Equatable {
    public var streamId: UInt32
    public var peakDBFS: Double
    public var silentSeconds: Double
    public var writes: UInt64

    public init(streamId: UInt32, peakDBFS: Double, silentSeconds: Double, writes: UInt64) {
        self.streamId = streamId
        self.peakDBFS = peakDBFS
        self.silentSeconds = silentSeconds
        self.writes = writes
    }
}
