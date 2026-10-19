# Handover: sync clock architecture and PR #228

Written 2026-09-26 for the next agent picking this up. Owner: Ali (GitHub `aa-hh`).
Project thread: "Write the sync clock architecture" in the *Bluetooth Speaker Sync
Reliability* project.

## TL;DR

- A design doc settles the master-clock question. It is at
  `dev/notes/sync-clock-architecture-2026-09-26.md`: the Mac's host
  clock is the only clock; a Bluetooth speaker can set the room delay `R` but is
  never the clock. Read it first.
- Ali decided one open question: **delay-to-worst across every transport.** A
  Bluetooth speaker slower than AirPlay's start buffer raises `R`, and AirPlay
  waits for it.
- That decision is implemented in **draft PR aa-hh/Audiout#228** (branch
  `claude/project-thread-wk2iwa`, one commit `32b108b`).
- **The PR has never been compiled.** It was written on Linux with no Swift
  toolchain. GitHub's two checks are green, but neither runs the Swift suite.
  The next step is a Mac build and test run, then a live listen.
- As of 2026-09-26 12:15 UTC the PR has no review comments, is mergeable
  (`clean`), and is still a draft.

## What was decided, and by whom

| Question | Answer | Source |
|---|---|---|
| Can a Bluetooth output be the master clock? | No. The timebase is Mac host time (`CLOCK_MONOTONIC`, also the PTP grandmaster for AirPlay). A BT speaker may only set the room delay depth `R`. | Design doc §3 |
| With AirPlay present, should a slow BT speaker push AirPlay later, or be flagged "too slow"? | **Push AirPlay later** (delay-to-worst). | Ali, 2026-09-26, in thread |
| Does BT need a rate-drift servo? | **No.** The 11 ms desync was the capture tap dropping cycles, fixed by PR #200. | Evidence in `.scratch/passive-drift-tracking/HANDOFF.md`; Ali accepted |

Ali pushed back on one thing worth knowing: the first draft of the doc wrongly
called the 11 ms desync unexplained. Ali remembered it had been found. It had.
Check the `.scratch/` handoffs before calling anything "unexplained".

## PR #228: what it does

Files: `AudioutCore/Sources/AudioutCore/NativeBackend.swift`,
`NativeBackend+Bluetooth.swift`,
`Tests/AudioutCoreTests/NativeBackendBTSelectionTests.swift`.

- New `NativeBackend.btRoomTermMs: Int?` (stateQueue-confined). It is `nil`
  unless all of these hold: whole-system BT is armed, the composition uses a
  presentation reference (AirPlay or Cast present), and
  `btOnlyReferenceMs(latencies, btSelectedUIDs)` (slowest measured latency +
  100 ms, floored at 500) is **greater than** `_startBufferMs`.
- `updateBTRoomTermLocked()` computes it. It is called from
  `updateBTReferenceBufferLocked()`, which already runs on every path that
  moves a BT latency or the selection: selection change, wizard Keep, drift
  commit, tuning cleared, wizard start and end. It is also called from
  `applyStartBuffer`. When the term moves, it fires
  `roomDelayChangedLocked(cause: "bt_latency")`, the existing Cast fan-out. That
  publishes the AirPlay `PCMDelayLine` depth `R − S`, re-anchors the BT sinks and
  the Mac sink, and pushes the Cast feed delays.
- `roomDelayLocked()` and `btReferenceDelayMs()` now take the `max` of
  `[castTerm, btRoomTerm]` over their base.
- `stop()` clears the term and publishes a 0 pre-delay if a term stood.
- New local telemetry line `bt_room_term_changed` (`from_ms`, `to_ms`,
  `start_buffer_ms`). It is local only, not a PostHog event, so nothing needs
  adding to `audiout-shared/docs/analytics-events.md`.
- Tests (3):
  - `btSpeakerUnderTheStartBufferNeverHoldsAirPlayBack`: no pre-delay is
    published when latency + headroom equals the buffer.
  - `btSpeakerSlowerThanTheStartBufferHoldsAirPlayBackByTheDifference`
  - `btRoomTermNeverFallsWhileTheSpeakerStaysSelected`

  `SpyBTSink` gained a `reanchorAll` recorder.

## Do this next, in order

1. **Compile and run the covering suite on the Mac**, through the wrapper as
   `CLAUDE.md` requires (never a bare `swift test`):
   ```
   bash scripts/run-tests.sh --filter NativeBackendBTSelectionTests
   bash scripts/run-tests.sh --filter NativeBackendCastTests   # shares roomDelayLocked
   ```
   Then run the full suite (`bash scripts/run-tests.sh`) before calling it done.
   Guard 7's `scripts/self-review.sh` also has not run on this commit. The
   pre-commit hook will demand it on the next commit.
2. **Fix whatever the compiler finds.** Likeliest spots, from re-reading the
   diff blind:
   - `reduce(today) { Swift.max($0, $1) }` over `[Int?].compactMap`. It should
     be fine, but it was never type-checked.
   - `SpyBTSink.reanchorAll(cause:)`: confirm the protocol at
     `NativeBackend+Seams.swift:528` declares it as a requirement (it does at
     `add4251`). Otherwise the spy's override is never called and test 2's
     `reanchorAll` expectation fails.
   - The `waitFor(timeout: 0.3) { false }` settle idiom is copied from the
     existing `perAppOnlyLatencyNeverRaisesTheSharedReference`. If
     `SuiteWait` records a timeout as a failure there too, fix both the same
     way.
