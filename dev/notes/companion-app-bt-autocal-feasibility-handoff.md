# Companion-app Bluetooth auto-calibration — feasibility research handoff

Branch: `claude/bluetooth-speaker-delay-feasibility-f3474a` (worktree, clean, no commits
yet — this document is the only output so far). Started 2026-08-22.

## The ask

Alec's idea: give the iPhone companion app a feature that speeds up setting a Bluetooth
speaker's sync trim. The phone triggers a test sound (via the Mac, since the phone
doesn't own the speaker), the phone's own mic records it, and the app computes the
delay automatically using cross-correlation / GCC-PHAT / adaptive filtering (LMS) —
instead of the current by-ear wizard. He explicitly flagged the round-trip problem:
phone → Mac → speaker → (air) → phone mic, and asked for a feasibility analysis, not
an implementation.

**No analysis was delivered yet.** The prior agent (a Fable/Opus session, per the
`/model claude-sonnet-5` switch and "this agent failed" framing) spent its whole run on
research/grounding and never produced the actual feasibility writeup. This document
captures what it found, so the next session can go straight to writing the analysis
(or building a spike) instead of re-reading the codebase.

## What's already in the codebase (don't re-derive these)

**The existing BT sync answer is manual, by-ear, and this was a deliberate, already-
litigated decision** — see `docs/plans/PLAN-UNIVERSAL-SYNC.md`:

- **Auto-offset via the Mac's own mic was already scoped, spiked, and explicitly CUT**
  by Alec (Decision 4 amendment, 2026-08-07): *"The Mac's mic position is
  uncontrollable — it may not hear all speakers (different rooms is our GOOD case) and
  can't identify which speaker is which."* `BT-SPIKE-OFFSET` and `BT-OFFSET-AUTO` were
  removed from the task list. This is the single most important precedent for the new
  ask — the phone-mic idea is a variant of an idea Alec already killed once, for a
  different but related reason (mic placement/identity), and the feasibility analysis
  needs to explain why a phone mic does or doesn't dodge that objection.
- **The mic-open HFP trap is real and load-bearing**: opening *the Bluetooth speaker's
  own* mic force-downgrades it from A2DP (stereo/wideband) to HFP (narrowband, call
  quality) on macOS, corrupting any playback-during-record probe. The mitigation the
  team already validated is to record on a **different** mic than the one attached to
  the speaker being measured — which is structurally what "phone mic instead of Mac
  mic" is. This is actually a point *in favor* of feasibility that's worth checking
  against real hardware behavior (does the same A2DP/HFP flip apply if a phone, not
  the Mac, opens its own unrelated mic? Almost certainly no interaction at all, since
  it's a different device's Bluetooth session — but state that explicitly rather than
  assuming).
- **What shipped instead**: `BTAlignmentWizardSession.swift` +
  `BTAlignmentBisection.swift` — a which-side bisection wizard. It plays a synthesized
  tick (via `AlignmentTickInjector.swift`) mixed into the **shared whole-system
  capture feed**, post-capture, so every sink (AirPlay, Mac-local, every BT device)
  renders the identical tick through its own real delay pipeline. The user says which
  speaker they heard the tick from first ("target" vs "reference" vs "can't tell"),
  and the bisection halves a ±500 ms bracket toward the answered side. Converges in
  ~9 answers from a full ±500 ms range width floor. This is the mechanism the new
  phone-mic feature would compete with/accelerate, not replace outright (manual trim
  UI stays as the escape hatch either way, per the "manual-only is a complete product"
  finding in the plan).
- **Trim storage/contract**: `BTTrimStore.swift` / `BTSyncTrim` — signed ms, ±500 ms
  range, whole-ms resolution (sub-ms precision was tested and found inaudible/pointless
  — "within a couple of milliseconds two speakers sound identical"). Any auto-cal
  result needs to round to this same resolution and clamp to this same range; it's the
  single existing contract every trim-setting path (manual drawer, wizard, and any new
  auto-cal) must agree with.
