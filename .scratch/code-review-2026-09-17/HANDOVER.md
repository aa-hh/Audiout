# Handover — code-review fix waves

Written 2026-09-20. Read this, then `REVIEW.md`, then the ticket you are picking up.

## Where things stand in one paragraph

The first whole-codebase review produced 24 tickets in five waves. Wave 1 (tickets 01–07) is
**built, verified and reviewed** — every one of the seven passed its own filtered suite and an
adversarial review. The owner approved committing and merging all seven. **The commit run then
died with the session, so none of it is committed.** All seven sit as uncommitted working-tree
changes in their own worktrees. That is the first thing to deal with, and the only thing at risk
of being lost. Wave 2 (08–13) was deliberately paused by the owner mid-run; three of its
worktrees hold scrap edits from executors that were killed part-way.

## The state on disk, exactly

Base commit for everything below is `a14ff11f` on `claude/unslop-code-ca8d54` (the review
branch). It carries `REVIEW.md`, the eight `areas/*.md` reports, and all 24 tickets in
`issues/`. It is pushed. `main` is still at `dcc587c8` and has none of this.

Wave 1 — each in `.claude/worktrees/cr-NN-<slug>`, branch `claude/cr-NN-<slug>`, **HEAD at
`a14ff11f`, work uncommitted**:

| Ticket | Diff | State |
|---|---|---|
| 01 Cast live-audio server bounds | 5 files, +267 | built, Fable-reviewed (2 passes) |
| 02 PTP helper XPC peer check | 9 files, +243 | built, Fable-reviewed (2 passes) |
| 03 NativeBackend silent `try?` | 4 files, +290 | built, Opus-reviewed |
| 04 store schema downgrade + quarantine | 11 files, +150 | built, Opus-reviewed |
| 05 DACP cap + non-finite volume | 2 files, +63 | built, Opus-reviewed |
| 06 companion approval prompt lifetime | 6 files, +195 | built, Fable-reviewed |
| 07 companion dispatcher refusals | 2 files, +29 | built, Opus-reviewed |

Every branch is pushed to origin at the base commit, so pushing a real commit is a
fast-forward. Each worktree also holds an untracked `issues/NN-*.work-order.md` in some cases;
that is pipeline scaffolding, safe to commit or drop.

Wave 2 — worktrees and pushed branches exist at `a14ff11f`, nothing wanted from them yet:

- `cr-08`, `cr-12`, `cr-13` — clean, untouched.
- `cr-09`, `cr-10`, `cr-11` — hold **partial edits from executors killed mid-step**. Treat as
  scrap. Do not try to finish them by reading the diff; re-run the ticket from a clean tree.

## The one open question you must settle first

The commit run got through ticket 01 and stopped there. Its pre-commit Guard 4 ran the full
suite and reported:

```
Test run with 3950 tests in 229 suites failed after 321.352 seconds with 7 issues.
```

Four tests failed:

- `deRouteCancelsThePendingRetryRatherThanLettingItResurrectTheTap` (NativeBackendTests.swift:6790)
- `aMeasuredProposalsRejectReRunsTheProbeThenHandsToTheQuestions` (PopoverBTAlignmentUITests.swift:1373)
- `cardTitlesTintGoldWhileTheirRowsSound` (PopoverControllerTests.swift:3881 and :3883)
- `enabledRetouchesMoreThanOnceAcrossAWaitThatNeverBecomesReady` (PTPHelperActivationTests.swift:203)

**None of them touches code ticket 01 changed.** Ticket 01 edits only `CastLiveAudioServer`,
`CastChannel` and one line of `CastOutputManager`. The four cover app-route rebinding, the
Bluetooth alignment wizard, a popover colour comparison, and PTP activation retries. Three of
the four are the shapes this repo already knows to be load-sensitive: a colour tolerance
assertion, a retry-count assertion, and a wizard stage count. At the time of that run, seven
pipelines plus their executors were competing for one build permit, and the machine was heavily
loaded.

A control run of those four tests on the clean base tree settles half of it. Run in
`.claude/worktrees/unslop-code-ca8d54`, which is the base commit with no ticket changes:

```
Test run with 4 tests in 5 suites failed after 1.506 seconds with 5 issues.
```

**Two fail on the clean base, with no ticket-01 code present at all:**

- `cardTitlesTintGoldWhileTheirRowsSound` — 4 issues, red and blue components outside a 0.004
  tolerance
