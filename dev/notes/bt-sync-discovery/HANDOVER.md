# Handover: "Bluetooth sync technical discovery" thread

Written 2026-09-26 08:25 UTC for whichever agent picks this thread up. Everything here
is read-only research so far; no repository was changed, no branch pushed, no PR opened
from this thread. The user is Ali (GitHub `aa-hh`), the owner of Audiout.

## 1. What Ali asked for, in his words

A team of researchers doing a full technical discovery (current setup, the whole user
journey, the whole architecture, anything available online) to find a novel way for
people to keep all their speakers in sync regardless of transport. AirPlay is not a
problem. Cast is a problem. Bluetooth is the real problem: it works sometimes but is not
reliable. He wants to know what is missing to make the vision real, believes it is
technically possible, and does not care how long it takes. He later added two things:

- **Volume before sync (standing requirement):** when the Mac can control a Bluetooth
  speaker's real output volume, the initial sync must first make sure the volume is high
  enough for the mic to hear the sweep.
- **First-sync silence (bug report):** on a freshly connected Bluetooth speaker the sync
  played nothing until he played audio once and paused; then it worked. Another thread
  owns this ("Silent Bluetooth speaker before first sync"; draft fix in Audiout PR #224,
  unverified on hardware).

He said "You have permission to do whatever you want... You do not need to ask me for
everything you want to check." Read that as: check freely, don't ask about reads. It is
not a standing approval for pushes, merges, PRs or production changes; the coordinator's
brief said to ask before editing code or opening a PR, and Ali has not overridden that
for this thread.

## 2. What was delivered (all under `/mnt/project-files/bt-sync-discovery/`)

| File | What it is |
|---|---|
| `discovery.md` | The synthesis Ali read and liked. §1 one-page answer, §3 the three-loop diagnosis, §4 ranked options in four tiers, §6 five live tests, §7 ten owner decisions, §8 what a Mac cannot control |
| `research/code.md` | Data path end to end, the BT sink state machine, every lifecycle edge, ten assumptions the code makes about Bluetooth and whether each holds, what was tried on branches and dropped |
| `research/bluetooth.md` | A2DP sink servo behaviour and deadband, where latency lives, codecs on macOS, delay reporting, AVRCP absolute volume, LE Audio/Auracast, USB dongles, HFP band limits |
| `research/cast.md` | Cast today (HTTP pull, 5.5 s receiver floor), two likely bugs, Cast Streaming as the fix, other senders |
| `research/journey.md` | The journey step by step, ProbeKit limits, invisible health states, §3.8b the sweep-volume flow, §5 a redesigned journey |
| `research/priorart.md` | Every product, OSS project, standard, paper and patent; the market gap; FTO flags |
| `research/crosstalk.md` | The researchers' notes to each other; useful for provenance |
| `runbooks/01-pause-resume-drain.md` | Live test 1, ~20 min, two BT speakers + Mac |
| `runbooks/02-bt-vs-host-hour.md` | Live test 2, ~75 min, one BT speaker + Mac speakers as reference |
| `runbooks/click-track-3s.wav` | 30 s click track (2 kHz burst every 3 s) to loop in QuickTime |
| `runbooks/click-pair-spacing.py` | Reads a Mac-mic recording, prints the gap between the two arrivals every 3 s and a drift fit; needs numpy; verified on synthetic data (recovers +1 ms/min exactly) |

Sibling documents from the same day, which the discovery cites and does not repeat:

- `/mnt/project-files/sync-architecture/sync-clock-architecture.md` ("ARCH"): the master
  clock is settled (Mac host clock only; a BT speaker may set the room delay `R`, never
  the clock) and its Gaps 1–5.
- `/mnt/project-files/bt-sync-version-comparison/report.md` ("VER"): none of the 1.2.0
  Bluetooth fixes are on main. One correction to it from this thread: VER row 4 says the
  restart-ordering fix has no pushed branch, but it is `3ae8fea2` on
  `origin/claude/bt-deselect-no-rebuild-a066`, one commit ahead of main.

## 3. The findings in five lines (read `discovery.md` §1 for the real version)

1. The BT sink has no continuous host-side loop after release (plain FIFO, ratio 1.0,
   `BTSyncedSink.swift:930-950, :1176-1179`). Every working sync system has that loop.
2. Common-mode BT-vs-host drift (~20 ppm, ~70 ms/h against AirPlay) is unmeasured; the
   "−0.02 ppm over 30 min" claim was a 120 s BT-vs-BT run (`efb67775`).
3. The passive tracker's baseline is the model `room + trim`, not an acoustic observation,
   so laptop geometry reads as error (journey §3.7, inferred; runbook-able).
4. Every structural event rebuilds every BT sink with a whole-house gap and, inferred, a
   20–90 ms re-roll, and nothing re-measures after.
5. Every sync-health state is computed and none is rendered.

Cast: likely ~500 ms late (ring cushion never subtracted, `CastLiveAudioServer.swift:331`,
inferred) and bimodal after the first pause; Cast Streaming (RTP, 400 ms target delay) is
the real fix. Desktop Macs get no mic path at all (`MicProbeSession.swift:231-252`).

## 4. Decisions Ali has made, and the ones still open

Made:
- **Gap 1, delay-to-worst:** a slow Bluetooth speaker may push AirPlay's room delay later,
  reusing the delay line Cast already has (decided in the clock architecture thread,
  2026-09-26 00:55; recorded in `discovery.md` §7 item 1 and option 1.3). Not implemented.
