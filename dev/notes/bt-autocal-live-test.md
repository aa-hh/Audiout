# BT auto-cal spike — live hardware test protocol

The spike's gate (per `bt-autocal-spike-spec.md`): on ≥2 real Bluetooth speakers,
the phone-measured trim must land within audible equivalence of a wizard-tuned
baseline. Alec runs this; ~15 min per speaker.

## Setup (once)

1. Optional but recommended before any native live test: purge stale PTP daemons
   (`sudo` step — do it before the session, never mid-run).
2. Mac build from THIS worktree with a fresh bundle id (standing rule — never
   reuse a launched id):
   ```bash
   cd ".claude/worktrees/bt-autocal-spike"
   APP_NAME="Audiouter Probe v1" BUNDLE_ID="com.audiouter.Audiouter.probev1" bash scripts/make-app.sh
   open build/*.app
   ```
   Grant the fresh TCC prompts (audio capture, Bluetooth, local network).
3. iPhone build: open `ios/AudiouterRemote/AudiouterRemote.xcodeproj` from this
   same worktree in Xcode, run on the physical iPhone 15 Pro (never the
   Simulator). First probe run will ask for mic permission.
4. Pair phone ↔ Mac app as usual (companion approval flow).
5. Have at least the target BT speaker + one reference device (AirPlay speaker,
   another BT, or Main Out) in the mix and audible.

## Per-speaker measurement

1. **Baseline first**: tune the speaker by ear with the existing alignment
   wizard (or confirm the saved trim still sounds aligned). Note the trim value
   from the SYNC column.
2. Phone → Settings → debug area → **Alignment Probe**: pick the target speaker
   and the reference. Stand roughly between the two speakers, phone in hand.
3. Start. ~45 s: 5 s of faint noise (amp wake), then alternating tick blocks —
   reference first, target second, repeating 3×. Music is replaced during the
   run and comes back after.
4. Read the result: **offset ms / spread ms / confident**.
   - The interesting number is the offset measured while the baseline trim is
     applied: an accurate probe should read **near 0** (within a few ms) on a
     wizard-aligned speaker.
   - Bigger residuals: note the value, tap Apply, and A/B by ear against the
     wizard baseline (re-run the wizard to flip back if worse).
5. Repeat the probe 3× without moving. **Spread across the three runs is the
   repeatability number** — the spike's accuracy claim needs it ≤ a few ms.
6. Also try once standing clearly off-center (near the target) to see the
   geometry error in practice.

## What to record per speaker

| Speaker | Wizard trim (ms) | Probe offsets ×3 (ms) | Spread | Confident? | By-ear verdict after Apply |

## Failure modes to watch

- **Not confident / high spread on a Sonos**: expected suspect is amp warm-up —
  note whether a second immediate run is cleaner (the 5 s preamble may need
  lengthening; that's a knob, not a redesign).
- **Wildly wrong but confident**: check the phone wasn't paired to the target
  speaker or wearing AirPods routing — the session pins the built-in mic, but
  verify iOS honored it (Control Center input indicator).
- **Ticks audibly missing from a block**: amp gate swallowing ticks —
  note which speaker; the analyzer should go not-confident, not wrong.
- **Sign flip** (Apply makes alignment audibly worse in the opposite
  direction): report immediately — that's a bug in the trim math chain, not a
  tuning issue.

## Verdict options

- **GO**: ≤3 ms repeatability, applied trims audibly equivalent to wizard on
  both speakers → productize (UX, non-debug surface, ios-staging merge path).
- **GO-with-knobs**: accuracy fine but needs preamble/pattern tuning → tune,
  re-test once.
- **NO-GO**: repeatability or accuracy worse than the wizard → the spike
  answered honestly; keep the wizard, archive the branch (pushed, recoverable).
