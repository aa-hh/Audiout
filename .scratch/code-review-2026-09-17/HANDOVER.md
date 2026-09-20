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

So the working hypothesis is **flakes under load, not a regression**. It is a hypothesis. A
control run of exactly those four tests on the clean base tree was started and did not finish
before the session ended. **Run that control before you conclude anything:**

```bash
cd ".claude/worktrees/unslop-code-ca8d54" && AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'deRouteCancelsThePendingRetryRatherThanLettingItResurrectTheTap|aMeasuredProposalsRejectReRunsTheProbeThenHandsToTheQuestions|cardTitlesTintGoldWhileTheirRowsSound|enabledRetouchesMoreThanOnceAcrossAWaitThatNeverBecomesReady'
```

That worktree is the base commit with no ticket changes in it, so it is the control. If those
four fail there too, they are pre-existing and ticket 01 is exonerated; note them as a separate
defect and carry on. If they pass there and fail in `cr-01`, stop and investigate ticket 01 for
real before committing it.

Either way, trust only a line reading `Test run with N tests`. A filter that matches nothing
reports green.

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
