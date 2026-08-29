# Chirp probe on the phone — port record

2026-08-29. Branch `claude/ios-chirp-probe`, off `claude/ios-staging`. Replaces
the phone's tick-grid probe DSP with the Mac's chirp measurement (roadmap 064,
`mic-probe-calibration-brief.md`). Prior state of the phone probe:
`bt-autocal-live-findings-2026-08-23.md` on `claude/bt-autocal-spike`.

**Nothing in this port has touched hardware, and none of it has ever run on a
phone** — not on a device, not in a simulator (there is no iOS runtime on this
Mac). Every claim below is either a carried-over live finding from one of those
two documents, or a statement about code, compiles and tests. There is no live
result here.

## What changed, and why

The phone's old probe measured a tick grid. The Mac muted the two speakers in
turn so the phone could tell whose tick it was hearing, the phone whitened the
capture PHAT-style and matched a tick pattern, and one run took about 45
seconds. It worked — validated on real hardware, hand-checked twice against raw
arrival grids — but 45 seconds of alternating mutes is a procedure, not a
measurement you can fire on a reconnect.

The Mac's chirp method gets the same number in two or three seconds, and the
saving is structural rather than an optimization:

- **Separation by frequency, not by muting.** The two speakers play
  *simultaneously* — a DOWN sweep (2000→500 Hz) on the reference fan-out, an UP
  sweep (3200→10000 Hz) on the Bluetooth fan-out. Disjoint bands with a guard
  gap between them; each sweep's matched filter is deaf to the other. Nobody has
  to be silenced to be identified, so there is no alternation and no mute
  choreography on the Mac. (Opposite sweep directions over a *shared* band
  separate only ~33 dB, which real level imbalance eats; disjoint bands measure
  −134 dB. That is why the bands are disjoint and not merely opposed.)
- **SNR weighting, not PHAT whitening.** Whitening throws away exactly the
  per-band signal-to-noise information that tells you which part of the capture
  to trust. The chirp analyzer divides by the ambient noise spectrum instead,
  and falls back to the plain matched filter when the ambient slice turns out to
  be useless — see the live-finding comment on `ProbeAnalyzer.analyze`.

The port is wholesale: the tick DSP is not kept as a fallback. Two measurement
paths for one number is two things to keep in sync and two ways to be wrong,
and the tick path's only advantage was that it existed first.

## What the phone adds over the Mac's own microphone

Two things, and they are worth being precise about because one of them is real
today and the other is not.

1. **The microphone can be at the listening position.** The Mac's mic is where
   the Mac is. Sync is a property of a point in the room, and the point that
   matters is the one with ears at it. A phone can be there.
2. **The Mac refuses Bluetooth-vs-Bluetooth pairs; a phone listener would not
   inherently have to.** The Mac's limitation is not about its microphone — both
   Bluetooth speakers share one fan-out, so both get the same lane and their
   arrivals are unattributable. A phone at the listening position hears two
   physically separate speakers and could in principle tell them apart. **This
   port does not build that.** Attributing two same-lane speakers needs
   per-speaker sequencing on the Mac — playing them one at a time, or assigning
   them different bands — which is new Mac staging, not a phone change. Recorded
   here as the reason the phone path is worth having, not as something it does.

## The new risk the Mac did not have: the microphone moves

Distance asymmetry costs about **2.9 ms per metre**. On the Mac that was a
footnote — the laptop does not wander, and an off-centre Mac is a fixed, small,
one-sentence-of-copy error. On the phone it is the dominant failure mode.

A phone at the sofa measures sync at the sofa, which is the answer you want. The
same phone held beside one speaker measures that speaker's arrival minus half a
room, and reports it with full confidence. **No property of the signal
distinguishes the two cases.** The correlation peaks are equally sharp, the
peak-to-sidelobe ratio is equally high, the run looks equally clean. The
analyzer cannot refuse a bad placement because there is nothing in the recording
that is bad.