- `enabledRetouchesMoreThanOnceAcrossAWaitThatNeverBecomesReady` — 1 issue, retry counter not
  above 1

These are **pre-existing failures unrelated to any review ticket**, and since the base is `main`
plus review documents only, they are failing on `main` as well. See the separate section below.

The other two — `deRouteCancelsThePendingRetryRatherThanLettingItResurrectTheTap` and
`aMeasuredProposalsRejectReRunsTheProbeThenHandsToTheQuestions` — **passed** in that control.
That is suggestive but not conclusive: the control ran four tests in isolation on an idle
machine, while the run that failed them was 3,950 tests in parallel under heavy load. Passing in
isolation does not prove they pass in a full-suite run on the base.

**To settle it, run the full suite on the clean base** and compare:

```bash
cd ".claude/worktrees/unslop-code-ca8d54" && AUDIOUT_FULL_SUITE=1 AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh
```

If the same four fail there, ticket 01 is fully exonerated and you commit it. If only the two
known ones fail, investigate those other two against ticket 01's diff before committing it —
though note that ticket 01 touches only the Cast server and neither test goes near it, so a
load-sensitivity explanation stays more likely than a causal one.

Trust only a line reading `Test run with N tests`. A filter that matches nothing reports green,
and repeated runs are served from a pass cache unless `AUDIOUT_TEST_NO_CACHE=1` is set.

## Two tests are failing on `main`, unrelated to any of this

Worth its own attention, and worth telling the owner before it gets buried:

- `cardTitlesTintGoldWhileTheirRowsSound` (PopoverControllerTests.swift:3881 and :3883) asserts
  two colour components within 0.004. The most recent merge on `main` is `aec62105`, "Tokens:
  light mode takes the light gold for graphics" — a gold token change. A colour-tolerance test
  failing directly after a colour token change looks far more like a real regression, or a test
  that needed updating with that merge, than a flake. Check that merge first.
- `enabledRetouchesMoreThanOnceAcrossAWaitThatNeverBecomesReady` (PTPHelperActivationTests.swift:203)
  asserts a retry counter exceeds 1. This is the shape the repo already knows to be
  machine-speed sensitive, so it may be a genuine flake, but it failed in 0.002 seconds on an
  idle machine, which argues against timing.

Neither is caused by the review work. Neither should block the wave-1 merge. Both should be
raised as their own tickets.

## Resuming the commit and merge

The owner has already approved committing and merging all seven wave-1 tickets, and ruled on
the one open design question (keep ticket 01's IPv6 fallback: when the receiver's IPv4 address
is unknown the peer check is skipped rather than refusing every peer). You do not need to ask
again. You do need to not merge anything else without asking.

Per branch, from inside that worktree:

1. `git add -A`
2. `bash scripts/self-review.sh` — Guard 7 refuses a Swift commit without a receipt hashed over
   the exact staged bytes. Re-stage after any edit and re-run it, or the hash no longer matches.
3. Actually read the staged diff against `docs/REVIEW-RUBRIC.md`. The receipt only proves the
   flow ran.
4. `git -c core.hooksPath=.githooks commit` — Guard 4 runs the test scope for the staged files.
   On a branch that is the covering suites, not the whole suite, unless the guard cannot map a
   file.
5. `git push origin claude/cr-NN-<slug>`

A ready-made loop that does steps 1, 2, 4 and 5 for all seven sits at
`<scratchpad>/commit-wave1.sh` from the previous session; it is simple enough to rewrite. Run it
detached or foreground, but know that each commit runs tests, so the whole set takes a while on
one build permit.

Then merge each into `claude/unslop-code-ca8d54`, run the full suite once on the merged result,
and take that to `main` both as a local merge and a GitHub pull request so origin/main and local
main stay in step. `main` is merge-only; never commit on it. A `git merge` triggers an approval
hook, which is expected.

## Owed after the merge

