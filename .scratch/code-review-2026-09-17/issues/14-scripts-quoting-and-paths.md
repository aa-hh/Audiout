# 14 — Scripts: quote remote arguments in build.sh, drop the native engine flag from Guard 4, fix housekeeping's relative path

Status: ready-for-agent
Wave: 3
Pipeline model: opus mode
Source: [REVIEW.md](../REVIEW.md), findings scripts #1, scripts #2, scripts #3, scripts #11

Three rules written in one script and broken in another, plus two ways of resolving the script directory in the same file.

## Done when

`build.sh` quotes each argument into the remote string the way `run-tests.sh` does, and that quoting lives once in `scripts/lib/remote.sh` and is used by both. `.githooks/pre-commit` fallback build passes no `--build-system`. `housekeeping.sh:168` calls its sibling by absolute path. `run-tests.sh` and `build.sh` resolve their directory one way. shellcheck stays clean; `bash scripts/test-capacity.sh` still passes.

## Test seam

shellcheck over the touched files plus `bash scripts/test-capacity.sh`

## Verification

```bash
shellcheck scripts/build.sh scripts/run-tests.sh scripts/housekeeping.sh scripts/lib/remote.sh .githooks/pre-commit && bash scripts/test-capacity.sh
```

## Findings (verbatim from the area reports)

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
