import Foundation

/// The probe's audio shape — the tick grid the Mac plays and the mute schedule
/// it alternates the two devices on. Both sides of the spike share these
/// constants; changing one without the other silently invalidates a run.
public struct ProbePattern: Sendable {
    public let beatPeriodSeconds: Double
    public let ticksPerBlock: Int
    public let gapBeats: Int
    public let repetitions: Int

    public init(beatPeriodSeconds: Double, ticksPerBlock: Int, gapBeats: Int, repetitions: Int) {
        self.beatPeriodSeconds = beatPeriodSeconds
        self.ticksPerBlock = ticksPerBlock
        self.gapBeats = gapBeats
        self.repetitions = repetitions
    }

    /// 72 BPM, 6 ticks per block, 2 silent beats between blocks, 3 REF/TGT
    /// repetitions — about 45 s of audio.
    public static let spike = ProbePattern(beatPeriodSeconds: 60.0 / 72.0,
                                           ticksPerBlock: 6,
                                           gapBeats: 2,
                                           repetitions: 3)

    /// Beats from one block's first tick to the next block's first tick.
    var blockStrideBeats: Int { ticksPerBlock + gapBeats }
    /// REF and TGT blocks, in the order they are played.
    var blockCount: Int { repetitions * 2 }
}

/// What one probe recording measured. RAW measurement only — the Mac owns what
/// a given offset means for a device's trim.
public struct ProbeAnalysis: Sendable {
    /// Positive = the target sounded LATE relative to the reference.
    public let offsetMs: Double
    public let spreadMs: Double
    public let usedPairs: Int
    public let confident: Bool

    public init(offsetMs: Double, spreadMs: Double, usedPairs: Int, confident: Bool) {
        self.offsetMs = offsetMs
        self.spreadMs = spreadMs
        self.usedPairs = usedPairs
        self.confident = confident
    }
}

public enum ProbeAnalysisError: Error, Sendable {
    case noTicksDetected
    case patternMismatch(detail: String)
    case insufficientPairs(found: Int)
}

/// Recovers a target speaker's alignment error from a phone recording of the
/// alternating-mute tick probe.
///
/// The whole measurement is a comparison of tick PHASE against the shared beat
/// grid: the reference device's blocks establish where the grid sits at the
/// microphone, the target's blocks say how far off it lands. No clock is ever
/// compared across devices, and the recording's own start time drops out.
public struct ProbeAnalyzer: Sendable {

    /// A tick further off its block's grid than this is not one of ours.
    static let gridResidualTolerance = 0.15
    /// Gap between arrivals that starts a new block, in beats.
    static let blockSplitBeats = 1.2
    /// Blocks and pairs are only trusted with this many ticks behind them.
    static let minimumTicksPerBlock = 3
    static let minimumPairs = 2
    /// Pair-to-pair disagreement, in ms, that a confident result must stay under.
    static let confidenceSpreadMs = 3.0

    private let sampleRate: Double
    private let pattern: ProbePattern

    public init(sampleRate: Double, pattern: ProbePattern) {
        self.sampleRate = sampleRate
        self.pattern = pattern
    }

    public func analyze(recording: [Float]) throws -> ProbeAnalysis {
        let template = TickTemplate.render(sampleRate: sampleRate)
        guard recording.count > template.count * 2 else { throw ProbeAnalysisError.noTicksDetected }

        let correlation = MatchedFilter(template: template, sampleRate: sampleRate).correlationMagnitudes(of: recording)
        let arrivals = TickPicker(sampleRate: sampleRate).arrivals(in: correlation)
        let blocks = try slottedBlocks(from: arrivals)

        let period = pattern.beatPeriodSeconds
        var deltas: [Double] = []
        for repetition in 0..<pattern.repetitions {
            guard let reference = blocks[repetition * 2], let target = blocks[repetition * 2 + 1] else { continue }
            deltas.append(centeredRemainder(target.phase - reference.phase, period))
        }
        guard deltas.count >= Self.minimumPairs else {
            throw ProbeAnalysisError.insufficientPairs(found: deltas.count)
        }

        let offset = deltas.reduce(0, +) / Double(deltas.count)
        let spreadMs = (deltas.map { abs($0 - offset) }.max() ?? 0) * 1000
        return ProbeAnalysis(offsetMs: offset * 1000,
                             spreadMs: spreadMs,
                             usedPairs: deltas.count,
                             confident: deltas.count >= Self.minimumPairs && spreadMs <= Self.confidenceSpreadMs)
    }