- **Retry-once** on a failed first listen (decided in the silent-speaker thread; drafts in
  Audiout PR #224, audiout-remote PR #39, audiout-shared PR #20, none compiled).
- He has **no AirPlay setup available right now**. Told him none of the tests or decisions
  needs one; the Mac's own speakers are the host-clocked reference. What genuinely waits on
  AirPlay: listening to delay-to-worst, the 222 ms AirPlay send stalls, and the final
  BT+AirPlay verification.

Open (`discovery.md` §7 items 2–10): the volume-raise cap and whether it needs a visible
line; app-initiated measurement on connect; refuse vs reroute a Bluetooth default output;
merge order and whether `ed6f00a`'s pulls-vs-wall-time model stays or the timestamped
ring replaces it; Cast's ~5 s house delay vs "joins unsynced" and a libopus dependency;
BT vendor/product ID under the privacy fence; reopening spec decisions 1/7 for masked
per-speaker codes; a patent check; the definition of "in sync" (10 ms floor vs tighter).

## 5. Where the thread is right now

Ali said "Write them out. Let's get this going." about the runbooks, and they were
delivered at 01:19 UTC. **Nothing has come back yet.** The next thing that should happen
is Ali running runbook 1 and runbook 2 on his Mac and posting the numbers. The thread is
waiting on him.

When results arrive, `runbooks/02-bt-vs-host-hour.md` has a four-row table saying what
each outcome means and what to build. In short:
- Runbook 1: offset unchanged across the pause → servo needs rate only; offset jumps and
  stays → the servo needs gap-fill at enqueue (discovery option 1.1).
- Runbook 2: acoustic slide and `bt_clock_deviation` slope agree → servo on the pacing
  clock error against host time, no mic needed for rate; slide without slope → rate is a
  mic problem; both flat → rate is not the field problem, servo still earns its place for
  pulls and pauses.

## 6. What to do next, in order

1. **Read the runbook results when Ali posts them** and say plainly which design branch
   they choose. Update `discovery.md` §4 option 1.1 with the outcome.
2. **Runbooks 3–5** are not yet written (discovery §6): Cast 500 ms (needs a Cast device,
   Mac speakers as reference), the geometry test (two BT speakers + phone at the sofa +
   MacBook moved), and the rebuild re-roll test. Same shape as 1 and 2: build, press,
   listen, which log lines, verdict criterion. Write them when Ali asks or when 1–2 are in.
3. **Ask before any code.** The coordinator's brief was read-only; Ali has not said "build
   it" for any option. When he does, the Tier 1 order in `discovery.md` §4 is the plan,
   and Tier 0 (merge the unmerged fixes with a listen on the two Moves; persist the
   *applied* trim) comes before any new design. The designated branch for this thread is
   `claude/project-thread-n5cchm` in all three repos; the project's rules (worktrees,
   `run-tests.sh` never bare `swift`, the live-test slot for the dev id, Guard 7
   self-review) are in each repo's `CLAUDE.md` and `AGENTS.md`.
4. **Keep the sibling threads in view.** "Silent Bluetooth speaker before first sync" is
   waiting on a hardware run of PR #224; its outcome bears on option 1.7 (the audibility
   check) and journey step 4. "Write the sync clock architecture" is blocked on input.

## 7. Things a new agent would otherwise have to rediscover

- Telemetry is JSONL at `~/Library/Logs/Audiout/telemetry.jsonl` on Ali's Mac. Lines that
  matter: `bt_clock_deviation` (every 30 s per BT device: `ms`, `jumps`, `hostNanos`),
  `bt_sink_anchored`, `bt_sink_release_overshoot`, `bt_sink_seek_clamped`,
  `bt_clock_jump`, `tap_feed_gap`, `drift_correction_started`, `cast_lead_sample`.
- Dev build: `bash scripts/livetest.sh acquire --label <x>` then
  `APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" bash scripts/make-app.sh`,
  output `build/Audiout Dev.app`. One copy of the dev id at a time.
- The drift meter is on `origin/claude/bt-multi-spike` (`dev/bt-multi-spike`,
  `--drift-meter A B --seconds N`), reports each BT speaker's ppm against the built-in
  mic's clock and a LINE/STAIRCASE verdict. Needs two BT speakers and mic permission.
- The unmerged fix branches on origin: `worktree-agent-a2a761b2a16d4c277` (`ed6f00a`,
  sink re-timing), `worktree-agent-ae5fc1d4b52d6b034` (`2977e56`, correlator search
  window; `abc7007`, Try again), `claude/bt-deselect-no-rebuild-a066` (`3ae8fea2`).
  The version-comparison session itself lives on Ali's Mac, never pushed.
- The Mac never renders "settling"; only the phone does. Wait a minute after connecting.
- Bluetooth-to-Bluetooth drift is closed (PR #200). Do not reopen it; the open question is
  common-mode drift against the host clock only.
- Ali's phone companion is off in release builds (`AppSettings.remoteAppIsOffered`), so
  anything that leans on the phone mic needs a dev build or an owner decision.
- Team memory has `bt-sync-discovery-2026-09-26`, `sync-clock-architecture-doc` and
  `bt-cold-speaker-sync-silent` covering the above in short form.
