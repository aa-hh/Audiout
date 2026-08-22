# Feasibility: phone-mic auto-calibration of Bluetooth sync trim

2026-08-22 · Branch `claude/bluetooth-speaker-delay-feasibility-f3474a` · Analysis only, no code.
Companion to `companion-app-bt-autocal-feasibility-handoff.md` (research notes) and
`docs/plans/PLAN-UNIVERSAL-SYNC.md` (the BT sync design record).

## Verdict: FEASIBLE WITH CAVEATS — worth a spike, with one design change from the original idea

The idea as posed — phone triggers a tone, phone times how long until it hears it —
is **not** feasible: the phone→Mac→speaker round trip has too much unknown, variable
delay to time against. But a variant that measures **sound against sound instead of
sound against a network message** removes the round trip from the math entirely.
That variant is feasible, fits the existing architecture with no structural changes,
and its open risks are all checkable with a cheap spike before committing to build.

## Why the round-trip problem is real — and why the fix isn't "measure the jitter"

The trip is: phone sends command (WebSocket, LAN) → Mac schedules audio → Bluetooth
A2DP stack (~100–200 ms, varies per speaker and per connection) → air → phone mic.
Timing "command sent" to "sound heard" measures the sum of all of those, and the
Bluetooth stack portion alone varies by more than the ±few-ms accuracy that matters.
There is no RTT/jitter telemetry on the companion WebSocket today (checked: pings are
keep-alive only, nothing is timed), and none is needed — because the right design
never times anything against the network.

**Key reframe: the trim is a *relative* number.** It aligns the Bluetooth speaker
against the reference device (AirPlay speaker or Mac). So the phone doesn't need to
know *when* a sound was sent — it only needs the **difference** in arrival time
between the reference speaker's tick and the Bluetooth speaker's tick, both landing
in the same continuous recording on the same mic. Every shared delay — network,
scheduling, the phone's own mic latency, the phone's clock offset — cancels in the
difference. This is the same cancellation trick the `--drift-meter` spike already
proved on this exact hardware (two tones, one recording, mic clock cancels).

## Recommended design: alternating-mute tick probe

All existing machinery, one new orchestration layer:

1. Phone taps "Auto-align" for one Bluetooth device. Mac starts a probe session:
   the existing `AlignmentTickInjector` wizard mode (ticks + keep-alive bed +
   wake preamble) into the shared capture feed — every sink renders the identical
   tick through its real delay chain, exactly as the by-ear wizard does today.
2. The Mac alternates **per-device mute** (already a core feature) in known
   beat-aligned blocks: reference device audible for beats 1–4, target Bluetooth
   device audible for beats 5–8, repeat. One speaker at a time is ticking.
3. The phone records continuously (built-in mic, one take) and matched-filters
   against the known tick template — the tick is synthesized deterministically on
   the Mac, so the template can be shipped in the iOS app or sent once over the
   socket; it never needs to be timed, only *known*.
4. Each detected tick's arrival time, taken **modulo the beat period**, gives that
   speaker's phase on the shared tick grid. (Reference phase) − (target phase) =
   the target's alignment error. Beat spacing already dodges ±500 ms aliasing —
   the injector's 72 BPM / ~833 ms default was chosen for exactly this.
