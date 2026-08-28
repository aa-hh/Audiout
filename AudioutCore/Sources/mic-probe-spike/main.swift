// SPDX-License-Identifier: GPL-2.0-or-later
//
// mic-probe-spike — the hardware leg of the mic-probe sync calibration
// (dev/notes/mic-probe-calibration-brief.md, roadmap 064 step 2).
//
// Plays the dual calibration sweeps (UP on the left channel, DOWN on the
// right) out a chosen output device while recording the Mac's BUILT-IN
// microphone, then runs the production matched filter on the capture and
// prints both arrivals and their difference.
//
// It exists to answer two questions on real hardware:
//  1. Does A2DP survive while the built-in mic records? (The unresolved
//     R-A2DP/HFP risk — BT-SPIKE-OFFSET was cut before running. The tool
//     watches the output device's nominal sample rate for the HFP collapse.)
//  2. What does the probe measurement look like in a real room — arrival
//     confidence, run-to-run stability, sensible Δ?
//
// The mic is pinned to the built-in device BY ID, never the default input:
// with a Bluetooth speaker connected, the default input may BE that speaker's
// mic, and opening it is exactly what forces the HFP collapse.
//
// Run it from a terminal (the mic permission prompt attributes to the
// terminal app):   swift run --package-path AudioutCore mic-probe-spike

import AVFoundation
import AudioutCore
import CoreAudio
import Foundation

// MARK: - CLI

let usage = """
usage: mic-probe-spike [--output <name-substring>] [--duration <s>] \
[--gain <0..1>] [--lead-in <s>] [--keep <file.f32>] [--selftest]

  --output    play probes on the first output device whose name contains the
              substring (case-insensitive); default: the system default output
  --duration  sweep length in seconds (default 1.0)
  --gain      probe amplitude 0..1 (default 0.4)
  --lead-in   ambient-noise seconds recorded before the probes (default 0.8)
  --keep      also write the mono Float32 capture to this path
  --selftest  no hardware: run a synthetic scene through the analysis path
"""

var outputMatch: String?
var duration = 1.0
var gain: Float = 0.4
var leadIn = 0.8
var keepPath: String?
var selftest = false

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    func value() -> String {
        guard let v = args.first else { fputs(usage + "\n", stderr); exit(64) }
        args.removeFirst(); return v
    }
    switch arg {
    case "--output": outputMatch = value()
    case "--duration": duration = Double(value()) ?? duration
    case "--gain": gain = Float(value()) ?? gain
    case "--lead-in": leadIn = Double(value()) ?? leadIn
    case "--keep": keepPath = value()
    case "--selftest": selftest = true
    case "-h", "--help": print(usage); exit(0)
    default: fputs("unknown argument \(arg)\n" + usage + "\n", stderr); exit(64)
    }
}

// MARK: - Analysis (shared by selftest and the real run)

struct ProbeAnalysis {
    let up: SyncProbeCorrelator.Arrival
    let down: SyncProbeCorrelator.Arrival
    let deltaMs: Double
}

func analyze(recording: [Float], sampleRate: Double, leadInSeconds: Double) -> ProbeAnalysis? {
    let upRef = SyncProbe.samples(.upSweep(sampleRate: sampleRate, duration: duration))
    let downRef = SyncProbe.samples(.downSweep(sampleRate: sampleRate, duration: duration))
    let ambientCount = min(recording.count, Int(leadInSeconds * 0.75 * sampleRate))
    let ambient = ambientCount > 0 ? Array(recording[0..<ambientCount]) : nil
    let correlator = SyncProbeCorrelator(sampleRate: sampleRate)
    guard let m = correlator.relativeOffset(probeA: upRef, probeB: downRef,
                                            recording: recording, ambientNoise: ambient)
    else { return nil }
    return ProbeAnalysis(up: m.arrivalA, down: m.arrivalB, deltaMs: m.offsetSeconds * 1000)
}

func report(_ a: ProbeAnalysis, sampleRate: Double) {
    func line(_ label: String, _ arr: SyncProbeCorrelator.Arrival) {
        let ms = arr.sampleOffset / sampleRate * 1000
        print(String(format: "  %@ arrival  %8.2f ms into capture   confidence %5.1fx",
                     label, ms, arr.peakToSidelobe))
    }
    line("UP  (L)", a.up)
    line("DOWN(R)", a.down)
    print(String(format: "  Δ (down − up)  %+7.3f ms", a.deltaMs))
}

// MARK: - Selftest