    // MARK: - Blocks

    private struct Block {
        /// Absolute time of the block's first detected tick.
        let firstTick: Double
        /// The block's grid offset within one beat — what the comparison uses.
        let phase: Double
    }

    /// Groups arrivals into blocks and puts each block in its expected slot of
    /// the REF, TGT, REF, TGT… schedule. Slot 0 is REF: the phone starts
    /// recording before the Mac starts the probe, so the first block detected
    /// is always the reference one.
    private func slottedBlocks(from arrivals: [TickArrival]) throws -> [Int: Block] {
        let period = pattern.beatPeriodSeconds
        var clusters: [[TickArrival]] = []
        for arrival in arrivals.sorted(by: { $0.seconds < $1.seconds }) {
            if let last = clusters.last?.last, arrival.seconds - last.seconds <= Self.blockSplitBeats * period {
                clusters[clusters.count - 1].append(arrival)
            } else {
                clusters.append([arrival])
            }
        }

        let blocks = clusters.compactMap(fit(cluster:))
        guard let first = blocks.first else { throw ProbeAnalysisError.noTicksDetected }

        var slotted: [Int: Block] = [:]
        for block in blocks {
            let beat = ((block.firstTick - first.firstTick) / period).rounded()
            let slot = Int((beat / Double(pattern.blockStrideBeats)).rounded())
            // One beat of slack: the block's own first tick may have been
            // clipped away by the mute switch and never detected at all.
            guard abs(beat - Double(slot * pattern.blockStrideBeats)) <= 1 else {
                throw ProbeAnalysisError.patternMismatch(
                    detail: "a block starts \(Int(beat)) beats in, which is no block slot")
            }
            guard slot >= 0, slot < pattern.blockCount else {
                throw ProbeAnalysisError.patternMismatch(
                    detail: "a block falls outside the \(pattern.blockCount) expected blocks")
            }
            guard slotted[slot] == nil else {
                throw ProbeAnalysisError.patternMismatch(detail: "two blocks claim slot \(slot)")
            }
            slotted[slot] = block
        }
        return slotted
    }

    /// Least-squares fit of one block's ticks to the known grid `t = a + iP`.
    /// Returns nil when the cluster is not a block: too few ticks, or ticks
    /// that do not sit on the grid at all.
    private func fit(cluster: [TickArrival]) -> Block? {
        // The first tick of every block is discarded on principle: the mute
        // switch is wall-clock scheduled to ±200 ms, so that one tick may be
        // clipped mid-transient and its onset is not trustworthy.
        let ticks = cluster.dropFirst()
        guard let origin = ticks.first?.seconds else { return nil }
        let period = pattern.beatPeriodSeconds

        var indices: [Double] = []
        var times: [Double] = []
        for tick in ticks {
            let index = ((tick.seconds - origin) / period).rounded()
            let residual = abs(tick.seconds - origin - index * period)
            guard residual <= Self.gridResidualTolerance * period,
                  index < Double(pattern.ticksPerBlock),
                  index != indices.last else { continue }
            indices.append(index)
            times.append(tick.seconds)
        }
        guard times.count >= Self.minimumTicksPerBlock else { return nil }

        // P is known, so the fit reduces to averaging the per-tick estimates
        // of where the grid starts.
        let start = zip(times, indices).map { $0 - $1 * period }.reduce(0, +) / Double(times.count)
        return Block(firstTick: cluster[0].seconds, phase: start - (start / period).rounded(.down) * period)
    }
}

/// Remainder in (−period/2, period/2] — the smallest signed distance between
/// two grid phases, which is what "how late is the target" means when both are
/// known only modulo one beat.
func centeredRemainder(_ value: Double, _ period: Double) -> Double {
    var remainder = value.truncatingRemainder(dividingBy: period)
    if remainder <= -period / 2 { remainder += period }
    if remainder > period / 2 { remainder -= period }
    return remainder
}
