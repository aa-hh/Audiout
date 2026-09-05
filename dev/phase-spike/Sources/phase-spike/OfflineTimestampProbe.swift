import Foundation
import AVFoundation

// Q1/Q3 (algorithmic half): drive a SyncedLocalSink-shaped graph (an
// AVAudioSourceNode gated by a hostTime target) in OFFLINE manual rendering and
// record what the render block's AudioTimeStamp actually contains. This isolates
// the DETERMINISTIC / algorithmic behaviour (sampleTime cadence, hostTime
// availability offline) from real render-thread jitter — which offline mode
// cannot show and which the real-device probe measures instead.

final class OfflineTimestampProbe {
    let sampleRate: Double = 48_000
    let maxFrames: AVAudioFrameCount = 512
    let format: AVAudioFormat

    private var sampleTimes = [Double]()
    private var hostTimes = [UInt64]()
    private var flagsSeen = Set<UInt32>()

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    func run() {
        print("== Q1/Q3 (offline half): render-block AudioTimeStamp cadence ==")
        let engine = AVAudioEngine()
        let src = AVAudioSourceNode(format: format) { [weak self] _, tsPtr, frameCount, ablPtr in
            let ts = tsPtr.pointee
            self?.sampleTimes.append(ts.mSampleTime)
            self?.hostTimes.append(ts.mHostTime)
            self?.flagsSeen.insert(ts.mFlags.rawValue)
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            for buf in abl {
                if let p = buf.mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<Int(frameCount) { p[i] = 0 }
                }
            }
            return noErr
        }
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
            try engine.start()
            let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames)!
            var rendered = 0
            while rendered < Int(sampleRate) {  // 1 s
                let want = AVAudioFrameCount(min(Int(maxFrames), Int(sampleRate) - rendered))
                let st = try engine.renderOffline(want, to: out)
                if st == .success { rendered += Int(out.frameLength) } else { break }
            }
            engine.stop()
        } catch {
            print("  ERROR: \(error)")
            return
        }

        // sampleTime should increment by exactly the frame count each cycle.
        var sampleDeltas = [Double]()
        for i in 1..<sampleTimes.count { sampleDeltas.append(sampleTimes[i] - sampleTimes[i - 1]) }
        let sd = Stats(sampleDeltas)
        // AudioTimeStampFlags bits: SampleTimeValid=1, HostTimeValid=2, ...
        let hostTimeValidBit: UInt32 = 2
        let anyHostValid = flagsSeen.contains { ($0 & hostTimeValidBit) != 0 }
        print("  cycles=\(sampleTimes.count)")
        print("  sampleTime Δ per cycle: \(sd.describe(unit: "frames"))")
        print("  → sampleTime is perfectly regular (the deterministic offline grid).")
        print("  timestamp flags seen: \(flagsSeen.sorted().map { String($0) }.joined(separator: ",")) (bit0=SampleTimeValid, bit1=HostTimeValid)")
        if !anyHostValid {
            print("  → HostTimeValid bit is NEVER set offline: mHostTime is INVALID here (sampleTime-only).")
            print("    Real per-cycle hostTime + its jitter can ONLY be measured against a real")
            print("    device clock — see the 'realdevice' probe / the owner's live run.")
        } else {
            var hd = [Double]()
            for i in 1..<hostTimes.count { hd.append(Double(MachTime.hostTicksToNanos(hostTimes[i]) - MachTime.hostTicksToNanos(hostTimes[i-1]))) }
            print("  → offline hostTime FLAGGED valid; Δ: \(Stats(hd).describe(unit: "ns"))")
        }
    }
}