if selftest {
    let rate = 44_100.0
    let up = SyncProbe.samples(.upSweep(sampleRate: rate, duration: duration))
    let down = SyncProbe.samples(.downSweep(sampleRate: rate, duration: duration))
    let delayUp = Int(0.180 * rate), delayDown = Int(0.1875 * rate)
    var scene = [Float](repeating: 0, count: Int((leadIn + 0.5 + duration) * rate))
    var seed: UInt64 = 9
    for i in 0..<scene.count {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        scene[i] = (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.1
    }
    let base = Int(leadIn * rate)
    for (delay, probe) in [(delayUp, up), (delayDown, down)] {
        for (i, s) in probe.enumerated() where base + delay + i < scene.count {
            scene[base + delay + i] += 0.3 * s
        }
    }
    guard let a = analyze(recording: scene, sampleRate: rate, leadInSeconds: leadIn) else {
        print("SELFTEST FAIL: probes not found in synthetic scene"); exit(1)
    }
    report(a, sampleRate: rate)
    let pass = abs(a.deltaMs - 7.5) < 0.5
    print(pass ? "SELFTEST PASS (expected Δ 7.5 ms)" : "SELFTEST FAIL (expected Δ 7.5 ms)")
    exit(pass ? 0 : 1)
}

// MARK: - Core Audio device lookup

func property(_ selector: AudioObjectPropertySelector,
              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func allDeviceIDs() -> [AudioDeviceID] {
    var addr = property(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = property(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
          let cf = name?.takeRetainedValue() else { return "device \(id)" }
    return cf as String
}

func transportType(_ id: AudioDeviceID) -> UInt32 {
    var addr = property(kAudioDevicePropertyTransportType)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
    return value
}

func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var addr = property(kAudioDevicePropertyStreamConfiguration, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
    let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { list.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size,
                                     list.assumingMemoryBound(to: AudioBufferList.self)) == noErr
    else { return 0 }
    let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func nominalRate(_ id: AudioDeviceID) -> Double {
    var addr = property(kAudioDevicePropertyNominalSampleRate)
    var value = 0.0
    var size = UInt32(MemoryLayout<Double>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
    return value
}

func defaultOutputID() -> AudioDeviceID {
    var addr = property(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &addr, 0, nil, &size, &id)
    return id
}

// MARK: - Resolve devices

// The SAME lookup the app's recorder uses — the spike exists to exercise the
// shipping capture path, not a parallel one.
guard let builtInMic = BuiltInMicRecorder.builtInMicrophoneID() else {
    fputs("No built-in microphone found — this tool never records any other input.\n", stderr)
    exit(2)
}

let outputID: AudioDeviceID
if let outputMatch {
    guard let id = allDeviceIDs().first(where: {
        channelCount($0, scope: kAudioObjectPropertyScopeOutput) > 0 &&
        deviceName($0).localizedCaseInsensitiveContains(outputMatch)
    }) else {
        fputs("No output device matching \"\(outputMatch)\". Outputs:\n", stderr)
        for id in allDeviceIDs() where channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0 {
            fputs("  \(deviceName(id))\n", stderr)
        }
        exit(2)
    }
    outputID = id
} else {
    outputID = defaultOutputID()
}

print("mic:    \(deviceName(builtInMic))  (\(Int(nominalRate(builtInMic))) Hz)")
print("output: \(deviceName(outputID))  (\(Int(nominalRate(outputID))) Hz)")

// MARK: - Mic permission

// A DispatchSemaphore here deadlocks: requestAccess's completion is queued
// onto the main dispatch queue, and this bare `main.swift` has no run loop
// draining it — sem.wait() blocks the one thread that would ever drain it,
// so the TCC dialog either never appears or never reports back, and the
// process hangs silently forever with no crash and no sound. Pumping the
// run loop instead lets the completion actually run.
var accessResult: Bool?
if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
    accessResult = true
} else {
    print("Requesting microphone access — look for the system permission " +
          "prompt (it can appear behind this window)…")
    AVCaptureDevice.requestAccess(for: .audio) { granted in accessResult = granted }
    let deadline = Date().addingTimeInterval(60)
    while accessResult == nil, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}
guard let accessGranted = accessResult, accessGranted else {
    if accessResult == nil {
        fputs("Timed out waiting for the microphone permission prompt. " +
              "Check System Settings › Privacy & Security › Microphone for a " +
              "pending request, or grant Terminal access there and re-run.\n", stderr)
    } else {
        fputs("Microphone access denied. Grant it to this terminal in System Settings › " +
              "Privacy & Security › Microphone and re-run.\n", stderr)
    }
    exit(2)
}

// MARK: - Playback (capture is the app's own BuiltInMicRecorder)

final class ProbePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let rate: Double

    /// `rate` is the pinned device's HAL nominal rate, passed in so it is the
    /// same number the sweeps were synthesized at — one rate for the whole
    /// tool rather than a second, independently queried one that can disagree.
    ///
    /// Both graph edges are connected explicitly at that format. Merely
    /// touching `mainMixerNode` connects it to the output node implicitly, at
    /// whatever format the output node happened to carry then, which a later
    /// device pin does not rebuild.
    init(deviceID: AudioDeviceID, rate: Double) throws {
        self.rate = rate
        try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
        engine.attach(player)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
    }

    /// Plays L/R and blocks until the buffer has been consumed. False means the
    /// device took the buffer and never reported playing it.
    func playBlocking(left: [Float], right: [Float]) -> Bool {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let frames = AVAudioFrameCount(max(left.count, right.count))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for (channel, source) in [(0, left), (1, right)] {
            let dest = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { dest[i] = i < source.count ? source[i] : 0 }
        }
        let sem = DispatchSemaphore(value: 0)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in sem.signal() }
        player.play()
        return sem.wait(timeout: .now() + Double(frames) / rate + 10) == .success
    }

    func stop() { engine.stop() }
}

let rateBefore = nominalRate(outputID)
let capture = BuiltInMicRecorder()
let captureRate: Double
do { captureRate = try capture.start() } catch {
    fputs("Could not open the built-in microphone: \(error)\n", stderr)
    exit(2)
}
Thread.sleep(forTimeInterval: leadIn)
let rateDuringCapture = nominalRate(outputID)

let outputRate = nominalRate(outputID)
guard outputRate > 0 else {
    fputs("Could not read a sample rate from \(deviceName(outputID)).\n", stderr)
    _ = capture.stop()
    exit(2)
}
var upOut = SyncProbe.samples(.upSweep(sampleRate: outputRate, duration: duration))
var downOut = SyncProbe.samples(.downSweep(sampleRate: outputRate, duration: duration))
for i in 0..<upOut.count { upOut[i] *= gain }
for i in 0..<downOut.count { downOut[i] *= gain }

do {
    let player = try ProbePlayer(deviceID: outputID, rate: outputRate)
    let played = player.playBlocking(left: upOut, right: downOut)
    Thread.sleep(forTimeInterval: 0.6)
    player.stop()
    if !played {
        fputs("\(deviceName(outputID)) accepted the probes but never reported " +
              "playing them. Check nothing else is holding the device, or pick " +
              "another --output.\n", stderr)
        _ = capture.stop()
        exit(2)
    }
} catch {
    fputs("Could not open the output device: \(error)\n", stderr)
    _ = capture.stop()
    exit(2)
}

let rateAfter = nominalRate(outputID)
let recording = capture.stop()

// MARK: - Verdicts

print(String(format: "captured %.2f s at %.0f Hz from the built-in mic",
             Double(recording.count) / captureRate, captureRate))

if rateBefore == rateDuringCapture && rateDuringCapture == rateAfter {
    print("HFP check: PASS — output stayed at \(Int(rateBefore)) Hz while the built-in mic recorded")
} else {
    print("HFP check: FAIL — output sample rate moved \(Int(rateBefore)) → " +
          "\(Int(rateDuringCapture)) → \(Int(rateAfter)) Hz (A2DP likely collapsed)")
}

let rms = sqrt(recording.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, recording.count)))
if rms < 1e-6 {
    fputs("Capture is silent (RMS ≈ 0). The classic cause is a missing/stale mic TCC grant " +
          "for this terminal — macOS delivers zeros instead of failing.\n", stderr)
    exit(2)
}

if let keepPath {
    recording.withUnsafeBufferPointer { buf in
        try? Data(buffer: buf).write(to: URL(fileURLWithPath: keepPath))
    }
    print("capture kept: \(keepPath) (mono Float32 @ \(Int(captureRate)) Hz)")
}

guard let analysis = analyze(recording: recording, sampleRate: captureRate,
                             leadInSeconds: leadIn) else {
    print("MEASUREMENT FAILED: no convincing probe arrivals in the capture.")
    print("Hints: raise --gain, quieten the room, move the Mac nearer the speaker(s),")
    print("or check the probes were audible at all.")
    exit(1)
}
report(analysis, sampleRate: captureRate)
print("Reminder: after a fresh Bluetooth connect, wait ~60 s before trusting a " +
      "measurement (the BT clock settles chaotically first — bt-spike-findings 2026-08-07).")
exit(0)