This is therefore a UX problem and not a DSP one, and it must be solved where the
user is told what to do — before the run, in words, with the phone in their hand.
Do not go looking for a signal-side detector; there is not one to find.

## Two hand-copy hazards

Both are consequences of the package layout, recorded so the next person does not
discover them by measuring the wrong signal.

1. **`SyncProbeCorrelator.swift` is duplicated.** The original lives at
   `AudioutCore/Sources/AudioutCore/SyncProbeCorrelator.swift`; `ios/` may never
   depend on `AudioutCore`, so `ProbeKit` carries a verbatim copy. The Mac stages
   the sweeps this file *describes*, so a divergence is not a local bug — it is a
   phone matching against a signal nobody played, returning a confident wrong
   number. The file's own header says so; that note is the enforcement.
2. **`ProbeAnalyzer.sweepSeconds` is duplicated** from
   `AlignmentTickInjector.probeSweepSeconds` on the Mac. The Mac plays a sweep of
   that length and the phone renders one of its own to match against. Same
   failure shape as above, smaller surface.

**The standing fix for both is the same: invert the dependency.** Make
`AudioutCore` depend on `ProbeKit` rather than the other way round. `ProbeKit` is
license-clean, dependency-free (Accelerate and Foundation), and knows nothing
about app concepts — it is already shaped to be the shared bottom layer. Doing
that deletes the copy and the constant, and takes both hazards with it. It is not
done here because it is a Mac-side package change and no branch currently holds
both halves (below).

## Open item: an inherited crash, to be fixed on `main` FIRST

`SyncProbeCorrelator.correlate` returns `[]` when either `vDSP.DFT` initializer
returns `nil`, and `arrival` then indexes `corr[i]` across `0..<searchCount`
without checking `corr.count`. That is an index-out-of-range **crash**, not a
refusal — the one outcome this package is supposed to never produce.

It is inherited **verbatim** from `origin/main`, so it is not a porting defect.
But it is newly *reachable* on a phone. A 15 s tape at 48 kHz gives n = 2^20;
each `correlate` call transiently allocates about 11 `Float` arrays of that size
(~46 MB) plus four more inside `noiseWeights` (~16 MB), and `relativeOffset`
calls `correlate` twice per pass and up to four times across the
weighted-then-unweighted fallback. On macOS that allocation never fails. Under
iOS memory pressure (jetsam) it plausibly can, and the failure is a hard crash in
the middle of the wizard.

**Do not patch the phone's copy.** The hand-copy is only safe because it is
byte-identical to the Mac's file (see the hazards above); a local-only fix
destroys exactly that property and buys a crash-free phone at the cost of the
invariant that keeps the phone matching the signal the Mac actually plays. The
order is: fix it in `AudioutCore` on `main` — return a typed refusal when the DFT
setup fails, and make `arrival` guard on an empty correlation — then re-copy the
whole file here and re-verify byte-identity.

## Build state

**Built on this branch** (in the working tree, not committed):

- `ios/AudioutRemote/ProbeKit/` — the DSP package. Swift tools 6.0, iOS 17 /
  macOS 14, zero dependencies, one library product. `SyncProbeCorrelator.swift`
  (the hand-copy) and `ProbeAnalyzer.swift` (new: recording in, `offsetMs` +
  `confidence` out, or a typed refusal). **Tested: 24 tests in 2 suites, all
  passing**, run on macOS with `xcodebuild test -scheme ProbeKit -destination
  'platform=macOS'`. The package is pure DSP, so a Mac run exercises all of it.
- The phone-side capture leg and the run orchestration that drives it, in the
  app target. **Not tested — compile-verified only.** Its 4 tests
  (`ios/AudioutRemote/AudioutRemoteTests/ProbeSessionTests.swift`) have never
  been executed: they need an iOS destination, and this Mac has no iOS simulator
  runtimes installed (deliberately deleted to reclaim disk). The passing-test
  result above covers the package and nothing else — do not carry it across.
  Source files: automatic — the Xcode project's synchronized group picks up
  app-target sources with no `pbxproj` edit. The ProbeKit package reference: a
  real edit — the synchronized group does not cover package dependencies, so
  `AudioutRemote.xcodeproj/project.pbxproj` is modified in this diff to add the
  local package reference and link its product into the app target.

