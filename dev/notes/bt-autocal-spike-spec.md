# BT auto-cal spike — binding spec for the three build tracks

2026-08-22 · Base branch `claude/bt-autocal-spike` (off `claude/ios-staging`; the
companion server exists only there). Design rationale:
`dev/notes/companion-bt-autocal-feasibility.md` on
`claude/bluetooth-speaker-delay-feasibility-f3474a` — this file is the build
contract, that one is the why.

**Goal:** prove the alternating-mute tick probe end-to-end: phone records, DSP
recovers the target speaker's alignment error vs a reference device, Mac applies
the corrected trim. Gate: self-tests prove the math; the live hardware measurement
(≥2 speakers vs wizard-tuned baselines) is Alec-run afterwards.

**Spike, not product:** debug-surface UI only, no onboarding, no polish. But the
DSP and session sequencing are real — they graduate if the spike passes.

## Tracks and ownership (no file overlap)

| Track | Branch | Owns | Model |
|---|---|---|---|
| A `mac` | `claude/bt-autocal-mac` | `AudiouterCore/` only: ProbeSession, mute alternation, 3 new companion commands, trim math, tests | opus |
| B `dsp` | `claude/bt-autocal-dsp` | `ios/AudiouterRemote/ProbeKit/` only: standalone SwiftPM package — analyzer + synthetic self-tests | opus |
| C `iosui` | `claude/bt-autocal-iosui` | `ios/AudiouterRemote/` app: mic permission, capture session, debug probe screen, iOS-side protocol, pbxproj wiring + a ProbeKit STUB | sonnet |

C's stub ProbeKit (exact API below, bodies `fatalError`/dummy) exists only so C's
build check compiles; at reconciliation B's package replaces it file-for-file
while C's pbxproj wiring survives. Mark every stub file `// SPIKE STUB — replaced
by dsp track at merge`.

## Probe audio pattern (BINDING constants — all three tracks depend on these)

- Tick source: existing `AlignmentTickInjector`, continuous run like the wizard's
  (`replacesProgram: true`, bed on), default 72 BPM → beat period **P = 60/72 s
  ≈ 833.33 ms**. The tick reaches every sink through the shared feed — unchanged.
- Timeline after `startAlignmentProbe`:
  1. **Preamble ~5 s**: bed only (injector preamble), BOTH devices unmuted — wakes
     power-gated amps (Sonos trap).
  2. **3 repetitions** of: `[REF block: 6 ticks] [gap: 2 beats] [TGT block:
     6 ticks] [gap: 2 beats]`. During a REF block the target device is muted and
     the reference audible; TGT block is the inverse; gaps mute both.
  3. Restore all prior mute/volume state on every exit path (finish, cancel,
     error, timeout). Total ≈ 45 s; hard session timeout 90 s.
- Mute switching is wall-clock scheduled from run start (±200 ms accuracy is
  fine); a clipped boundary tick is expected — the analyzer discards the first
  tick of every block and any low-quality tick.
- The phone starts recording BEFORE sending `startAlignmentProbe`, so the
  recording always contains the pattern from the top: **first detected block =
  REF**, then strict alternation. No cross-device clock is ever compared.

## Measurement math (Track B implements; A and C must not re-derive)

- Detect ticks by matched filter: cross-correlate the recording against the known
  tick template with **PHAT-style spectral whitening**; within each correlation
  burst pick the **earliest strong peak** (direct path beats reflections).
- Template: re-synthesize the injector's tick (two decaying sine partials,
  parameters in `AlignmentTickInjector.swift` — read it, replicate exactly) at the
  recording's sample rate.
- Cluster arrivals into blocks (gap > 1.2 × P splits). Validate against the
  expected pattern; mismatch → structured error, never a guess.
- Per block: least-squares fit the tick grid `t_i = a + iP` (P known); block
  phase = `a mod P`.
- Per adjacent REF→TGT pair k: `δ_k = centeredMod(phase_tgt − phase_ref, P)` in
  (−P/2, P/2] — unambiguous over ±416 ms (fine: residual errors are tens of ms;
  noted limitation).
- Result: `offsetMs = mean(δ_k)` — **positive = target sounds LATE relative to
  reference**; `spreadMs = max |δ_k − offsetMs|`; `confident = (≥2 valid pairs
  && spreadMs ≤ 3.0)`.
- The phone reports the RAW measurement only. **The Mac owns trim semantics**
  (Track A verifies the sign against actual sink consumption + wizard convention
  and encodes it in ONE place): `newTrim = BTSyncTrim.quantise(currentTrim ∓
  offsetMs)` — A determines the sign from code, documents it at the call site,
  and unit-tests it.

## ProbeKit API (BINDING — B implements, C consumes, stub must match verbatim)

Package `ios/AudiouterRemote/ProbeKit/` — `Package.swift` name `"ProbeKit"`, one
library product `ProbeKit`, platforms `[.iOS(.v17), .macOS(.v14)]`, dependency-free
(Accelerate via `import Accelerate`).

```swift
public struct ProbePattern: Sendable {
    public let beatPeriodSeconds: Double   // 60/72
    public let ticksPerBlock: Int          // 6
    public let gapBeats: Int               // 2
    public let repetitions: Int            // 3
    public static let spike: ProbePattern  // exactly the constants above
}

