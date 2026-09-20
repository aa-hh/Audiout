# Handover: full test suite on GitHub Actions

Branch `claude/ci-runner-performance-33258a` (merged the earlier
`claude/disable-github-actions-tests-cda23f` in), worktree
`.claude/worktrees/ci-runner-performance-33258a`, pushed to origin at b00a35b4.
Not merged. Written 2026-09-20 00:50 UTC, runner-speed section added 01:45 UTC.

## What Alec asked for

The repo went public. Alec wants GitHub Actions to take test load OFF the two
Macs while agents write code (free macOS runners on a public repo), not to run
less often. Explicitly: "build both, workflow plus the merge guard", then "add
the cache and measure a second run".

## What is built (all committed on the branch)

1. `.github/workflows/tests.yml` — two macos-26 jobs on every push touching
   `AudioutCore/**`, `AirPlayEngine/**`, `scripts/run-tests.sh`,
   `scripts/lib/**`, or the workflow itself; also `workflow_dispatch`.
   Each job: checkout, `actions/cache/restore`, brew deps, the package's suite
   via `bash scripts/run-tests.sh` (AirPlayEngine via
   `AUDIOUT_TEST_PACKAGE=AirPlayEngine`), then `actions/cache/save` with
   `if: always()` so a red run still saves its compile. Env:
   `AUDIOUT_BUILD_LOCAL=1 AUDIOUT_TEST_NO_LOCK=1 AUDIOUT_TEST_NO_CACHE=1`.
   Concurrency group per ref, cancel-in-progress (a push cancels the previous
   run on the same branch — this bit me once).
2. `.githooks/pre-commit` Guard 4 — on a merge commit onto main it now skips
   the local full-suite run when BOTH hold: `git diff --quiet MERGE_HEAD --
   AudioutCore/ AirPlayEngine/ scripts/run-tests.sh scripts/lib/` (the Swift
   being committed is byte-identical to the branch head), and `gh run list
   --workflow tests.yml --commit <MERGE_HEAD>` shows every completed run
   green. Anything else falls back to the local run unchanged. Flag
   `ci_green`; `AUDIOUT_FULL_SUITE=1` overrides. Note: a CLEAN `git merge`
   never invokes pre-commit at all (hook header says so), so this guard only
   fires on conflict-resolution merges. Not a regression, but worth knowing
   before anyone claims "main is gated by CI".
3. `CLAUDE.md` guards paragraph updated to mention the CI skip.
4. `.github/workflows/license-gate.yml` UNCHANGED (I changed it to
   push-to-main only in 22f94251 by misreading the ask, then reverted in
   b07d09ec).

## Measured

| Run | AudioutCore job | compile | tests | AirPlayEngine job |
|---|---|---|---|---|
| cold, no cache (35477948876) | 10.3 min | ~5 min | 290 s, 3947 tests | 1.5 min |
| cache-populating (35478553383) | 5.2 min | 3.7 min | suite process died early, no "Test run with" line | 1.5 min |
| warm, cache hit (35479212448) | 9.7 min | 3.4 min | 305 s, 3947 tests | 1.6 min |

Cache hit saves only ~20 s of compile (716 → 447 "Compiling" lines). Cause,
almost certainly: `actions/checkout` writes every source file with a fresh
mtime, so SwiftPM treats every module in this repo as changed; only the
dependency checkouts (Sparkle, PostHog, audiout-shared) come back warm. Same
wall as memory `swift-compilation-caching-unreachable.md`. Cache sizes: 679 MB
AudioutCore, 50 MB AirPlayEngine. `gh cache list` shows them.

So the floor per push today is ~10 min for AudioutCore, ~1.5 min for
AirPlayEngine, all off Alec's Macs. Brew is 8 s, checkout 9 s.

## The blocker: the suites are not runner-clean

Both jobs FAIL on every run, and it is the tests, not the code. Same 31
AudioutCore failures on both complete runs (deterministic on the runner), 3
in AirPlayEngine. Two kinds only:

- Wall-clock assertions (runner is a slow shared 3-core VM):
  `WriteCadenceTests` (deficit 0.30 s vs < 0.15), `SchedulingProbeTests`
  (p50 gap 41 ms vs < 20), `TCCProbeRunnerTests` ×3 (confirmation never
  fired), `CaptureCoordinatorTests` ×11 (all the one `waitForState` helper at
  line 134 timing out at 30 s), `CompanionServerTests`
  `commandRoundTripDeliversTheReply` (54 s wait), `PassiveDriftSamplerTests`
  (5 windows fired, expected 1), `NativeBackendTests` ×3.
- AppKit layout differs on the runner's display: `PopoverControllerRowReveal*`
  ×4 (panel 182 pt vs expected 110 — exactly 72 pt off, every time),
  `SurfaceToolbarTests` ×4 (alpha off by 0.05), `OnboardingUITests` ×5
  (`test_ribbonIsWaiting` false), `CardViewCollapseTrajectoryTests`,
  `EnergizeTests`.

Full per-test list: grep `recorded an issue` in a job log fetched with
`gh api repos/aa-hh/Audiout/actions/jobs/<id>/logs --allow-escape-sequences`.
Matches memories `test-deadlines-assert-machine-speed.md` and
`appkit-rounding-grid-varies-per-run.md`.

