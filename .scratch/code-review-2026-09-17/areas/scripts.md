# Build scripts, git hooks, dev tooling — review

## Verdict

This is the strongest-written area of the repo for a cold reader: quoting discipline is genuinely
good (I found no unquoted path variable anywhere, and shellcheck across all 36 shell files returns
only sourcing notes and four harmless `SC2154`s), every lock has a trap, every destructive path in
`purge-dev-installs.sh` runs through an `assert_not_prod` gate, and the headers explain *why* rather
than *what*. The weak spots are all the same shape — a rule written down carefully in one script and
then not followed in a second. `scripts/build.sh:53` sends caller arguments to the remote Mac with
the exact unquoted `$*` that `scripts/run-tests.sh:161-168` has a six-line comment forbidding;
`.githooks/pre-commit:246` passes `--build-system native` twenty lines under its own comment saying
it must not; `scripts/housekeeping.sh:168` shells out to a relative path in a script every other line
of which is absolute, which silently disables its PTP-helper warning. The single highest-impact
change is fixing `build.sh:53` to reuse the per-argument quoting `run-tests.sh` already wrote, and
then moving that quoting into `lib/remote.sh` so the third caller cannot get it wrong either.

## Findings

### 1. [BUG] `build.sh` hands caller arguments to the remote shell unquoted — the exact failure `run-tests.sh` documents and defends against

- Where: `scripts/build.sh:53`, contrast `scripts/run-tests.sh:161-171`
- Evidence:
  ```sh
  # scripts/build.sh:53
  remote_run "$repo_root" "cd \"$package\" && swift build $*" || rrc=$?
  ```
  ```sh
  # scripts/run-tests.sh:161-168
  # The remote command is a STRING the far shell re-parses, so caller flags
  # must be quoted INTO it: an unquoted `--filter "A|B"` arrived there as a
  # pipe into a command named `B`. Single-quote each argument, escaping any
  # single quote it contains ('\'' — the standard sh idiom).
  qargs=""
  for a in "$@"; do
      qargs="$qargs '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'"
  done
  ```
- Why it matters: `remote_run`'s command is re-parsed by the mule's shell. Any `build.sh` argument
  containing a space, `|`, `;`, `*`, `$` or a quote is re-split or interpreted there — the usage
  block's own example `scripts/build.sh -c release` is safe, but `-Xswiftc -DFOO="a b"` or any
  quoted value is not. The failure is silent: the remote build compiles something other than what
  was asked, reports success, and `build.sh:56` exits 0.
- Fix: lift `run-tests.sh`'s `qargs` loop into `scripts/lib/remote.sh` (it is the one place all three
  callers share) and have both `build.sh` and `run-tests.sh` call it.
- Confidence: high

### 2. [BUG] Pre-commit Guard 4's fallback build uses the dead `native` engine, contradicting its own comment and three other scripts

- Where: `.githooks/pre-commit:246`, comment at `.githooks/pre-commit:224-227`
- Evidence:
  ```sh
  # .githooks/pre-commit:224-227
  # No engine flag: the SwiftPM default matches scripts/run-tests.sh and
  # scripts/make-app.sh — see the note above run-tests.sh's `swift test` call.
  ...
  # .githooks/pre-commit:245-246
  ( cd "$repo_root/AudioutCore" \
      && $nogit swift test --build-system native --parallel >&2 )
  ```
  `scripts/run-tests.sh:63` — "Do NOT add an engine flag back here alone."
  `scripts/build.sh:43` — "Do NOT reintroduce a per-script engine flag."
  `scripts/housekeeping.sh:294` — `dead_engine_dir=arm64-apple-macosx`, the tree this flag produces.
- Why it matters: on a branch old enough to lack `scripts/run-tests.sh` (the case this fallback
  exists for) the hook builds a second ~1.3 GB cache tree that `housekeeping.sh` is separately
  written to delete as unreachable, so the commit pays a full cold compile and then loses the cache.
  It also breaks the invariant `housekeeping.sh:268-307` relies on.
- Fix: delete `--build-system native` from line 246.
- Confidence: high

### 3. [BUG] `housekeeping.sh` calls a sibling script by relative path, silently disabling its PTP-helper warning