public struct ProbeAnalysis: Sendable {
    public let offsetMs: Double      // positive = target late vs reference
    public let spreadMs: Double
    public let usedPairs: Int
    public let confident: Bool
}

public enum ProbeAnalysisError: Error, Sendable {
    case noTicksDetected
    case patternMismatch(detail: String)
    case insufficientPairs(found: Int)
}

public struct ProbeAnalyzer: Sendable {
    public init(sampleRate: Double, pattern: ProbePattern)
    public func analyze(recording: [Float]) throws -> ProbeAnalysis
}
```

B's self-tests (`swift test` inside the package — the run-tests.sh wrapper doesn't
know this package; a seconds-long local run is the accepted deviation): synthetic
recordings at 48 kHz and 44.1 kHz built from the same template synthesis —
known offsets (+37.4 ms, −112 ms), white noise at ~10 dB SNR, one simulated
reflection (+8 ms, −6 dB), random lead-in padding. Assert recovery within
±1.0 ms and `confident`. Negative cases: silent target → `insufficientPairs` or
not-confident; pure noise → `noTicksDetected`. A sign-convention test is
mandatory (injected "target late" must yield positive `offsetMs`).

## Companion protocol additions (BINDING names/fields; each side follows its
existing encoder/decoder conventions — read the current code first)

Commands (phone → Mac):
- `startAlignmentProbe` — `targetDeviceID: String`, `referenceDeviceID: String?`
  (nil = Main Out is the reference).
- `cancelAlignmentProbe` — no fields.
- `submitProbeResult` — `targetDeviceID: String`, `offsetMs: Double`,
  `spreadMs: Double`, `confident: Bool`. Mac computes + persists the new trim
  (BTTrimStore path — same contract as the wizard) only when `confident`;
  otherwise log + ignore (phone UI already told the user).

State (Mac → phone): add a minimal probe status to the snapshot
(`alignmentProbe: { targetDeviceID, state: running|idle }`) so the phone can show
progress and detect Mac-side abort. Keep it as small as the snapshot conventions
allow.

Track A also enforces: target must be a Bluetooth device with a live sink;
reference must be audible and ≠ target; reject otherwise with the dispatcher's
existing error convention. Rate-limiter: register the new commands however
`CompanionCommandRateLimiter` expects.

## Track C specifics

- `NSMicrophoneUsageDescription` in Info.plist + permission request flow (first
  probe run), graceful denied-state UI.
- Capture: `AVAudioSession` category `.record`, mode `.measurement`, **no
  bluetooth options**, `preferredInput` = built-in mic (the phone must never open
  a Bluetooth input — it could HFP-kill the very speaker being measured).
  `AVAudioEngine` input tap → mono Float32 buffer at the session rate; 90 s cap.
- Debug screen (follow the app's existing debug-surface conventions — Settings →
  the same area as "Replay Intro"): pick target (BT devices) + reference from the
  snapshot's device list, Start = begin capture THEN send `startAlignmentProbe`,
  show status, on pattern completion stop + run `ProbeAnalyzer`, show
  offset/spread/confidence, Apply → `submitProbeResult`, Discard. Cancel path
  sends `cancelAlignmentProbe`.
- Verify: `xcodebuild build` (generic iOS destination, `CODE_SIGNING_ALLOWED=NO`)
  compiles with the stub ProbeKit.

## Rules for every track

- Work ONLY in your own worktree; never touch `.claude/worktrees/ios-staging`
  (it has another session's uncommitted edits) or the main checkout.
- Commit on your branch; push to `origin/<your branch>` when done. Never merge
  anywhere — reconciliation is the coordinator's job.
- Track A: verify with `bash scripts/build.sh` and `bash scripts/run-tests.sh
  --filter <your new suite>`; never bare `swift build`/`swift test` for
  AudiouterCore.
- Read the nearest `AGENTS.md` before editing in any folder.