- **Acoustic drift measurement precedent — `--drift-meter`**: a throwaway CLI spike
  (`dev/notes` references, commits `b35b8737` / `efb67775`, in the abandoned
  `bt-multi-spike` tool, never merged) already did real acoustic cross-correlation
  work on this exact hardware class: it measured **inter-speaker Bluetooth clock drift
  acoustically** and found real speakers settle to a few ppm after a device-dependent
  warm-up window (Sonos: ~40s of chaos then clean; Sony: clean from t=0). This is the
  closest existing precedent for "do acoustic timing measurement against real BT
  speakers on this hardware" and is worth reading (`DriftMeterProbe.swift` in that
  spike, not on any current branch — would need `git show b35b8737:...` to pull it)
  for its cross-correlation implementation approach, noise floor handling, and the
  "amp power-gates after silence, ticks get swallowed" pitfall it discovered (the SAME
  pitfall `AlignmentTickInjector`'s keep-alive bed exists to work around).
- **Companion transport**: `CompanionServer.swift` — Bonjour-advertised WebSocket
  server (`NWListener`/`NWConnection`) the iPhone app talks to; `CompanionCommandDispatcher.swift`
  handles incoming commands, `CompanionSnapshotBuilder.swift` pushes state out. This is
  the existing channel a "phone triggers a test tone" command and a "phone reports
  measured delay" command would ride on — no new transport needed, just new message
  types. iOS side lives on `claude/ios-staging` (separate long-lived worktree, per
  root `CLAUDE.md` — **do not build iOS UI in this worktree**, switch to
  `.claude/worktrees/ios-staging`, `git pull` first if stale).

## What was NOT yet checked (the actual remaining feasibility questions)

The prior session ran out before doing the hardware/systems analysis. These are the
open questions the feasibility writeup needs to answer:

1. **The round-trip latency problem Alec named explicitly.** Phone-triggers-tone
   requires: phone → Mac (network hop, WebSocket) → Mac plays tone → speaker (A2DP
   Bluetooth, ~100-200ms typical stack latency, variable) → air → phone mic capture
   → cross-correlate. Every one of those hops adds latency AND, more importantly,
   **jitter** (variance run-to-run). Cross-correlation only needs the round trip to be
   *stable* within one measurement window, not zero — but if phone→Mac network jitter
   is comparable to or larger than the ~10-50ms trims being measured, naive
   cross-correlation of "trigger sent" to "sound heard" is measuring the wrong thing
   entirely. **This needs a real number**, not a guess: what's actual observed
   jitter on the existing `CompanionServer` WebSocket path? Is there existing telemetry
   or timestamp-round-trip logging to check, or does this need a fresh instrumented
   spike?
2. **The reference-signal fix that likely solves #1**: the phone doesn't need to
   time against when it *sent the trigger* — it can instead record continuously and
   cross-correlate the recorded audio against **a known reference signal already
   present in the shared tick feed** (the same tick every sink already plays, per
   `AlignmentTickInjector`). If the phone can also hear the Mac's own reference
   rendering (e.g., via companion WebSocket streaming a copy of the tick's exact
   playout timestamp, or literally also recording the Mac's speaker if colocated) then
   the network round-trip becomes irrelevant — you're doing sound-to-sound
   cross-correlation (phone mic vs. reference audio), not command-round-trip timing.
   This is analytically the more promising design and should be the one evaluated in
   depth; needs to be spelled out with the actual signal path.
3. **Phone mic placement/identity — does it dodge the reason Alec cut the Mac-mic
   version?** Alec's objection to Mac-mic auto-offset was mic placement (can't hear
   all speakers, can't tell which is which). A phone is *movable* — the user could be
   asked to stand between/near the speaker being calibrated, which is actually a
   **strength** relative to the fixed Mac mic, not a shared weakness. This should be
   the central "why this is different from the thing we already rejected" argument in
   the writeup, but it needs to be stated explicitly, not assumed.
4. **iPhone mic/AVAudioSession practicalities**: background audio permission,
   `AVAudioSession` category needed to record while other audio may be playing,
   whether iOS ducks/AGCs the input (which would corrupt amplitude-sensitive
   cross-correlation the same way macOS's HFP flip does), and whether the existing
   companion app already requests microphone permission (grep in ios-staging came back
   empty for `NSMicrophone`/`AVAudioSession`/mic-related strings — **this permission
   does not exist yet in the iOS app and would need to be added**, including the
   Info.plist usage-description string and TCC prompt flow).
5. **GCC-PHAT vs plain cross-correlation vs LMS — which is actually warranted here.**
   Alec's message proposes all three. The feasibility writeup should give a real
   recommendation, not just accept the menu:
   - Plain cross-correlation: fine if SNR is decent and there's no significant
     multipath/reverb — likely NOT fine for real rooms per the `--drift-meter` spike's
     own experience with reflections.
   - GCC-PHAT: the standard fix for exactly the reverb problem — almost certainly the
     right one-shot algorithm for the initial delay/offset measurement, no real
     downside vs plain cross-correlation once you're already doing an FFT.
   - Adaptive LMS: solves a **different** problem (continuously *tracking* a slowly
     time-varying delay), not one-shot offset calibration. This only matters if the
     feature is meant to also replace/inform the continuous drift-correction PI loop
     that `BTSyncedSink`/`SyncCore` already runs from the BT device's real DAC clock —
     which would be **scope creep beyond what Alec asked** (he asked about "trim", i.e.
     the static per-device offset the wizard sets, not the continuous drift servo).
     The writeup should flag this distinction clearly so scope doesn't quietly expand.
6. **What accuracy actually matters.** Per `BTTrimStore`'s own documented finding,
   sub-few-ms differences are inaudible and whole-ms resolution is already overkill.
   Phone mic hardware + iOS audio stack round-trip latency (mic ADC latency,
   `AVAudioSession` I/O buffer duration) has its own fixed floor — needs to be checked
   against Apple's typical figures (usually single-digit ms with default buffer sizes,
   but worth confirming for the iPhone 15 Pro specifically, since
   [ios-testing-on-physical-phone-only.md] memory says that's the only device tested
   on) to confirm the phone-mic path even has enough precision headroom over the
   existing by-ear wizard to be worth building.

## Recommended next steps for whoever picks this up

1. Read `docs/plans/PLAN-UNIVERSAL-SYNC.md` in full (not just the grep hits above) —
   it's the authoritative design doc for all BT sync/offset work and has sections this
   summary didn't quote (hot-files list, wave plan, risk register).
2. Pull `DriftMeterProbe.swift` from commit `b35b8737` (`git show b35b8737:AudiouterCore/Sources/bt-multi-spike/DriftMeterProbe.swift` — path may need adjusting, spike lived in a since-removed package) to see the existing cross-correlation implementation and its real-hardware lessons (amp power-gating, reflection handling) before writing new DSP.
3. Answer the round-trip/jitter question (item 1/2 above) with either existing
   telemetry or a small instrumented spike on `CompanionServer` — this is the crux of
   Alec's own stated worry and the feasibility verdict likely hinges on it.
4. Write the actual feasibility analysis as a short brief (verdict: feasible /
   feasible-with-caveats / not feasible, plus the recommended design — almost
   certainly "reference-signal cross-correlation via the existing tick feed" per item
   2, using GCC-PHAT, NOT LMS, NOT Mac-mic) and get Alec's go/no-go before writing any
   code. Nothing should be built until that checkpoint, matching how `BT-SPIKE-OFFSET`
   was gated in the original plan.
5. If it proceeds to a spike: needs work in **two** worktrees — DSP/companion-protocol
   additions here or in a fresh worktree off `main`, and the iOS-side mic capture +
   permission work on `.claude/worktrees/ios-staging` (per root CLAUDE.md, iOS work
   never happens outside that branch).

## Session log (for context, not action items)

- Read: `docs/plans/PLAN-UNIVERSAL-SYNC.md` (Decision 4/Q-OFFSET-AUTO/Q-SYNC-CLOCK
  sections), `dev/notes/bt-spike-findings-2026-08-07.md`,
  `BTAlignmentWizardSession.swift`, `BTAlignmentBisection.swift`,
  `AlignmentTickInjector.swift`, `BTTrimStore.swift`.
- Located (not yet read in full): `CompanionServer.swift`,
  `CompanionCommandDispatcher.swift`, `CompanionSnapshotBuilder.swift` in
  `ios-staging` worktree; drift-meter spike commits `b35b8737`/`efb67775`.
- Confirmed no `NSMicrophone`/`AVAudioSession` mic strings anywhere in the current
  `ios-staging` iOS app — mic capture is unbuilt there.
- No code written, no files changed other than this handoff note. Worktree is clean.