`ProbeKit` stays pure DSP on purpose — no audio I/O, no networking, no app
concepts. Capture and orchestration belong to the app, and the package tests stay
runnable with no device attached. Run them by copying the package out of the repo
(a hook blocks bare `swift test`, matching the command string anywhere) and:
`xcodebuild test -scheme ProbeKit -destination 'platform=macOS'`.

**Not built:**

- The protocol messages between phone and Mac for a chirp run.
- The Mac-side handler for them.
- The Mac staging a sweep run for a *phone* listener instead of its own
  built-in mic.

**Why the Mac half is blocked — a branch problem, not a design one.** No single
branch contains both halves:

- `claude/ios-staging` (this branch's base) has no mic-probe code at all. It is
  99 commits behind `main`, and the Mac's chirp work landed on `main`.
- The old phone probe's `ProbeKit` lived only on `claude/bt-autocal-spike`, which
  is 194 commits behind `main` and predates the Audiouter→Audiout rename — its
  tree still says `ios/AudiouterRemote`.

So the Mac half cannot be written until `main` is merged into `claude/ios-staging`,
and that merge is the owner's call, not an agent's. The phone half is built to
the Mac's *existing* staging contract precisely so that merge is the only thing
standing between here and being able to *write* the Mac half. An end-to-end run
is further off than that: it needs the Mac half written, and then a real phone
and real speakers, neither of which this port has seen.

## Constraints carried in (read before writing the capture leg)

- **`AVAudioSession` category `.record`, mode `.measurement`, and an EMPTY
  options set.** No `.allowBluetooth`, no `.allowBluetoothA2DP`, none of that
  family. Any of them collapses the Bluetooth speaker from A2DP to HFP —
  call-quality mono — and then the thing being measured is not the thing the user
  listens to. The whole measurement is invalid and it will not look invalid.
- **`setInputGain(1.0)` when `isInputGainSettable`.** `.measurement` mode
  disables automatic gain control, which is what we want, and the default input
  gain was measured too low to leave alone.
- **Probes stay inside 500 Hz – 10 kHz.** A2DP codecs roll off somewhere between
  14 and 18 kHz, unpredictably per device; small speakers roll off at the bottom.
  The usable window is narrower than it looks, and the two bands plus their guard
  gap have to fit inside it.
- **Bluetooth clocks settle roughly 60 s after connect.** A probe fired straight
  after a reconnect measures the settling, not the speaker.
- **Bluetooth latency re-rolls on every reconnect**, by up to hundreds of ms
  (−410 ms one session, ~46 ms the next, same pair). This is the finding that
  makes a fast probe worth porting at all: a static trim is valid per connection,
  nobody re-runs a by-ear wizard on every reconnect, and a two-second chirp per
  reconnect is something a person would actually tolerate.
- **The phone reports the raw measurement; the Mac owns trim semantics.** No sign
  convention, no trim arithmetic, no "which way does this go" on the phone.
  `offsetMs` is positive when the target (UP / Bluetooth lane) sounded late, and
  that is the whole of the phone's opinion.
- **Refuse rather than guess.** A wrong alignment number is worse than none —
  the user acts on it and then distrusts the feature. `ProbeAnalysisError` exists
  so a bad run has somewhere honest to go.

## Open question, carried over

**The Bluetooth sink's drift servo did not hold phase through a mid-stream
disturbance.** After an AirPods route-grab, the measured offset walked
17 → 61 → 86 ms over about eight minutes, while staying sub-millisecond stable
*inside* each individual probe window. Suspected re-anchor gap after a mid-stream
buffer step; compare the FLUSH re-anchor work, which handles dropouts.

This is not a probe defect and a better probe does not fix it. It invalidates any
trim over time, however that trim was arrived at — by ear, by tick, or by chirp.
It deserves its own investigation, and it should not be filed under probe work.