- **Ticket 03 needs its analytics row merged.** The new PostHog exception type
  `local_playback:start_failed` has a row waiting in
  [audiout-shared PR #19](https://github.com/aa-hh/audiout-shared/pull/19) (OPEN). Event names
  are an external contract; the Mac change and the shared row should land together.
- **Ticket 01 needs a live check against a real Chromecast** — that the receiver is still served
  after the peer check, cap and idle deadline went in. No test covers the real device.
- **Ticket 02 needs one live session with a Developer ID dev build** to prove the helper refuses
  an unsigned peer's release request. The XPC listener only exists under launchd, so it cannot
  be unit-tested; the manual procedure is written out in
  `AirPlayEngine/Sources/ptp-helper/AGENTS-HISTORY.md`.
- **Ticket 02 changes ad-hoc build behaviour.** With no Team ID the helper refuses every release
  and idle-exits after its 15-second window instead of releasing promptly. Developer ID builds,
  which is what `make-app.sh` produces, are unaffected. The owner has been told.

## One change that did not come from a pipeline

In `cr-05`, the new `test_connectionCount` seam landed `public` though its work order said
internal. I changed it to internal by hand with `sed` before the commit run. It is in that
worktree's uncommitted diff and has not been through the ticket's own review. It is a one-word
visibility change on a test seam; glance at it, do not be surprised by it.

## How to run a ticket, if you pick up wave 2

What worked, and it worked well: one orchestrator sub-agent per ticket, each given its own
worktree and told to invoke the `scope-and-run2` skill on that ticket's file. Model per ticket,
not per wave — Fable for anything touching security boundaries, concurrency, audio-thread code
or C; Opus mode for tickets that are a pattern copy with a named source to copy from. Seven ran
concurrently without colliding because each had its own worktree.

Four things to put in every orchestrator prompt, learned the hard way:

- **Sub-agents cannot write files into another worktree.** The file tools refuse it. Tell the
  orchestrator to pass the work order to its executor inline and let the executor edit through
  shell commands. Several pipelines lost time rediscovering this.
- **Tell it to fold spec-check corrections in itself if the scoper is slow.** One scoper took
  seventy minutes to return a revision; another never did. In both cases the orchestrator
  assembled the correction list itself and the result matched the scoper's eventual answer.
- **Never use the Agent tool's worktree isolation for branch work.** It forks from `main`, not
  from the current branch, so branch-only files are missing. Create the worktree yourself from
  the branch HEAD.
- **Nobody commits inside a pipeline.** Work stays uncommitted until the owner has seen it.

Also worth knowing: an orchestrator waiting on a child spends no tokens, so its token count
freezes and two waiting on similar children can show the same number. That looks like a hang and
is not one. Check what the children are doing before intervening.

## Build capacity, which shaped everything

Every compile and test takes a permit from a machine-wide pool. The local pool had drifted to 1
and was set back to 2, the documented value. The second Mac was unreachable for this entire
effort, so its 3 permits were unavailable and every pipeline queued behind the local pool. That
is why the wave took hours of wall-clock for a few hours of work. `bash scripts/capacity.sh
status` shows the current picture. If the mule is up, the same wave runs far faster.

---

# Wave 2 — built, verified, uncommitted (2026-09-20)

All six wave-2 tickets ran through `scope-and-run2`, one orchestrator per ticket, each in its
own worktree at base `a14ff11f`. All six are built, reviewed and APPROVED. **Nothing is
committed.** Every worktree still has `HEAD` at `a14ff11f` with the work in the tree.

| Ticket | Diff | Review | Verification re-run independently |
|---|---|---|---|
| 08 app row drag flag | 6 files, +52 −8 | Opus, approved | `Test run with 73 tests in 2 suites passed` |
| 09 level meter display link | 2 files, +53 −1 | Opus, approved | `Test run with 7 tests in 1 suite passed` |
| 10 default output monitor leak | 2 files, +35 −3 | Opus, approved | `Test run with 18 tests in 1 suite passed` |
| 11 synced local sink lifetime | 2 files, +48 −19 | Fable, approved | `Test run with 44 tests in 6 suites passed` |
| 12 render callback clock rebase | 6 files, +168 −25 | Fable, approved | `Test run with 84 tests in 9 suites passed` |
| 13 real-time contract mixers | 6 files, +394 −85 | Fable, approved twice | `Test run with 125 tests in 4 suites passed` |

Those verification lines are from a separate run done after every pipeline finished, with
`AUDIOUT_TEST_NO_CACHE=1`, one worktree at a time on an otherwise idle machine. They are not
the pipelines' own reports.

Tickets 11 and 12 both edit `SyncedLocalSink.swift` and were fenced against each other. Ticket
12 checked the merge: its hunks land at old lines 134, 254, 351–357, 624–629 and 651, and
ticket 11's at 190–194, 367–372 and 642–650. No overlap.

## Decisions taken inside wave 2

- **Ticket 13's real-time policy.** The capture delivery thread is the `.userInitiated` serial
  dispatch queue the IOProc is registered on, not the HAL's real-time thread — but the HAL
  dispatches the block synchronously and waits, so its wall time still counts against the
  device's IO cycle. Rule now written once at the IOProc registration site: never wait on a
  serial queue, or on a lock whose holder does unbounded work; a lock whose every holder does
  bounded in-memory work may be taken outright; allocation and the converter run are accepted
  costs. The three `// ---- REALTIME THREAD ----` labels were reworded to point at it, since
  they named a thread the code does not run on.
- **Ticket 11's `sourceNode`.** Became `AVAudioSourceNode!` rather than `let`, because Swift
  forbids capturing `self` weakly in `init` before every stored property has a value. Matches
  `lifecycleHooks!` two lines below.
- **Ticket 11's deinit deadlock** was fixed, not argued away. `deinit` can run on
  `lifecycleQueue`, so listener removal moved into its own method that `deinit` calls directly;
  `stopObservingLifecycleEvents()` keeps the queue hop.

## Owed after a merge

- **Ticket 11 adds a PostHog exception type**, `sync:restart_failed` under `.localPlayback`.
  Event names are an external contract, so `docs/analytics-events.md` in `audiout-shared` needs
  its row. That joins ticket 03's `local_playback:start_failed`, already open as
  [audiout-shared PR #19](https://github.com/aa-hh/audiout-shared/pull/19).
- All six ticket files still read `Status: ready-for-agent`.

## Wave 1's commit run failed again, for a reason that is nobody's ticket

The commit loop was restarted and refused at ticket 01. Guard 4 ran the **full** suite (a
branch commit falls back to the full suite when the diff touches AudioutCore Swift) and
reported:

```
Test run with 3950 tests in 229 suites failed after 1046.198 seconds with 16 issues.
```

That run happened while six wave-2 pipelines and their executors were competing for two build
permits. The popover controller suite alone took 954 seconds against 321 seconds for the whole
suite in the previous session. The loop was stopped so it would stop starving wave 2. **No
wave-1 work was lost**; all seven worktrees still hold their changes.

## `main` is red, and this is the thing to deal with first

Eleven tests fail on the clean base commit, which is `main` plus review documents only:

```bash
cd .claude/worktrees/unslop-code-ca8d54
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'RouteArmedSignalTests|DeviceRowConnectionStateTests'
# Test run with 103 tests in 2 suites failed after 1.606 seconds with 11 issues.
```

All eleven are mute-pill assertions: `test_isMutePillEngaged`, `test_mutePillIsMutedHue` and
`test_muteDrawsRestSymbol`, at RouteArmedSignalTests.swift:184, :190, :194, :203, :397, :434 and
DeviceRowConnectionStateTests.swift:511, :520, :527, :533, :536.

A lead, not a diagnosis. In `DeviceRowView.swift:2773`, `test_mutePillIsMutedHue` documents
itself as checking "the filled square" but builds its reference from
`RowAccessorySymbol.muteRest` (`custom.speaker.slash.square`), while `muteEngaged`
(`custom.speaker.slash.square.fill`) exists. That does not explain every failure —
`muteDrawsTheOutlineSquareWhenUnmutedViaApply` exercises the rest path, which looks correct —
so confirm the cause before changing anything. These are raster comparisons over TIFF bytes, so
a rendering-environment difference has to be ruled out too.

**This blocks every commit in both waves**, because Guard 4 runs the full suite for any diff
touching AudioutCore Swift and the full suite cannot pass while `main` is red. Fix this first,
then re-run the wave-1 commit loop on an idle machine, then wave 2.

Two other tests were already known to fail on `main` and are separate:
`cardTitlesTintGoldWhileTheirRowsSound` and
`enabledRetouchesMoreThanOnceAcrossAWaitThatNeverBecomesReady`.

## One process lesson, worth putting in every orchestrator prompt

Five of the six orchestrators stalled the same way: each launched a child agent in the
background, went idle waiting for a report, and stopped. With no live child, nothing was ever
coming back. Each needed a nudge to check the tree itself and to relaunch children with
`run_in_background: false`. **Tell an orchestrator to launch every child synchronously.**