- Where: `scripts/housekeeping.sh:168`; callers `scripts/run-tests.sh:55`, `scripts/make-app.sh:289`
- Evidence:
  ```sh
  # scripts/housekeeping.sh:168
  stale_helpers_output=$(bash scripts/purge-stale-ptp-helpers.sh 2>/dev/null || true)
  ```
  Every other path in the file is absolute (`$primary`, `$worktrees_dir`, `$wt`, `$xcode_dir`), and
  the script never `cd`s. `make-app.sh:289` invokes it as `"$SCRIPT_DIR/housekeeping.sh"` from
  whatever cwd the caller had.
- Why it matters: when cwd is not a repo root the command fails, `2>/dev/null || true` hides it,
  `stale_helpers_total` falls back to 0, and the "stale PTP helper is squatting on UDP 319/320"
  warning never fires — the failure mode AGENTS.md says has piled up 16-deep. This is the same
  silent-disable the file's own `in_use` comment (lines 84-89) was written to fix.
- Fix: resolve it beside this script, as `run-tests.sh:54` does:
  `bash "$(cd "$(dirname "$0")" && pwd)/purge-stale-ptp-helpers.sh"`.
- Confidence: high

### 4. [BUG] `make-app.sh` leaks five `mktemp -d` directories on every run that builds an icon

- Where: `scripts/make-app.sh:649`, `:694`, `:729`, `:741`, `:784`
- Evidence: `grep -n 'ACTOOL_TMP\|XCASSETS_DIR\|ACTOOL_LD_TMP\|VERIFY_SWIFT\|ICONSET_DIR'` shows each
  variable assigned from `mktemp -d` and then only read — no `rm -rf` and no trap covers them. The
  script's other temp dir is cleaned (`:351`, `:357`, `:410` for `$STAGE`), so the omission is
  inconsistent with its own practice.
- Why it matters: `ICONSET_DIR` alone holds ten PNGs resized from two ~2.5 MB 1024x1024 sources, and
  `XCASSETS_DIR` holds forty. In a repo whose main recorded incident is the disk reaching zero bytes
  free — the reason `housekeeping.sh` exists at all — a build script that leaks tens of megabytes
  per invocation works against the thing it calls on line 289.
- Fix: add each to the existing EXIT trap, or `rm -rf` each at the end of its own block.
- Confidence: high

### 5. [BUG] `renderPNG` failures never reach the exit code — every snapshot tool exits 0 unconditionally

- Where: `AudioutCore/Sources/popover-snapshot/main.swift:1032` and `:1124`; same shape in
  `window-snapshot/main.swift:495`, `onboarding-snapshot/main.swift:303`,
  `settings-snapshot/main.swift:254`
- Evidence:
  ```swift
  // popover-snapshot/main.swift:96-135 (renderPNG)
  guard let data = rep.representation(using: .png, properties: [:]) else {
      print("  FAIL  could not encode PNG for \(url.lastPathComponent)")
      return
  }
  do { try data.write(to: url) ... } catch { print("  FAIL  write ...: \(error)") }
  ```
  `func run() -> Int32` has ten `return 0` statements and no other value; the last line is
  `exit(MainActor.assumeIsolated { run() })`.
