
## Fixed for good, 2026-09-04

Item 2 above, done: `scripts/make-app.sh` now finds `.env` on its own when
the worktree it's running in has none, via `git rev-parse
--path-format=absolute --git-common-dir` to locate the primary checkout —
the same command this note already suggested, now load-bearing instead of a
copy-paste instruction a human has to remember. No behavior change for the
primary checkout itself (its own `--git-common-dir` is `.git`, whose parent
is already `$REPO_ROOT`).

Confirmed live: this exact gap reproduced again today in a different
worktree (`settle-clock-state`), the same `ERROR: POSTHOG_PROJECT_TOKEN is
required for a release bundle` exit. Fixed the script instead of copying
`.env` a second time, then proved it — deleted the worktree's `.env`,
reran `make-app.sh` there with the patched script, and it built clean with
no manual step: `TeamIdentifier=TGT8D69RZ4`, `flags=...(runtime)`, both
`com.apple.security.device.audio-input` and `.bluetooth` present.

AGENTS.md:78 updated to describe the fallback instead of the manual copy.