5. New trim = current trim − measured error, put through `BTSyncTrim.quantise`
   (whole ms, clamp ±500) — the same single contract the manual drawer and wizard
   write through. Phone sends it over the existing companion socket as one new
   command; the WebSocket carries only control ("start probe", "here's the
   result"), where even a second of slop is harmless.

Averaging over ~8–16 ticks per speaker (~15–30 s total, inside the injector's
existing budget) beats down room noise and any per-beat Bluetooth jitter.

### Why alternating mute and not two distinct signals

The drift meter used a different tone per speaker — but it had per-device engines.
The production tick injector mixes into the **single shared feed before fan-out**;
per-device distinct signals are structurally impossible there (documented in the
injector itself, re the shared bed). Alternating mute gets per-speaker identity
using controls that already exist, with zero architecture change.

### Algorithm: matched filter with PHAT-style whitening. Not LMS.

- Plain cross-correlation against the tick template is the baseline; in a real
  room, reflections smear the peak.
- **GCC-PHAT** (whiten the spectrum before the inverse FFT) sharpens the direct-path
  peak under reverb at no real extra cost once an FFT is in play, and pairs with
  "pick the earliest strong peak" (direct path arrives before reflections). This is
  the recommendation.
- **Adaptive LMS solves a different problem** — continuously *tracking* a
  time-varying delay. The continuous drift servo already exists (`SyncCore` PI loop
  from the device's real DAC clock) and Alec asked about trim, the static offset.
  LMS is scope creep; explicitly out.

## Why this dodges the objection that killed Mac-mic auto-offset

Alec cut the Mac-mic version (Decision 4 amendment, 2026-08-07) for two reasons:
the Mac's mic position is uncontrollable, and it can't tell which speaker is which.

- **Position:** the phone is movable and the flow can *instruct* placement —
  "stand about halfway between the speakers." Geometry error is ~3 ms per meter of
  path-length difference (speed of sound), so even a sloppy ±1–2 m gives ±3–6 ms —
  inside the "within a couple of ms two speakers sound identical" band from the
  trim-resolution finding. Different-rooms setups (the Mac-mic worst case) become
  the *instruction*, not the failure: walk to where you can hear both.
- **Identity:** solved deterministically by mute-alternation — the probe knows
  which speaker is audible in which beat block. Nothing is inferred.

Also note: the A2DP→HFP trap that haunted the Mac-mic design does not apply — the
phone opening its **own built-in** mic is a different device's audio session with no
interaction with the Mac↔speaker A2DP link. (One self-inflicted version does exist;
see caveat 3.)

## Caveats — what a spike must prove before any production build

1. **iOS input processing.** `AVAudioSession` mode `.measurement` is supposed to
   disable AGC/voice processing on the input. Verify on the actual iPhone 15 Pro
   (the only test device) that the recorded tick keeps a sharp, un-mangled
   transient. This is the iOS analog of the "never VoiceProcessingIO" rule the
   drift meter learned on macOS.
2. **Per-beat Bluetooth latency stability.** The trim only holds if the speaker's
   chain delay is stable beat-to-beat within a probe. The drift meter found
   speakers settle to a few ppm *after warm-up* (Sonos: ~40 s of chaos first).
   The probe must warm the target up (extend the existing keep-alive-bed preamble)
   and should report spread across ticks — high spread → low confidence → fall
   back to the wizard, mirroring the wizard's own "can't tell" graceful exit.
3. **Phone-side Bluetooth routing trap.** If the same speaker (or AirPods) is
   paired to the *phone*, a careless session category could route the phone's
   input/output over Bluetooth — at worst forcing the target speaker into HFP
   *from the phone's side*, corrupting the very stream being measured. The session
   must pin category `.record`, no Bluetooth options, `preferredInput` = built-in
   mic. Same family as the drift meter's "never the default input" rule.
4. **Mic permission is unbuilt.** The iOS app has no microphone usage string,
   permission flow, or `AVAudioSession` code at all today (grep-confirmed on
   `ios-staging`). Plumbing, not risk — but it's real work including the TCC flow.
5. **Accuracy headroom.** Expected error budget: geometry ±3–6 ms, detection
   ±1–2 ms with PHAT on a clean transient, quantized to whole ms. That should land
   within the inaudibility band and roughly match ~9 rounds of by-ear bisection —
   the spike should confirm against a wizard-tuned baseline on real hardware. If it
   can't beat "audibly aligned," it's a toy.

## What it buys, honestly

The wizard already converges in ~9 answers. Auto-cal turns ~1–2 minutes of
attentive listening into ~20–30 s of holding the phone up — per speaker. Real but
modest for one speaker; compounding for multi-speaker setups, and it covers users
who genuinely can't judge the flam. Manual trim and the wizard remain the shipping
story and the fallback (the "manual-only is a complete product" finding stands);
this is an accelerator, not a replacement.

## If Alec says go — spike shape (est. 1–2 days, two worktrees)

- **Mac side** (fresh worktree off `main`): probe session — tick run + beat-aligned
  mute alternation + two companion message types (start/stop probe, submit trim).
  Reuses `AlignmentTickInjector`, mute paths, `BTTrimStore`.
- **iOS side** (on `ios-staging`, never here): mic permission + `.measurement`
  record session + template matched-filter (Accelerate/vDSP FFT) + modulo-period
  phase math. Port the peak-picking/noise-floor lessons from `DriftMeterProbe.swift`
  (`git show b35b8737:dev/bt-multi-spike/Sources/bt-multi-spike/DriftMeterProbe.swift`).
- **Gate:** spike measures ≥2 real speakers against wizard-tuned baselines;
  written finding + go/no-go checkpoint before any production UI — the same gating
  `BT-SPIKE-OFFSET` had.
