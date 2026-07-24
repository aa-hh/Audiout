import Foundation

// phase-spike — throwaway feasibility harness for T-SPIKE-PHASE.
// See dev/notes/phase-lock-spike-findings.md for the writeup this feeds.

let usage = """
phase-spike — measure achievable phase-lock precision for the SyncedLocalSink graph

USAGE:
  phase-spike offline        Silent, no device. Runs:
                               • plan-math Monte-Carlo (sub-buffer placement floor)
                               • offline render-block AudioTimeStamp cadence
                               • correction-node probe (TimePitch / Varispeed)
                               • custom fractional-resampler probe
  phase-spike realdevice [--seconds N]
                             Opens the default output device and measures REAL
                             per-cycle hostTime jitter. Emits ONLY digital silence
                             (zeros, isSilence=true, mainMixer volume 0). Default N=4.
  phase-spike all [--seconds N]   offline + realdevice
  -h | --help

All 'offline' work is silent and touches no audio device. 'realdevice' opens an IO
cycle on the default output device but produces no audible sound.
"""

func planMathSection() {
    print("== Q1/Q3 (algorithmic floor): SyncTiming.plan sub-buffer placement ==")
    for (sr, buf) in [(48_000.0, 512), (48_000.0, 4096), (44_100.0, 512)] {
        let s = PlanMath.monteCarlo(sampleRate: sr, frameCount: buf, trials: 200_000)
        let halfFrameNs = 0.5 * 1e9 / sr
        print("  sr=\(Int(sr)) buffer=\(buf): |phase error| \(s.describe(unit: "ns")); theoretical ±½-frame = \(String(format: "%.2f", halfFrameNs)) ns")
    }
    print("  → frame-accurate silent-prefix placement holds the INITIAL release to ≤ ½ frame")
    print("    (~10 µs @ 48k), INDEPENDENT of buffer size. Buffer size sets correction CADENCE, not precision.\n")
}

func runOffline() {
    planMathSection()
    OfflineTimestampProbe().run()
    print("")
    CorrectionProbe().run()
    print("")
    FractionalResampler.run()
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print(usage); exit(2) }

func seconds(from args: [String]) -> Double {
    if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count, let v = Double(args[i + 1]) { return v }
    return 4
}

switch cmd {
case "-h", "--help":
    print(usage)
case "offline":
    runOffline()
case "realdevice":
    RealDeviceProbe(seconds: seconds(from: args)).run()
case "all":
    runOffline()
    print("")
    RealDeviceProbe(seconds: seconds(from: args)).run()
default:
    print("unknown command: \(cmd)\n")
    print(usage)
    exit(2)
}
