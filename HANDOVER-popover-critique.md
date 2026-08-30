# HANDOVER — Output Devices popover critique/fix/polish (`claude/impeccable-critique-polish-443502`)

Written 2026-08-29. Note: this worktree also contains `HANDOVER.md`, which
belongs to a DIFFERENT, unrelated effort (the alignment wizard) and predates
this one — ignore it for this task.

---

## 1. Where you are

**Branch:** `claude/impeccable-critique-polish-443502`, based on `main`.
**Worktree:** `.claude/worktrees/xenodochial-ardinghelli-fa348b`.
**HEAD:** `53669a5f`, clean working tree, all 8 commits pushed to origin. Not
merged. `main` is merge-only — this branch reaches it via Alec's explicit
go-ahead only.

```
53669a5f Queue agents for the one live-test slot instead of clobbering it
44a02a8c Pick the test build's bundle id by what is under test
4a14ebd6 Hover previews the click: node travels to its post-click size
bb9ab318 Grow the bus node on hover instead of ringing it
2aa18d91 Uncross the Source/Offset legends: feed pills left, sync chip right
bb83f25c Output Devices header decisions: Source/Offset legends, pinned Mac row, dot socket
5211b318 Polish pass: Older-AirPlay badge only for real AP1 receivers + fresh snapshot set
c548431b Output Devices card polish: header nesting, Feed legend, node affordance, AX headings
```

Full suite green at every commit (Guard 4 ran it each time — most recently
3026/3026 passed).

## 2. What this branch is

An `/impeccable critique` → fix → polish cycle on the macOS popover's Output
Devices card, run against Alec's own live feedback, not just automated
review. In order:

1. Dual-agent critique (design review + detector/snapshot evidence), score
   30/40. Snapshot: `.impeccable/critique/2026-08-28T08-53-03Z__e-sources-audioutpopoverui-popovercontroller-swift.md`.
2. Fix wave for the critique's P1/P2 findings: subsection header indent +
   rhythm, Feed legend anchor, hover ring, header hover wash, "+" footer AX
   label, VoiceOver headings.
3. Polish pass: regenerated all 22 popover snapshots, caught and fixed a real
   bug (This Mac's feed pill truncating to "Older" — `supportsAirPlay2` is
   false on non-AirPlay device kinds too, not just AirPlay 1 receivers).
4. Four design decisions from Alec, live-checked on real builds: "Feed" →
   "Source", "Sync" → "Offset", This Mac pinned under the card header (no
   more one-row subsection), dark-mode dot socket `#34302A` → `#4A443B`.
5. Two more rounds of Alec's live feedback on the resulting build: the
   Source/Offset legends were crossed over their columns (fixed — sync rows
   now lay out pill-left/chip-right like every other row); the hover cue
   ballooned to a fixed 10pt ring instead of previewing the actual post-click
   size (fixed — node now tweens between its real resting size and its real
   post-click size, 5.5↔7.5pt, never a size that doesn't exist elsewhere in
   the UI).
6. A live debugging session (separate background agent, `ptp-debugger`,
   still resumable by that name) diagnosed why fresh test builds started
   throwing `SMAppServiceErrorDomain Code=1` on 2026-08-28 — see §4.
7. Built `scripts/livetest.sh`, a machine-wide slot so parallel agents don't
   clobber Alec's in-progress hardware test of the shared dev bundle id —
   see §5.

## 3. What's still owed before merge

- **Alec's live check of the CURRENT build is not done.** The last thing
  verified on real hardware was v5, which predates the Source/Offset
  crossing fix and the hover-size fix (those landed as `2aa18d91` and
  `4a14ebd6`/wave-2 correction after v5 was built). **Build a fresh
  `Audiout Dev` before trusting the visual state** — see §6 step 3.
- **Merge go-ahead.** Never merge without it (standing rule).
- Figma design-system mirror of the Tokens/PopoverColumnGrid renames — Figma
  MCP was unauthenticated all session. Owed separately, not blocking.

## 4. The BTM/permissions detour (context you need before building anything)

Since 2026-08-28 ~06:49, this Mac refuses `SMAppService` daemon registration
for any NEW bundle id until one manual "Allow in the Background" approval —
traced to a silent Gatekeeper config update (XProtect 5357) meeting the
macOS 27 beta's btmd. Full writeup:
`~/.claude/projects/-Users-alechenderson-Projects-AirPlay-Controller/memory/btm-approval-wall-new-bundle-ids.md`.

**This produced a revised, STANDING project rule** (now in this branch's
`CLAUDE.md`, "Build & run"): pick the bundle id by what you're testing.

