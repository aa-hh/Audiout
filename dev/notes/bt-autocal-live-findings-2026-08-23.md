# BT auto-cal spike — first live session findings + longitudinal study handoff

2026-08-23, ~01:00–01:45. Branch `claude/bt-autocal-spike` (this doc's commit is
the state of record). Prior context: `bt-autocal-spike-spec.md` (build contract),
`bt-autocal-live-test.md` (original protocol), and the feasibility brief on
`claude/bluetooth-speaker-delay-feasibility-f3474a`. Hardware: two Sonos Moves,
both connected over Bluetooth — target "Move 2" (`C4-38-75-0E-BF-4A:output`),
reference "Sonos Move" (SONOS 089E). ~15 probe runs.

## Verdict so far: the instrument is VALIDATED; the target moves

**Measurement system works end to end on real hardware:**
- Within-run spread 0.4–1.6 ms on every clean run (3 pairs).
- Back-to-back repeatability: 46.6 → 45.7 ms (0.9 ms apart, nothing touched).
- Hand-verified twice against raw tick-arrival grids: exports
  `~/Downloads/probe-take-1787441614.wav` (probe said 61.4 — grid says every
  TGT block is +60..62 ms off the REF grid) and `...762.wav` (85.7 — grid says
  +84..85). No analysis artifacts. Replay harness: see "Diagnostics" below.
- The confidence gate correctly refused a run disturbed by an AirPods
  route-grab (read 283 ms / 2 pairs) and a mid-settling run (spread 3.0).

**The finding that reframes the feature — BT latency is per-connection:**
- Within a healthy, undisturbed connection it holds for 45+ minutes through
  play/pause cycles (Alec's by-ear evidence: manual trim −410 ms stayed "very
  very clearly in sync" across many start/stops, speakers beside him).
- Each reconnect / stream rebuild RE-ROLLS it — by up to hundreds of ms
  (−410 one session vs ~46 the next: same pair, different connections).
- After a mid-stream disruption (AirPods grabbed the route) it WALKED:
  17 → 61 → 86 ms across ~8 minutes, while staying sub-ms stable inside every
  45 s probe window.
- **OPEN ENG QUESTION:** the BT sink's continuous drift servo did not hold
  phase through that walk. Possible re-anchor gap after a mid-stream buffer
  step (compare the FLUSH re-anchor work, which handles dropouts). Deserves
  its own investigation; affects wizard-set trims exactly as much.

**Product implication:** a static trim is valid per connection → nobody
re-runs a by-ear wizard on every reconnect, but a 45 s phone probe per
reconnect is realistic. Auto-probe-on-reconnect is the natural end state.

## The longitudinal ear-vs-probe study (IN PROGRESS — Alec is collecting)

Hypothesis: ear says "in sync" ⇔ probe reads ≈0 (under the trim in place);
ear hears flam ⇔ probe reads the flam's size. A few normal listening sessions.

Per session: listen first (judge by ear) → one probe → tap the ear-verdict on
the new History row (`ear?` cycles unknown → sync → flam). Everything persists
on the phone (`ProbeRunLog`, Documents/probe-run-log.json, exportable as JSON
from the History footer): timestamp, devices, offset/spread/pairs/confidence,
**the trim the run was measured under** (from the snapshot's new
`syncTrimMs`), applied flag, ear verdict.

Reading the exported log: correlation between `earSaidInSync` and `offsetMs`
(magnitude vs the ~few-ms audibility threshold) is the spike's final gate.

## Deployed builds (state as of this commit)

- **Mac**: `Audiouter Probe v3` (`com.audiouter.Audiouter.probev3`), built from
  this branch, in `build/` of this worktree. v3 adds trim-in-snapshot; Alec
  opens it at next session (fresh TCC prompts + phone re-pair). v2
  (`.probev2`) was the session's workhorse; superseded.
  Every future test build: NEW bundle id (standing rule).
- **iPhone 15 Pro** ("A Phone", udid `9F64EA5A-DD41-50EC-AA3C-FC8DBC70B5D0`):
  build/install with
  `xcodebuild -project ios/AudiouterRemote/AudiouterRemote.xcodeproj -scheme
  AudiouterRemote -destination 'platform=iOS,id=<udid>'
  -allowProvisioningUpdates DEVELOPMENT_TEAM=TGT8D69RZ4
  CODE_SIGN_STYLE=Automatic build`, then `xcrun devicectl device install app`.
  (The project has no team set; the override is required.)
- Probe entry point on the phone: Connection tab → Mac Settings →
  "BT Auto-Cal Probe" (DEBUG builds only).

## Operating the probe (traps a fresh agent must know)

- **Music must be playing** on both devices — the tick rides inside the
  captured feed (same root cause as roadmap 040). Reference must be an
  audible Main Out member.
- **Duplicate identity rows**: each BT speaker appears as its live output
  (`XX-XX-…:output`) AND its paired record (`XX:XX:…`); pickers don't
  distinguish. Users pick the idle twin and get "isn't playing" refusals.
- Mac-side probe logging: subsystem `com.audiouter.Audiouter`, categories
  `probe`/`companion` (info level — use `/usr/bin/log stream --info`; note
  Alec's shell aliases `log`, use the absolute path).
- The Sonos amp-gate swallows the first ~2 ticks after each unmute; the
  analyzer's discard-first + quality filter absorb it by design.

## Diagnostics harness

`ios/AudiouterRemote/ProbeKit/Tests/ProbeKitTests/RealRecordingDiagnostics.swift`
replays a phone-exported WAV through every analyzer stage with printed
arrivals/blocks (`PROBE_WAV=/path swift test --package-path
ios/AudiouterRemote/ProbeKit --filter RealRecordingDiagnostics`). A repo hook
blocks bare `swift test` even for this package — copy the package outside the
repo and run `xcodebuild test -scheme ProbeKit -destination 'platform=macOS'`
there (env vars don't pass through xcodebuild's runner; hardcode the path in
the copy). The phone's "Export recording" button produces the WAVs.

## Productization punch list (if the study passes)

1. Reference/target pickers: one row per physical speaker (merge the identity
   twins), clear naming.
2. "Too quiet — raise the volume" feedback from tick-quality stats.
3. Mac aborts/flags the run when output routing changes mid-pattern
   (the AirPods incident produced a confident-looking 283 ms).
4. Split the collapsed reference-refusal message (not-a-member / muted /
   not-writable are three different user problems).
5. Auto-probe-on-reconnect concept (the per-connection re-roll finding).
6. Run history graduated from debug UI.
7. The servo re-anchor investigation (own track; not probe work).

## State of the branch

Everything committed and pushed to `origin/claude/bt-autocal-spike`. Not
merged into `claude/ios-staging` (waits for the study + Alec's go). Track
branches `claude/bt-autocal-{mac,dsp,iosui}` are merged into this branch and
pushed; their worktrees are prunable. All spike-only code is marked with
`razor:` comments for eventual removal or graduation.
