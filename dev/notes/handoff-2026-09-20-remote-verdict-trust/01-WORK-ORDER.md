# Work order: trust the mule's verdict when it is a verdict

Read `00-HANDOFF.md` first. It carries the history, the safety change and the
traps. This file is the task list.

All line numbers are against `main` at `f1b7a34f`. Confirm each anchor before
editing; if one has moved, find it by the quoted text rather than trusting the
number.

Four tasks in four shell files. Sequential: tasks 2 to 4 depend on task 1.

---

## Task 1 — build the exit path for a final verdict

**Why first:** there is currently no way for `run-tests.sh` to act on a remote
failure. Every non-zero return from `run_remote` falls through to the local
suite. Until this exists, "trust the mule" has nowhere to land. See the defect
section of the handover.

**File:** `scripts/run-tests.sh`

1. Give `run_remote` a third return value, `3`, meaning the remote's verdict is
   final and this run should end on it. Document the three values in the
   comment block at `run_remote()` (`:135`), which today documents only `0`,
   `1` and `2`.

2. Handle `3` at **both** call sites. This is the trap that matters most:

   - `:259`, the prefer-remote path
   - `:300`, the overflow path, reached when the local slots are busy

   On `3`, at each site:
   - do **not** write the pass stamp to the cache
   - `exit "$remote_status"` (a global set by `remote_run`,
     `scripts/lib/remote.sh:471`, non-zero by construction here)
   - print one line saying the suite failed on the mule and was not re-run

   Nothing local has been acquired at either point, so there is no capacity
   permit to unwind. The existing comment at `:307` already says so.

3. Leave `2` doing exactly what it does now: fall through and re-run locally.

**Do not** change what `1` means or how it is handled.

---

## Task 2 — stop discarding the failure classification

**File:** `scripts/lib/remote.sh`

`remote_run` already distinguishes the three failure kinds and prints which one
it was (`:480-504`), then returns the same `2` for all three (`:505`).

1. Add a global `remote_failure_kind`, set alongside the existing
   `remote_status`. Clear it at the **top** of `remote_run`, not only on the
   failure path: it is a global, and a stale value from a previous call in the
   same script would be read as this call's answer.

2. Set it in the three branches that already exist:
   - `:487`, named failing tests, to `tests`
   - `:497`, no test verdict after N passes, to `noverdict`
   - `:500`, the build did not finish, to `nobuild`

3. Leave `remote_run`'s return value at `2` in all three cases.
   **Do not renumber `remote_run`'s exit codes.** `build.sh:53-64` and
   `make-app.sh:380-421` branch on `0` / `2` / else and a new numeric code
   drops them into the wrong message.

4. The classifier is gated on `remote_toolchain = swift` (`:480`) because
   `ios.sh` drives `xcodebuild`. Outside that gate `remote_failure_kind` stays
   empty, and every reader must treat empty as "unknown, do not trust".

**File:** `scripts/run-tests.sh`

5. In `run_remote`, replace the flat `rrc -eq 2` branch (`:176`) with a
   decision on `remote_failure_kind`:
   - `tests` -> return `3` (final verdict, from task 1)
   - `noverdict`, `nobuild`, or empty -> return `2`, re-run locally as today

6. Keep `AUDIOUT_TRUST_REMOTE_FAILURE` (`:168`). Its job is now "trust the other
   two kinds as well", and it finally works once task 1 exists: change its
   `return 1` to `return 3`. See the open decision in the handover; proceed on
   keep, do not block.

---

## Task 3 — the mule reports its load with the verdict

A starved mule produces named test failures, which task 2 now trusts. This
makes that visible instead of mysterious.

**File:** `scripts/lib/remote.sh`

1. In the ssh command string (`:424`), emit the mule's core count and load
   average beside the exit marker.

   **Preserve `$?` explicitly.** The line today is
   `$* ; echo \"REMOTE_EXIT:\$?\"`. Any command inserted before that `echo`
   clobbers `$?` and the marker reports the load reading's status instead of
   the job's. Capture the status into a variable first, then read the load,
   then echo the marker from the variable.

2. Filter the new line out of the output relayed to the user at `:449`, which
   today filters only `^REMOTE_EXIT:`.

3. Parse it beside `_marker` at `:450`. `sysctl -n vm.loadavg` returns
   `{ 1.23 4.56 7.89 }`; trim it to the one-minute figure for the message.

4. Append it to the three failure messages (`:487`, `:497`, `:500`), so a
   failure reads like:
   `3 test(s) failed: <names> (mule load 4.1, 8 cores)`

5. **Report the number. Do not gate on it.** No threshold, no behaviour change
   from the value. A threshold would silently change when a commit gets
   refused, and would be a magic number: the job cap already attacks
   starvation at its source. Mark the ceiling with a `razor:` comment naming
   the upgrade path, per the repo convention.

---

## Task 4 — correct the two comments that state the false reason

Both claim a toolchain difference that the owner re-checked and disproved on
2026-09-20. They are the stated justification for the local re-run, so leaving
them will mislead the next reader into thinking the re-run protects against
something it does not.

1. `scripts/run-tests.sh:178`, "The remote compiles against a different SDK
   (macOS 26 there, 27 here)".
2. `scripts/build.sh:59`, "Swift 6.4 but against different SDKs (macOS 27 here,
   macOS 26 there)".

Replace with the real reason the re-run survives for two of the three kinds:
machine condition, not toolchain. The mule has been out of disk and starved
before, and a crashed test process is not a verdict at all. Name the date the
toolchains were confirmed to match.

`build.sh`'s **behaviour** stays as it is. A `swift build` failure always
classifies as `nobuild`, which is a kind this work does not trust, so nothing
about the build path changes. Only its comment is wrong.

---

## Verification

There is no test harness for any of this. `scripts/test-capacity.sh` covers
the permit pool only. Verify by hand on the mule, the same way `0e622494` did.

Force each case and confirm the kind it prints and whether it re-runs locally:

| Forced case | Expect |
|---|---|
| One test made to fail | `tests`, no local re-run, exits non-zero |
| A deliberate compile error | `nobuild`, re-runs locally |
| Test process killed mid-run | `noverdict`, re-runs locally |
| Clean tree | passes on the mule, pass stamp written |

Then confirm all four of these:

- Both call sites. Force the failing test twice: once on the normal path, and
  once with the local slots occupied so the run takes the overflow path at
  `:300`. A fix applied to only one site is the most likely mistake here.
- Guard 4 refuses a commit on a trusted remote failure, and does not refuse on
  the other two kinds.
- The load figure appears in all three failure messages and does not leak into
  the relayed output on a passing run.
- Full suite green: `bash scripts/run-tests.sh`.

Always go through `scripts/run-tests.sh` and `scripts/build.sh`. Never a bare
`swift test` or `swift build`; the hook denies them and they bypass the permit
pool.

## Out of scope

- No load threshold, and no behaviour driven by the load value.
- No change to the local re-run for `nobuild` and `noverdict`. Both keep it.
- No change to `build.sh`, `make-app.sh` or `ios.sh` behaviour. `build.sh` gets
  a comment fix only.
- No change to the permit pool or the job caps.
- Do not delete `AUDIOUT_TRUST_REMOTE_FAILURE` without the owner's word.

## Before handing back

- Commit on `claude/mule-failure-testing-fallback-225b1b`, never on `main`.
- Push the branch to origin; it has no counterpart yet.
- Guard 7 runs the staged-diff self-review before any Swift commit. These are
  shell files, but run `scripts/self-review.sh` if the guard asks.
- Report which forced cases you actually ran and what the command printed. A
  reported pass is not evidence; paste the output.
