import Foundation
import AVFoundation

// Q1/Q3 (the part offline CANNOT show): the REAL per-cycle hostTime the HAL hands
// the render block against the real default output device, and its jitter. This is
// the number R7 actually turns on.
//
// SILENCE GUARANTEE (triple): the source node writes ONLY zeros AND sets
// isSilence=true, AND mainMixer.outputVolume is forced to 0. No tone, no captured
// audio, nothing audible — this is not a playback/self-test. It DOES open an IO
// cycle on the default output device for `--seconds`, so it is opt-in
// (`realdevice`) and short. macOS mixes audio for normal apps, so it does not
// interrupt anything else the user is playing.

final class RealDeviceProbe {
    let seconds: Double
    private var hostDeltasNs = [Double]()
    private var monoVsHostSkewNs = [Double]()
    private var lastHost: UInt64 = 0
    private var firstCycleHandled = false
    private let lock = NSLock()
    private var cycleCount = 0

    init(seconds: Double) { self.seconds = seconds }

    func run() {
        print("== Q1/Q3 (real device): render-block hostTime jitter — SILENT (zeros only) ==")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let engine = AVAudioEngine()
        let src = AVAudioSourceNode(format: format) { [weak self] isSilence, tsPtr, frameCount, ablPtr in
            let ts = tsPtr.pointee
            self?.record(hostTime: ts.mHostTime, flags: ts.mFlags.rawValue)
            // zero the output (belt) and declare silence (suspenders)
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            for buf in abl {
                if let p = buf.mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<Int(frameCount) { p[i] = 0 }
                }
            }
            isSilence.pointee = true
            return noErr
        }
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0   // third guard
        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("  ERROR starting engine: \(error) — skipping (needs a usable default output device).")
            return
        }
        // sanity: confirm the graph's output config
        let outFmt = engine.outputNode.outputFormat(forBus: 0)
        print("  output device format: \(outFmt.sampleRate) Hz, \(outFmt.channelCount) ch; mainMixer.outputVolume=\(engine.mainMixerNode.outputVolume)")
        usleep(useconds_t(seconds * 1_000_000))
        engine.stop()

        lock.lock(); let hd = hostDeltasNs; let skew = monoVsHostSkewNs; let cc = cycleCount; lock.unlock()
        guard cc > 2 else { print("  render block fired \(cc) times — insufficient to measure."); return }
        let expectedCyclePeriodNs = expectedPeriodNs(format: outFmt)
        // jitter = deviation of the per-cycle hostTime advance from its own mean
        let ds = Stats(hd)
        var jitter = [Double]()
        for d in hd { jitter.append(abs(d - ds.mean)) }
        print("  cycles measured: \(cc)  (~\(String(format: "%.2f", Double(cc) * ds.mean / 1e9)) s)")
        print("  per-cycle hostTime Δ: \(ds.describe(unit: "ns"))")
        print("    (nominal buffer period ≈ \(String(format: "%.1f", expectedCyclePeriodNs/1000)) µs)")
        print("  hostTime Δ jitter |Δ−mean|: \(Stats(jitter).describe(unit: "ns"))")
        print("  mono↔host rebase skew stability: \(Stats(skew).describe(unit: "ns"))")
        print("""
          INTERPRETATION: mHostTime is the HAL's clock-anchored presentation anchor for
          the cycle, NOT 'wall time when the callback woke'. Its per-cycle Δ tracking the
          nominal buffer period with low jitter is what a phase-lock control loop reads.
          Thread-scheduling jitter (when the callback runs) does NOT corrupt this anchor.
        """)
    }

    private func record(hostTime: UInt64, flags: UInt32) {
        lock.lock(); defer { lock.unlock() }
        cycleCount += 1
        let mono = MachTime.monotonicNanos()
        let hostNs = MachTime.hostTicksToNanos(hostTime)
        if hostTime != 0 { monoVsHostSkewNs.append(Double(mono - hostNs)) }
        if firstCycleHandled, lastHost != 0, hostTime != 0 {
            hostDeltasNs.append(Double(MachTime.hostTicksToNanos(hostTime) - MachTime.hostTicksToNanos(lastHost)))
        }
        lastHost = hostTime
        firstCycleHandled = true
    }

    private func expectedPeriodNs(format: AVAudioFormat) -> Double {
        // We don't know the device's buffer size from here without HAL calls; infer
        // from the median observed Δ instead (reported separately). Return a rough
        // 512-frame reference for context.
        return 512.0 / format.sampleRate * 1e9
    }
}
