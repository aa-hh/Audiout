# Handover: trust the mule's verdict when it is a verdict

Written 2026-09-20. Nothing is built. The work order is `01-WORK-ORDER.md`
in this directory; read this file first.

## The job in one paragraph

When the mule runs the suite and reports failures, `scripts/run-tests.sh`
throws that result away and runs the whole suite again locally. That re-run
was written to protect against a toolchain difference between the two Macs.
There is no longer a toolchain difference. But the re-run still earns its
place for two of the three ways a remote run can fail, so the fix is not to
delete it: it is to tell the three cases apart, act on the one that is a real
verdict, and keep re-running the two that are not.

## Where this came from

**2026-09-03**, session "Mule failover and local rerouting", off
`dev/notes/handoff-2026-09-03-mule-testing-module.md`. That deep dive found
the mule failing three different ways in one morning and the wrapper turning
every one of them into a full local suite run. Its conclusion, verbatim:

> The re-run asymmetry was written for a toolchain skew that no longer
> exists, since both Macs run 27A5252f.

Everything else that session identified was built and merged: the remote
environment gate and failure classification (`0e622494`), `--disable-keychain`
and the `--num-workers` removal (`bbb0791a`), and the mule's job cap. The
re-run itself was never touched.

**2026-09-20**, the owner re-checked the toolchains and confirmed they still
match. That is the premise this work rests on. If a future reader finds the
Macs have diverged again, stop and re-open the question rather than shipping
the trusted-verdict path.

## What is already true in the code

`remote_run` already works out which of three failures it got and prints it
(`scripts/lib/remote.sh:480-504`):

1. named failing tests, with the test names
2. the build did not finish, no `Build complete!` line
3. no test verdict, N tests passed then the process died

It then returns the same `2` for all three (`remote.sh:505`). The information
exists and is discarded one line later. Task 2 of the work order is just
keeping it.

Connection-level failures never reach that branch. A dropped ssh, a killed
client, a sleeping host, exit 97 (unusable environment) and exit 98 (mule
full) all return `1`, meaning "could not use the remote", and the job simply
runs locally with no verdict claimed (`remote.sh:456-470`).

## The defect found while scoping this

`AUDIOUT_TRUST_REMOTE_FAILURE=1` does not do what `5acdd30d` says it does.

It returns `1` from `run_remote` (`run-tests.sh:173`). The caller reads `1` as
"could not use the remote", prints "falling back to this machine"
(`run-tests.sh:269`), and falls through to the local suite. Only `rrc -eq 0`
short-circuits with `exit 0`. So the flag changes one printed line and the
tree still builds and runs twice, which is the exact cost the commit message
claims it removes.

Verify in three greps: `grep -n '^ *exit ' scripts/run-tests.sh` shows every
exit; none of them is on the `2` or `1` path out of `run_remote`.

This is why Task 1 exists. There is no plumbing for "the remote's verdict is
final", so choosing which failures to trust has nowhere to land until that
path is built.

## The safety change, stated plainly

Guard 4 shells out to `run-tests.sh` (`.githooks/pre-commit:239-241`,
invoked at `:270-272`). Once named test failures are trusted, **the mule can
refuse a commit**. The 2026-09-03 design explicitly forbade that, on the
grounds that a machine on a different toolchain must never be what blocks
your work. Matching toolchains is what makes it defensible now. It is still
the real change in this work, and the part to be sure about.

The two untrusted kinds still re-run locally, so a starved mule, an
out-of-disk mule, or a crashed test process cannot block a commit.

## Traps

- **There are two call sites, not one.** `run_remote` is called at
  `run-tests.sh:259` (the prefer-remote path) and again at `:300` (the
  overflow path, when local slots are busy). An executor who fixes only the
  first leaves every overflowed run still double-building. Both need the new
  exit path.
- **Do not renumber `remote_run`'s exit codes.** `build.sh:53-64` and
  `make-app.sh:380-421` both branch on `0` / `2` / else. A new numeric code
  from `remote_run` drops them into the wrong message. Export a variable
  instead. `ios.sh:322` only tests zero against non-zero and is unaffected.
- **The classifier is gated on the swift toolchain** (`remote.sh:480`), because
  `ios.sh` drives `xcodebuild`, whose output carries neither marker. Anything
  reading the new variable must cope with it being empty.
- **No test harness covers any of this.** `scripts/test-capacity.sh` tests the
  permit pool only. Verification is manual on the mule; the protocol is in the
  work order, and it is the same shape `0e622494` used.
- **Two comments in the tree state the false reason** and will mislead the next
  reader if left: `run-tests.sh:178` and `build.sh:59` both claim the Macs
  compile against different SDKs, macOS 26 there and 27 here.

## One case this does not fully solve

A starved mule produces *named* test failures, not a crash: wait-bound tests
miss their deadlines. On 2026-09-03 the six `CompanionEndToEndTests` waits
failed at load 300 and passed in 0.085 seconds on an idle machine. Those land
in the kind this work now trusts.

The job cap attacks that at the source and is already merged, so it should be
rare. Task 3 makes it diagnosable rather than mysterious by printing the
mule's load beside the verdict. Read the recommendation in the work order
before reaching for a load threshold: gating on one would silently change when
a commit gets refused.

## State

- Branch `claude/mule-failure-testing-fallback-225b1b`, clean, identical to
  `main` at `f1b7a34f`. Nothing committed, nothing staged.
- The branch has **no GitHub counterpart yet**. Push it before starting:
  `git push -u origin claude/mule-failure-testing-fallback-225b1b`.
- Size: four small tasks in four shell files. One executor, sequential, Opus
  at medium effort. Tasks 2 to 4 depend on Task 1.

## Open decision for the owner

Does `AUDIOUT_TRUST_REMOTE_FAILURE` survive? Once named failures are trusted
by default, its remaining job is "trust the other two kinds as well, during an
exploratory run". Recommendation: keep it, one line, and it finally works once
Task 1 exists. The executor should proceed on keep and not block; dropping it
later is a one-line change.
