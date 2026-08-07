# Bluetooth output (roadmap 004) — pre-build research, 2026-08-07

Fresh outside research requested by Alec before starting roadmap 004, layered on top of
`docs/plans/PLAN-UNIVERSAL-SYNC.md` (2026-07-24, 6 decisions locked) and the July
multi-BT feasibility research. Three web-research agents: Airfoil/PairPods prior art,
per-device delay UX survey, BT+AirPlay sync techniques. Local state re-verified same day.

## Local state (verified 2026-08-07)

- **Decision-6 gate is CLEARED**: the synced-local engine landed on `main` —
  `SyncedLocalSink.swift` + `PhaseController.swift` (delay-to-reference scheduling +
  PI drift loop + resampler) plus tests. BT builds on this, as planned.
- **Spike is committed**: `claude/bt-multi-spike` @ 09f99180 (`dev/bt-multi-spike/`,
  8 files). BT-SPIKE-COMMIT is effectively done.
- **License chore stands**: `SyncedLocalSink.swift` and `PhaseController.swift` are
  `GPL-2.0-or-later`-headered. Decision 5 (clean-room `SyncCore` extraction for the
  Apple-only BT sender file) is still owed before BT-SINK.
- Competitor sweep (roadmap 003, `dev/notes/competitor-parity-research-2026-08-05.md`)
  already ranked **per-device delay trim as the #1 table-stakes gap** and BT-in-group
  as a differentiator Airfoil ships.

## 1. Prior art — how existing apps do it

### Airfoil (Rogue Amoeba) — closest commercial precedent
- BT supported since v5 (2016), consumed as **plain CoreAudio output devices** (user
  pairs in System Settings; Airfoil offers whatever the OS exposes). Same shape as our
  plan's enumeration approach.
- **Sync = delay-to-worst**: everything is delayed to the highest-latency output.
  Published figures: local "virtually no delay", AirPlay 2 s, Chromecast 2 s, BT
  "variable, generally not exceeding two seconds". No auto-calibration of any kind.