3. **Live test on real hardware.** Use the shared dev id, and hold the
   live-test slot first (`bash scripts/livetest.sh acquire --label
   claude/project-thread-wk2iwa`). The dev id, `com.audiout.Audiout.dev`, is
   the right one here: this is audio behaviour, not a permissions test. The
   run:
   - Select an AirPlay speaker plus a BT speaker. Keep a measured latency above
     ~900 ms on the BT speaker (or type it via the wizard), with the AirPlay
     buffer at 1000.
   - Expect one audible gap on every speaker, then all in sync. Telemetry
     should show `bt_room_term_changed` and a `room_delay_changed` line with
     `airplay_pre_ms > 0`.
   - Deselect the BT speaker. Expect AirPlay to jump forward, with
     `airplay_pre_ms` back to 0.
   - Regression check: with a normal BT speaker (latency well under the
     buffer), nothing should differ from `main`. There should be no
     `bt_room_term_changed` line at all.
4. Mark the PR ready and hand it to Ali. Ali merges, never an agent. `main` is
   merge-only.

## Known issues in the PR (not fixed yet: decide or fix)

- **The hysteresis claim is overstated.** The PR text and a code comment say
  the term "never falls while the speaker stays selected". In the code it only
  holds while the candidate stays *above the start buffer*. A re-measurement
  that drops the slowest speaker to `latency + 100 ≤ S` sets the term to `nil`,
  and `R` falls back to `S` (one gap). Test 3 doesn't catch this, because its
  lower value, 1100, still clears the buffer. Two ways to fix it:
  - Make the doc match the code, which is arguably the right behaviour: the
    speaker now fits.
  - Keep the term at its high-water mark until deselect, which matches Cast's
    rule literally.

  Ask Ali only if the choice isn't obvious once it's heard live.
- **The high-water mark outlives the speaker that set it.** With two slow BT
  speakers, deselecting the slower one leaves the term at the slower one's
  value as long as the remaining one still clears `S`. This matches the Cast
  policy, but nobody has signed it off for Bluetooth.
- **Possible double re-anchor on selection change.** The selection path
  applies `applyBTSinkTransition` and can also fire `roomDelayChangedLocked`,
  which calls `btSink.reanchorAll`. The Cast code comments say this is "the same
  hold restarted a queue hop later, not a second gap". Confirm that by ear.

## Follow-ups deliberately left out of #228

1. **The wizard can't measure a slow speaker in an AirPlay room.**
   `btWizardLatencyRangeMs` (`NativeBackend+Bluetooth.swift`, around line 2468 at
   `add4251`) caps candidates at `S − 500` when AirPlay is present, so a
   1.2 s speaker can now be *synced* but not *measured* there. This is the rest
   of blocker 1 in `dev/notes/handoff-2026-09-03-bt-airplay-alignment-blockers.md`.
   It is a separate PR.
2. **BT speaker as the Mac's default output** (design doc Gap 4). If it happens,
   `SyncedLocalSink` would trust the HAL latency, which is wrong for BT. This is
   unverified: nobody has checked whether it is reachable. Verify before
   building anything.
3. **Vocabulary** (Gap 5): add timebase / `R` / intrinsic delay / trim /
   measurement reference to `CONTEXT.md`.
4. **The common ~1 ms/min slide** of both BT speakers in live test 4, block 6.
   It only matters against AirPlay or the Mac. Watch `bt_clock_deviation` in the
   next BT+AirPlay session. Build nothing unless it shows up.

## Where everything is

| What | Where |
|---|---|
| Design doc (read first) | `dev/notes/sync-clock-architecture-2026-09-26.md` |
| PR | https://github.com/aa-hh/Audiout/pull/228 |
| Branch | `claude/project-thread-wk2iwa` (pushed; from `main` at `add4251`) |
| Blocker write-up the PR fixes | `dev/notes/handoff-2026-09-03-bt-airplay-alignment-blockers.md` |
| Cast delay-line design the PR reuses | `dev/notes/006-cast-sync-architecture-2026-08-22.md` §3–5 |
| Drift evidence | `.scratch/passive-drift-tracking/HANDOFF.md`, `spec.md` (decisions 13–18) |
| Sibling work the same day | `bt-sync-discovery/discovery.md` in the project's shared files, not in this repo (wider discovery, 10 owner decisions in §7); PR #224 (cold BT speaker silent during sync sweeps) |
| Project memory | `sync-clock-architecture-doc`, `bt-sync-discovery-2026-09-26`, `bt-cold-speaker-sync-silent` |

## House rules that bite on this work

- Build and test only through the wrapper scripts (`build.sh`, `run-tests.sh`,
  `make-app.sh`). Bare `swift` commands are blocked by a hook.
- Work in a worktree, never the `main` checkout. Run
  `git config core.hooksPath .githooks` once per clone.
- A new test must name its defect in one sentence (root `AGENTS.md`, "New tests
  buy their place"). The three tests here each do.
- Only one agent may hold the dev-id live-test slot at a time. Release it the
  moment Ali gives a verdict.
- Ali said this thread's original brief was read-only. The PR exists because
  Ali asked for the recommendation to go ahead. Don't widen it without asking.
