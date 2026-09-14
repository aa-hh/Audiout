# Handoff — phone-driven speaker-sync calibration (2026-09-02)

Self-contained. Covers all three repos: `audiout-shared` (protocol), this
repo (Mac), `aa-hh/audiout-remote` (phone, private). Read
[dev/notes/make-app-worktree-env-gap.md](make-app-worktree-env-gap.md) for
the full mechanics of the build-verification bug in "Loose end" below — this
file only summarizes it.

## Where things stand

| Piece | State | Where |
|---|---|---|
| Wire protocol | **Landed.** 8 alignment commands, 2 messages, `DeviceState.alignment` | `audiout-shared` @ `21871e5`, tagged `0.3.0`, pushed to `main` |
| Mac half | **Landed**, round-1 only (see defects below) | this repo, feature commit `0d1e844a`, merged to `main` via `90ae54ba` |
| Phone half | **Landed**, round-1 only | `audiout-remote` `main` @ `d12918c` (fast-forwarded, includes the concurrent Connect-gate rewrite merge) |
| Round-2 fixes | **Scoped, not executed** — 9 defects found by the second `/scope-and-run` review, retry budget exhausted before a fix pass ran | Work order + published plan: `https://claude.ai/code/artifact/de0a06d0-6735-4869-a3ea-b4905d05b06c` (Track S: shared `alignmentApplied` message; Track M: 11 Mac steps; Track P: 11 phone steps) |
| Hardware verification | **Never done.** Everything above is compile/test-suite verified only | n/a |

Alec explicitly declined to run the round-2 fix tracks ("just prepare the
plan") — do not execute that work order without asking him first, it was
deliberately parked.

## Hardware state

Nothing on the sync feature has been exercised against real hardware. Round 1
is compile- and test-suite verified only, on both ends. The phone app was
installed on Alec's iPhone 15 Pro from `d12918c`.

For what is running right now — the dev build, the live-test slot — ask the
machine: `pgrep -f AudioutApp` and `bash scripts/livetest.sh status`.

## Loose end just found and fixed: `make-app.sh` false success

A Mac dev build was reported "built and running" when the underlying script
had actually exited 1 (missing `POSTHOG_PROJECT_TOKEN`/`POSTHOG_HOST` —
required unconditionally at
[scripts/make-app.sh:883-884](../../scripts/make-app.sh#L883-L884), unlike
the License/Buy/Sparkle checks just above it, which are properly optional for
a dev build). The failure was masked by piping the script's output through
`grep` and checking only file freshness, not the real exit code. The
resulting `.app` launched but carried none of its entitlements (no
microphone/local-network/Bluetooth/audio-input grants, hardened runtime off).

Fixed: `.env` copied into the `companion-sync` worktree (it's gitignored, so
new worktrees never get one automatically), a note added at
[AGENTS.md:78](../../AGENTS.md#L78), and a rebuild confirmed clean (real
Developer ID signature, hardened runtime on, all six entitlement keys
present).

**Not decided** — flagged for discussion, not resolved:
1. Should the PostHog requirement be gated for dev builds the same way
   License/Buy/Sparkle already are? Alec chose to supply the credential
   rather than change the gate, so the unconditional check is still live and
   will hit the next fresh worktree.
2. No script provisions a new `git worktree` with `.env` — `housekeeping.sh`
   only prunes/sweeps existing ones. If (1) stays unconditional, this is the
   actual fix needed, not another one-off copy.
3. No evidence exists (or was looked for beyond this one incident) that any
   earlier `make-app.sh` run this session produced a properly-signed bundle —
   treat any prior "Mac app built" claim from before today as unverified
   until re-checked with real exit code + `codesign -dvvv` + `codesign -d
   --entitlements :-`.

## Next steps, in order

### 1. Verify on real hardware (Agent + Alec)

Relaunch `Audiout Dev.app` (worktree `companion-sync`, `AUDIOUT_TEST_PREFER=local
bash scripts/make-app.sh` now that `.env` is in place — or revert to the
remote default, either works) and run an actual sync-probe session against
the phone on Alec's iPhone. Nothing about this feature — chirp capture,
alignment application, trim nudges — has touched real hardware yet.

### 2. Decide the round-2 fix tracks (Alec)

9 defects are sitting in shipped code (`main` in both the Mac and phone
repos). The plan is ready (link above); it needs a go/no-go, not more
scoping.

### 3. Decide the PostHog-gate question above (Alec + Agent)

Either relax `scripts/make-app.sh`'s dev-build gate, or add worktree `.env`
provisioning. Pick one before the next fresh worktree hits this again.