- **Per-device delay UX**: per-speaker "Sync" sliders in a secondary *Advanced Speaker
  Options* window (deliberately out of the main UI; "most users will not need to adjust
  this"). Units = seconds. Ranges by transport: local & BT **add-only up to +1.00 s**
  (they're the earliest outputs — you can only push them later); AirPlay/Cast **±1.00 s**
  (Airfoil controls those buffers). Snap-to-default-0. Persisted.
- **Published honesty**: a constant offset "won't be able to correct things permanently"
  if a device's latency *fluctuates* — Rogue Amoeba concedes permanent BT sync is
  impossible in that case. Mirror this in our UX copy.
- Sources: rogueamoeba.com KB `AudioDelaysAndSync`, manual `advancedfeatures` +
  `supportedoutputs`, release notes.

### PairPods (MIT, macOS) — the zero-effort floor
- One **stacked CoreAudio aggregate device** (`AudioHardwareCreateAggregateDevice`,
  `kAudioAggregateDeviceIsStackedKey`, `kAudioSubDeviceDriftCompensationKey: 1` on
  non-master members, user-selectable master clock). No per-device delay, no latency
  queries, no runtime monitoring.
- Its main real-world complaint is **sample-rate mismatch pitch-warp** (44.1 vs 48 kHz
  members), not sync. Confirms our July rejection of the aggregate as primary path
  (no per-device volume/delay, can't include AirPlay) while noting the OS drift
  compensation itself basically works for casual use.
- Apple's own Multi-Output "Drift Correction" = **resampling to the clock-source
  device, rate drift only** — it does nothing about static latency offsets between
  members (docs + user reports: BT members still sit ~150–250 ms off). Our per-device
  offset + drift loop genuinely does something the OS doesn't.

## 2. Per-device delay adjustment — industry design patterns

Surveyed: Google Home group delay correction, snapcast, Music Assistant/Sendspin,
SoundSeeder, AmpMe, AudioRelay, AVR lip-sync (Denon/Yamaha), Roon, LMS.

Convergent pattern (near-universal):
1. **One signed per-device offset in ms, applied live, persisted per device.** The
   value belongs to the *device*, not the group; applies in every group; no effect solo
   (Google's scope rule). Snapcast issue #476's lesson: the offset must survive every
   other state change (theirs was forgotten after a volume change).
2. **Range**: consumer ±200–500 ms (Google ~200 — users hit the cap and complain;
   SoundSeeder ±400; AVRs 0–500); pro/OSS up to ±1000 (Roon, snapcast). BT's real
   100–400 ms spread sits comfortably inside **±500 ms**.
3. **Steps**: 1 ms where a numeric field exists; **10 ms is the practical by-ear step**
   (SoundSeeder). SoundSeeder documents the only published guided flow: probe ±100 ms
   to learn direction, then walk in 10 ms steps. **Show the number** — Google's blind
   unlabeled slider is its top complaint (and bare numerals are the house rule anyway).
4. **Tune against real music playing to the group, not test tones.** Every manual UI
   says so. Test signals appear only in mic-based *automatic* calibration (AmpMe
   AutoSync tone+mic, later replaced by device-profile "Predictive Sync"; AVR room
   cal) — and every product that automates still keeps a manual offset as fallback.
5. **Nobody ships an A/B alternating-click alignment aid.** Closest precedents are
   car-audio by-ear noise-track alignment and AVR auto chirps. Our planned
   "nudge until it blends" aid is a genuine differentiator, not a catch-up feature.

## 3. Keeping BT consistent with AirPlay — technique check

The plan's design (AirPlay presentation timeline as reference; BT sink delayed by
`presentationDelay − perDeviceOffset` ≈ 1.7–1.8 s; continuous ppm rate-correction) is
**exactly the state of practice**: snapcast corrects by single-sample insert/drop
(~0.02 ms each), shairport-sync by "stuffing" (soxr resample-to-N±k frames), PipeWire
by a delay-locked loop steering an adaptive resampler. Sustained corrections of even a
few hundred ppm are inaudible as pitch (1 cent ≈ 578 ppm); what's audible is abrupt
rate *changes* (slew them) and hard whole-frame drops (clicks). Typical consumer clock
spread ±100–200 ppm ⇒ up to ~6 ms/min divergence uncorrected — continuous correction is
mandatory, confirmed.

**Corrections/additions to the plan from this research:**

1. **BT latency is NOT stable within a session** (plan implicitly assumed it was).
   Documented on Apple's stack: ~215→155 ms "warm-up" decay over 20–30 min on fresh
   connect (AirPods measurements, Apple dev forum 679274) and minute-scale wobble
   (193→260 ms within a minute, thread 126277). A saved per-device offset is coarse
   alignment (±50 ms-ish); the drift loop + user trim must absorb the rest, and slow
   runtime re-estimation is worth considering. Cannot promise lip-sync-grade — the
   locked "blend, not phase-lock" bar (Decision 1) is the right promise.
2. **CoreAudio-reported BT latency is confirmed junk** (`kAudioDevicePropertyLatency`
   underreports, `kAudioStreamPropertyLatency` reports 0 — Apple forums + JUCE). Use
   as a seed only, never truth. (Plan already said this; now sourced.)
3. **`AudioDeviceGetCurrentTime` on a BT device reads the host-side BT stack's pacing
   clock, not the speaker's remote DAC.** No source confirms it reflects the real DAC.
   It's still the right clock to servo against (it determines buffer fill), but expect
   jumps when the stack re-buffers (the warm-up behavior) — the per-device drift loop
   needs a low-pass/DLL and a re-anchor path, same lesson as the FLUSH re-anchor work.
   **Unverified plan assumption → add empirical verification to the spike list** (log
   pacing-clock cadence + jump events per BT device on real hardware).
4. **Concurrent-sink ceiling**: no documented OS limit on simultaneous A2DP links;
   2 sinks routinely fine, 3–4 is where field reports fall apart (2.4 GHz airtime,
   worse near active Wi-Fi). macOS Tahoe 26.0/26.1 currently has a broad BT audio
   regression wave (stutter with >1–2 BT devices, crackle after sleep) — plan for
   **2 reliable / 3–4 best-effort with a warning**, and expect more rate-change events
   per session on Tahoe (relevant to the HFP-storm/rebuild work).
5. **Auracast/LE Audio: still no Apple broadcast-source API through WWDC26** (June
   2026, confirmed by hearing-industry press). A2DP remains the only path; keep the
   sender seam Auracast-ready but build nothing on it.

## Net verdict

Nothing found contradicts the locked architecture — per-device pinned AVAudioEngine
sinks + reference-timeline delay + continuous drift correction is both the July
verdict and what the industry does. The fresh findings sharpen v1:

- **Offset control**: numeric signed ms per device, **±500 ms, 10 ms coarse / 1 ms
  fine**, live-applied while music plays, persisted by device UID, brand-seeded;
  advanced-surface placement (Airfoil precedent) with the A/B click aid as our
  differentiator. (Matches BT-OFFSET-UI; adds concrete range/step.)
- **Drift loop hardening**: low-pass + re-anchor on the pacing clock; treat offset as
  coarse + let the loop absorb warm-up drift. (Extends BT-DRIFT.)
- **Spike list gains one item**: verify the BT pacing-clock behavior empirically
  (alongside BT-SPIKE-CONNECT and BT-SPIKE-OFFSET, both still owed, both
  hardware/Alec-present).
- **Set expectations in-product**: constant offsets can't fix fluctuating links
  (Airfoil says it publicly; so should we), same-room BT+BT stays marginal, video
  lip-sync is out of scope.