- Why it matters: a run that wrote nothing — wrong output directory, full disk, encode failure —
  exits 0 and looks green to any script or agent that checks the status rather than reading the
  transcript. The repo has a named trap for exactly this class ("a non-matching `--filter` passes
  green"), and `run-tests.sh:386-392` goes out of its way to solve the same problem for the suite.
- Fix: have `renderPNG` return `Bool` and `run()` return 1 when any capture failed.
- Confidence: high

### 6. [SUBSTANCE] `renderPNG` is byte-identical in three snapshot executables, comment included

- Where: `AudioutCore/Sources/popover-snapshot/main.swift:96`,
  `AudioutCore/Sources/onboarding-snapshot/main.swift:201`,
  `AudioutCore/Sources/settings-snapshot/main.swift:63`
- Evidence: all three are the same 32 lines, down to the four-line comment beginning
  "`NSBitmapImageRep(bitmapDataPlanes:...)` doesn't guarantee a zeroed buffer". `snapshotAppearance`
  is likewise identical in all three (`:57`, `:47`, `:35`); `tempDir` differs only in its prefix
  string across `popover-snapshot:77`, `window-snapshot:66`, `settings-snapshot:47`;
  `makeSnapshotDefaults` is repeated in `window-snapshot:488`, `onboarding-snapshot:125`,
  `settings-snapshot:105`; `waitForFleet` / `drain` in `popover-snapshot:64,73` and
  `window-snapshot:175,184`.
- Why it matters: five helpers hand-copied across five executables. A fix to the zeroing logic or the
  failure reporting (finding 5) has to be made in three places and will not be. This is the same
  hazard `.githooks/guard-shared-leak.sh` exists to prevent across repos, unpoliced within one.
- Fix: one `SnapshotSupport` target in `AudioutCore/Package.swift` that the five snapshot executables
  depend on; `window-snapshot`'s capture-until-stable variant stays local.
- Confidence: high

### 7. [BUG] `housekeeping.sh`'s "is anything running out of this path" gate fails open on a path with regex metacharacters

- Where: `scripts/housekeeping.sh:97-105`
- Evidence:
  ```sh
  in_use() {
      for pid in $(pgrep -f "$1" 2>/dev/null); do
  ```
  `$1` is a filesystem path (`$primary/.claude/worktrees/<slug>`) handed to `pgrep -f`, which takes an
  extended regular expression, not a literal.
- Why it matters: `in_use` is the safety gate on both destructive jobs — it guards `git worktree
  remove` at line 115 and every cache delete at line 250. A worktree slug containing `+`, `(`, `[` or
  `?` makes `pgrep` exit with a usage error, the loop iterates zero times, `in_use` returns 1, and
  the worktree reads as free while a build is running in it. A gate that fails open is worse than no
  gate, and the function's own comment (lines 84-89) says this check was already silently broken once.
- Fix: `pgrep -lf` over a fixed-string match, or quote the metacharacters:
  `pgrep -f "$(printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"`.
- Confidence: medium (no current worktree name triggers it; the hole is latent)

### 8. [BUG] `reap-orphaned-swift.sh` will SIGKILL an app launched by `run-app.sh` once its launching shell exits

- Where: `scripts/reap-orphaned-swift.sh:35-39`; interaction with `scripts/run-app.sh:36`
- Evidence:
  ```sh
  # reap-orphaned-swift.sh:35-39
  for pid in $(pgrep -f '/(swift|swift-build|swift-frontend|swiftpm|swift-test|swiftpm-testing-helper)([[:space:]]|$)' 2>/dev/null); do
      ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      [ "$ppid" = "1" ] || continue
      ...
      kill -9 "$pid" 2>/dev/null || continue
  ```
  ```sh
  # run-app.sh:36
  exec swift run --package-path "$SCRIPT_DIR/../$pkg" "$product" "$@"
  ```
- Why it matters: `run-app.sh` replaces itself with `swift run`, which is meant to live "for as long
  as the app runs" (its own comment at line 32-35). When the shell that launched it goes away — an
  agent session ending, a backgrounded launch — that `swift run` reparents to PID 1 and matches the
  reaper's pattern exactly. `build.sh:31` and `make-app.sh:29` both run the reaper unconditionally at
  startup, so the next build by any agent on the machine kills the app under test with no message the
  tester will see. The script's own reasoning ("nothing legitimate is reading its output") does not
  hold for `run-app.sh`, which is a long-lived app, not a compile.
- Fix: skip a process whose command line contains `swift run`, or have `run-app.sh` write a pidfile
  the reaper checks.
- Confidence: medium (I traced both scripts; I did not observe the kill)

### 9. [SUBSTANCE] Root `AGENTS.md` states three housekeeping thresholds that no longer match the code

- Where: `AGENTS.md:170-178` vs `scripts/housekeeping.sh:194,201,205`
- Evidence: AGENTS.md says "untouched for `AUDIOUT_CACHE_MAX_AGE_DAYS` (7)", "below
  `AUDIOUT_MIN_FREE_GB` (8) free disk", "Below `AUDIOUT_CRITICAL_FREE_GB` (2)". The code reads
  `max_age_days=${AUDIOUT_CACHE_MAX_AGE_DAYS:-3}`, `min_free_gb=${AUDIOUT_MIN_FREE_GB:-15}`,
  `critical_gb=${AUDIOUT_CRITICAL_FREE_GB:-6}`, each with a dated comment explaining the change
  (7->3 and 8->15 on 2026-08-29).
- Why it matters: AGENTS.md is the file this repo tells every agent to read before touching the
  folder, and all three numbers in the paragraph about disk safety are wrong by a factor of 2. An
  agent reasoning about whether a build will have room reasons from 8 GB when the script targets 15.
  Related, smaller: `scripts/lib/remote.sh:73` defaults `remote_slots` to 2 where AGENTS.md:190 and
  CLAUDE.md both say 3 (masked on this machine by `git config audiout.remoteSlots`, but a fresh
  clone gets 2).
- Fix: update the three numbers in AGENTS.md; they are the script's own documented values.
- Confidence: high

### 10. [SUBSTANCE] `license-gate-preview` is a dead executable target

- Where: `AudioutCore/Sources/license-gate-preview/main.swift` (140 lines),
  declared in `AudioutCore/Package.swift`
- Evidence: `grep -rIl 'license-gate-preview' .` outside its own directory returns exactly two files
  — `AudioutCore/Package.swift` (its own target declaration) and its own `main.swift`. No script,
  no `AGENTS.md`, no `docs/`, no `dev/notes/`, no `ROADMAP.jsonl` entry mentions it. For contrast,
  every other tool target has at least one external reference: `core-audio-diagnostic` is named in
  root `AGENTS.md`, `process-audio-dump` in two `docs/plans/`, `mic-probe-spike` and `cast-spike` in
  `ROADMAP.jsonl` and `dev/notes/`.
- Why it matters: it is compiled by every swift build of the package and read by every reviewer
  looking for the licence-gate surface, and nothing invokes it.
- Fix: delete the target and its directory, or add the one line to `AudioutCore/AGENTS.md` saying how
  it is run.
- Confidence: high

### 11. [SUBSTANCE] `run-tests.sh` and `build.sh` resolve their own directory two different ways in the same file

- Where: `scripts/run-tests.sh:353` vs `:54` and `:130`; `scripts/build.sh:31` vs `:48`
- Evidence:
  ```sh
  # run-tests.sh:353 — in a #!/bin/sh script
  bash "$(dirname "${BASH_SOURCE[0]}")/reap-orphaned-swift.sh" || true
  # run-tests.sh:54 and :130, correct for /bin/sh
  hk="$(cd "$(dirname "$0")" && pwd)/housekeeping.sh"
  . "$(cd "$(dirname "$0")" && pwd)/lib/remote.sh"
  ```
  shellcheck: `SC3028` / `SC3054` on both files ("In POSIX sh, BASH_SOURCE is undefined").
- Why it matters: it works today only because macOS's `/bin/sh` is bash in POSIX mode. Under `set -u`
  on any other `sh` it aborts the script outright, and either way a cold reader has to decide which
  of the two idioms in the same file is the intended one.
- Fix: use `$(dirname "$0")` in both, matching the other lines in the same files.
- Confidence: high

### 12. [SUBSTANCE] Two empty files are committed under `dev/`

- Where: `dev/log`, `dev/audiocap/object`
- Evidence: `git ls-files` lists both; `ls -la` shows both at 0 bytes; `file` reports "empty". Neither
  is named in `dev/AGENTS.md`'s Map or `dev/.gitignore`.
- Why it matters: leftover redirect targets (`> log`, `2> object`) checked in. A reader opening
  `dev/` cannot tell them from real fixtures, and `dev/AGENTS.md` says "`.run/` is generated state" —
  implying everything else in `dev/` is not.
- Fix: `git rm dev/log dev/audiocap/object`.
- Confidence: high

### 13. [SUBSTANCE] `dev/AGENTS.md`'s Map omits eight of the files in `dev/`

- Where: `dev/AGENTS.md:21-28`
- Evidence: the Map lists `fake-speakers.sh`, `stop-fake-speakers.sh`, `audiocap/`, `phase-spike/`,
  `spikes/`, `notes/`, `README.md`. Not listed and present: `gated-session-step1.sh`,
  `gated-session-step2.sh`, `verify-0f2-prep.sh`, `verify-0f2-e2e.sh`, `verify-0f3-soak.sh`,
  `drift-clock-step-fit.py`, `drift-window-analysis.py`, `test-drift-clock-step-fit.py`, plus
  `symbols/` and the 4.4 MB `probe-tone.raw` (referenced only by `gated-session-step1.sh`).
- Why it matters: the repo's stated rule is "read the nearest AGENTS.md before editing or tracing
  code in that folder". Six runnable scripts that nothing in the Map accounts for is exactly the gap
  the rule is meant to close.
- Fix: add the six scripts and the two data directories to the Map, one line each.
- Confidence: high

### 14. [SUBSTANCE] `popover-snapshot/main.swift` is 1,125 lines in one file, dispatched by a nine-branch if-chain

- Where: `AudioutCore/Sources/popover-snapshot/main.swift:1032-1113`
- Evidence: `wc -l` = 1125. `run()` is 82 lines of
  ```swift
  if mode == "connection-states" { ...two calls...; print("Done."); return 0 }
  if mode == "live-routing"      { ...two calls...; print("Done."); return 0 }
  ```
  repeated nine times with only the function name changing, ahead of a default four-call block.
- Why it matters: a cold reviewer has to read 1,125 lines to know what the tool renders, and the
  dispatch is nine copies of a three-line body that a `switch` over a
  `[String: (NSAppearance.Name, String, URL) -> Void]` collapses to one.
- Fix: split the nine `snapshot*` scenario functions into their own files in the same target, and
  replace the if-chain with a `switch` (or a dictionary lookup) that also reports an unknown mode
  instead of silently falling through to the default render.
- Confidence: high

### 15. [SUBSTANCE] The self-review receipt hash is computed independently in two files

- Where: `scripts/self-review.sh:31` and `.githooks/guard-self-review.sh:65`
- Evidence:
  ```sh
  # scripts/self-review.sh:31
  hash=$(git diff --cached -- '*.swift' | shasum -a 256 | cut -d' ' -f1)
  # .githooks/guard-self-review.sh:65
  expected=$(git diff --cached -- '*.swift' | shasum -a 256 | cut -d' ' -f1)
  ```
  `self-review.sh:29-30` acknowledges it: "Identical computation to guard-self-review.sh's".
- Why it matters: the two are the producer and the verifier of the same receipt. If either changes —
  adding `--diff-filter`, a pathspec, `-w` — Guard 7 refuses every Swift commit on the machine with a
  message that tells the committer to re-run the script they just ran. Duplicating the one line that
  must never disagree is the wrong half to duplicate.
- Fix: have `guard-self-review.sh` source a two-line helper (or call `self-review.sh --hash-only`).
- Confidence: high

### 16. [COSMETIC] `run-tests.sh`'s local-slot comment argues for a number the machine no longer uses

- Where: `scripts/run-tests.sh:111-121`
- Evidence: "Lowered 4 -> 3 (owner's call, 2026-08-30)" above
  `slots=${AUDIOUT_TEST_SLOTS:-$(git config --get audiout.localSlots 2>/dev/null || echo 3)}`.
  CLAUDE.md and AGENTS.md:188 both say `audiout.localSlots` was set to 2 on 2026-09-10, which is what
  actually applies.
- Why it matters: eleven lines reasoning about why 3 is right, sitting above a value that is 2 in
  practice. A reader tuning capacity reads the argument for the wrong number.
- Fix: one line noting the live value comes from `git config` and is currently 2.
- Confidence: high

## Also noted

- `scripts/run-on-vm.sh:124` — `LAUNCH_LOG="$(mktemp -t run-on-vm)"` is never removed and has no
  trap; `scripts/lib/remote.sh:361` `_rr_out` is removed inline at `:434` but leaks if the runner is
  interrupted during the `wait`.
- `scripts/run-tests.sh:171` — `"cd $pkg && swift test ..."` leaves `$pkg` unquoted in the remote
  command string where `scripts/build.sh:53` quotes the same value.
- `scripts/housekeeping.sh:241` — `skippable()` returns 0 for "may be deleted" while every `say()`
  inside it prints "keeping…"; the name reads backwards at all three call sites.
- `scripts/housekeeping.sh:76` — the lock trap `rm -f "$lock"` does not verify ownership, unlike
  `capacity_release` in `lib/remote.sh:667`, which explicitly refuses to delete a permit that is no
  longer its own.
- `scripts/livetest.sh:230-233` — `write_meta` runs after `shlock` succeeds, so a concurrent
  `status`/`check` in that window reads the *previous* holder's label from `$meta_file`.
- `AudioutCore/Sources/core-audio-diagnostic/main.swift:24` — `buf.baseAddress!` force-unwraps a
  buffer pointer on the return path of `proc_pidinfo`, OS-supplied data.
- `AudioutCore/Sources/settings-snapshot/main.swift:172-173` — `field.cell!` force-unwrapped twice.
- `dev/fake-speakers.sh:32,42,107,115` — box-drawing rules and `✗`/`⚠`/`•` glyphs in source output.

## Counts

BUG: 6 · SUBSTANCE: 9 · COSMETIC: 1 · files read: 46 / files in area: 89