Consequence: tests.yml never goes green, so Guard 4's CI skip never triggers
and every merge still runs locally. Harmless, but the workflow buys nothing
until this is fixed.

## Open items, in order

1. **Alec's decision**: fund making the suite runner-clean (~34 tests across
   13 suites: loosen, skip on CI via an env check such as `GITHUB_ACTIONS`,
   or tag "real Mac only"), OR narrow tests.yml to AirPlayEngine plus the
   AudioutCore suites that touch neither AppKit nor wall-clock (green sooner,
   covers less). I recommended the cleanup; estimate half a day. Not decided.
2. **Compile cache**: if the 10 min matters, try restoring source mtimes from
   git commit times before the build (e.g. a small `git log`-driven touch
   loop, or `actions/checkout` + a known mtime-restore step) so SwiftPM sees
   unchanged modules. Unproven; measure before believing it.
3. **The 72-pt popover delta** is suspiciously constant — probably a title bar
   or safe-area the runner's window server adds. Someone chasing item 1 should
   start there; one cause may clear 4 tests.
4. The cache-populating run's AudioutCore suite died without a summary line
   (5.2 min). Not investigated. Possibly a crash in the same
   CaptureCoordinator area. Check `gh run view 35478553383` log tail.
5. Merge when green and Alec says so. Guard 4 skip cannot be exercised until
   tests.yml is green on some commit.

## Traps hit this session

- Background Bash jobs lost `gh` keychain auth mid-session ("not logged into
  any GitHub hosts") while foreground `gh` was fine; it recovered on its own
  ~10 min later. Poll runs in the foreground.
- GitHub's job log drops lines under parallel test output: a failing test's
  own `✘` lines can be absent while the summary says "N issues". Diff the set
  of `Test X started` against `Test X passed` to find them.
- `actions/cache@v4` saves only on job success. Use restore + save with
  `if: always()` (done).
- `gh run rerun --failed` refuses while a sibling job is still running.
- The repo's Bash hook blocks any command line containing the bare words for
  running Swift tests or builds, even inside a grep pattern.

## Runner speed discovery (2026-09-20, second session)

Where a warm-cache job's 9.7 min went before this session: checkout 5 s,
cache restore 24 s, brew 8 s, compile 203 s, tests 305 s, cache save 9 s.
The compile split: app modules 66 s, the single 43k-LOC test target 136 s.
The cache spared none of it because `actions/checkout` stamps every file
with "now" and SwiftPM recompiles on mtime; only the dependency checkouts
(Sparkle, PostHog, audiout-shared, the C libs) came back warm.

**Fixed (commit 2301e791):** a step after checkout gives each tracked file
the time of the commit that last touched it (`git log --name-only` newest
first, `touch -t`). Needs `fetch-depth: 0` + `filter: blob:none` (trees
only, 7 s). Measured on a realistic push (one comment line in
`AudioutCore/Sources/AudioutCore/Analytics.swift`, run 35481425256):

| | before (35479212448) | after (35481425256) |
|---|---|---|
| compile | 203 s, 447 files | **42 s, 19 files** |
| tests | 305 s | 329 s |
| job total | 9.7 min | **6.5 min** (7.3 with cache save) |

Run 35480288970 was the cold run that populated this branch's cache
(compile 237 s). Commit b00a35b4 is the comment touch used for the
measurement; harmless, revert if you like.

**Cache scope trap:** GitHub hands a cache only to the branch that saved it
and to the default branch's children. Every branch starts cold until
tests.yml has run on main once; after that every branch reads main's cache.
Key includes `github.sha`, so each push saves a fresh 680 MB entry; the
10 GB repo limit means ~14 entries before eviction. Fine, just know it.

**What's left is the test phase, and it is the suite, not the runner.**
The same 3947 tests take 208–271 s on Alec's 8-core Mac and 305–329 s on
the 3-core runner. The critical path is the @MainActor chain
(PopoverControllerTests spans the whole run), same as memory
`test-suite-profile-2026-08-06.md` found. Levers, in order of payoff:

1. **Make the suite runner-clean** (open item 1). Several failing tests sit
   on that chain and burn 30–135 s waiting for a timeout (the
   CaptureCoordinator `waitForState` at 30 s ×11, `commandRoundTrip` 40 s,
   the row-reveal set at 135 s). Removing them likely cuts a minute or two
   as a side effect. Unmeasured until it's done. The failure count varies
   run to run (25, 31, 37), so some are flaky, not just slow.
2. **Shard the tests across jobs** with `--filter` regexes, one job per
   shard. Compile is now 42 s per job, so 3 shards ≈ 42 s + ~110 s ≈ 3 min
   wall, versus 6.5. Free on a public repo (5 macOS jobs at once). The
   split must spread the @MainActor UI suites across shards or one shard
   keeps the whole chain. Not built.
3. **Skip the 14 dev executables** during the test build (`swift build
   --build-tests --target AudioutCoreTests` then `--skip-build`). Worth
   ≤15 s and only on a cold compile. Skipped as not worth the churn.
4. Bigger runners (macos-*-xlarge) are paid, ~$0.16/min. Not proposed.

Open item 4 resolved as far as the log allows: run 35478553383's test
process died with `swiftpm-testing-helper ... exited with unexpected signal
code 1` after ~5 min with hundreds of tests still unfinished — a crash in
the test process, no crash log in the job output. Not reproduced in the
four runs since.