- Testing the permissions path itself → fresh id, every time.
- Everything else (this branch's UI work included) → reuse the standing
  `com.audiout.Audiout.dev` id, approved once, silent forever after.

**Alec was mid-sequence to prove that persistence claim when this session
paused:** he ran `sudo sfltool resetbtm` (wipes the whole BTM database,
system-wide) and was restarting the Mac. The plan, unfinished as of this
write-up:

1. ~~`sudo sfltool resetbtm` + restart~~ — Alec confirmed he ran the command;
   **restart completion was NOT confirmed before this handover was written**
   (`uptime` showed 16h45m continuous at write time — check `uptime` before
   assuming the reboot happened).
2. Launch `Audiout Dev.app`, approve Login Items + audio/network/Bluetooth
   prompts once.
3. Rebuild the exact same command, relaunch, confirm NO prompts return. This
   is the actual proof the revised rule rests on — don't skip it.
4. Alec's live check of the popover (§3).
5. Merge go-ahead.

A `build/Audiout Dev.app` already exists in this worktree from before the
pause — but it predates the Source/Offset and hover fixes (§2.5), so **build
fresh, don't reuse it**, once you're clear to build (§5).

## 5. The live-test slot — READ THIS, its state is not what you'd assume

`scripts/livetest.sh` (this branch only — NOT on `main`, NOT in any worktree
forked from `main`; a real gap flagged by a peer session, see §7) serializes
access to the shared `com.audiout.Audiout.dev` id, since only one native
instance can run at a time (PTP ports exclusive) and only one copy of that id
should exist on disk at once. `make-app.sh` refuses to build that id unless
the caller holds the slot.

**Current actual state (checked at write time, not assumed):**

```
$ bash scripts/livetest.sh status
live-test slot: HELD by "cast-live" for 5h52m — EXPIRED (past 45m).
  worktree: .claude/worktrees/oss-license-reference-audit-5307f7
```

This session acquired the slot earlier as `impeccable-critique-polish` and
**never called `done`** — it got pulled into the reboot conversation with
Alec and the hold expired on its own. A peer session (branch
`claude/cast-delay-sync-proposal-7737fe`, roadmap 006 Cast sync) was told to
wait rather than take a fresh id, since Alec's permissions sequence took
priority. At some point after that it (or another agent in that worktree)
took over the expired slot under a NEW label `cast-live` — consistent with
actually starting a live hardware test, but **no Audiout process is
currently running under that worktree**, so it may itself be a forgotten
hold rather than an active test. Do not assume either way.

**Before you build or launch `Audiout Dev`:**

```bash
bash scripts/livetest.sh status
```

If it's still held by `cast-live` with no corresponding running process, that
is very likely a second forgotten release — but the documented protocol is
to warn and ask, not silently take over, in case Alec is mid-test through
that other worktree. If genuinely stuck, `bash scripts/livetest.sh done
--force` clears it (say so to Alec first if you're not the one who just
confirmed no test is running).

A completely unrelated worktree (`mac-audio-single-device-bug-1f9651`) has
its own build (`Audiout VolFix6.app`) running right now — that's fine, it's a
fresh handover id and correctly bypasses the slot entirely. Not a conflict.

## 6. Exact next steps (resume here)

```bash
# 1. Confirm the restart actually happened
uptime

# 2. Check the live-test slot — see §5 before assuming you can just take it
bash scripts/livetest.sh status
bash scripts/livetest.sh acquire --label impeccable-critique-polish

# 3. Build fresh (do NOT reuse the pre-pause build/Audiout Dev.app)
AUDIOUT_BUILD_LOCAL=1 APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" \
  bash scripts/make-app.sh

# 4. Launch, let Alec approve permissions once
open "build/Audiout Dev.app"

# 5. Prove persistence: rebuild the SAME command, relaunch, confirm silence
AUDIOUT_BUILD_LOCAL=1 APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" \
  bash scripts/make-app.sh
open "build/Audiout Dev.app"   # should show zero prompts

# 6. Alec live-checks the popover (Source/Offset alignment, hover grow-to-
#    post-click-size, header nesting, dark-mode dot). Release when done:
bash scripts/livetest.sh done

# 7. Merge only on Alec's explicit go-ahead.
```

## 7. Loose end for Alec, not blocking

A peer session pointed out that `scripts/livetest.sh` and the `make-app.sh`
dev-id guard exist ONLY on this branch. Verified: `main` has neither.
Every worktree forked from `main` can build over `com.audiout.Audiout.dev`
with nothing stopping it and no way to discover the queue exists — the
mechanism only protects agents who already have it. Worth merging this
branch (or backporting just `livetest.sh` + the `make-app.sh` guard) sooner
rather than later for that reason alone, independent of the popover work's
own merge readiness.

## 8. Related memory (for whichever agent resumes)

- `impeccable-popover-critique-polish.md` — the critique/fix/polish
  narrative.
- `btm-approval-wall-new-bundle-ids.md` — the permissions investigation.
- `feedback-every-build-unique-bundle-id.md` — the revised bundle-id rule.
- `livetest-slot-queue.md` — the queue mechanism.
