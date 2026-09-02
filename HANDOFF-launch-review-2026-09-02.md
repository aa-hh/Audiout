# Launch-review fix pass — 2026-09-02, merged 2026-09-03

Fifteen findings from the pre-launch review artifact ("Audiout Launch Review",
https://claude.ai/code/artifact/c911a5a0-e8b4-46a3-85b1-11bab858f4b6) became
ten tracks, one worktree and branch per track, all forked from `main` at
`1b34ed29`. Every branch was scoped (Fable) -> spec-checked (Opus) -> executed
-> adversarially reviewed -> up to two fix passes -> committed behind the full
pre-commit guard. No agent used `--no-verify`, built an `.app`, took the
live-test slot, or touched hardware.

This file replaces the original handoff, which lived uncommitted in a worktree
that was pruned before it could be pushed. Its `work-orders/` folder is lost;
the substance survives in each PR body, which carries that track's assumptions,
owed list and verification output.

## Status: all merged to main

| PR | Track | What it does |
|---|---|---|
| [#86](https://github.com/aa-hh/Audiout/pull/86) | cadence-tracker-netting | `WriteCadenceTracker` reports netted drift, excludes idle and sleep gaps |
| [#87](https://github.com/aa-hh/Audiout/pull/87) | companion-lan-trust-notes | Documents the LAN-trust assumption and plaintext names; shared-secret brief |
| [#88](https://github.com/aa-hh/Audiout/pull/88) | hfp-rate-capture-016 | Holds a transient hands-free rate; the return rebuilds (roadmap 019) |
| [#89](https://github.com/aa-hh/Audiout/pull/89) | licence-key-paste-gate | Reads the clipboard only on an explicit Paste |
| [#90](https://github.com/aa-hh/Audiout/pull/90) | rapid-toggle-detector-2 | Cadence-proof rapid-toggle detector, ported onto main |
| [#91](https://github.com/aa-hh/Audiout/pull/91) | mixer-first-run-cues | First-session routing cue and column legends |
| [#92](https://github.com/aa-hh/Audiout/pull/92) | settings-general-consistency | One switch style, even row rhythm |
| [#93](https://github.com/aa-hh/Audiout/pull/93) | copy-label-drift | One name per thing across app, tests and docs |
| [#95](https://github.com/aa-hh/Audiout/pull/95) | header-tab-labels | Each tab's name beside its icon; Quit says the word |
| [#94](https://github.com/aa-hh/Audiout/pull/94) | agents-md-orientation-trim | AGENTS.md back to orientation size, history relocated |
| [#98](https://github.com/aa-hh/Audiout/pull/98) | foreman-roadmap-071 | Stops the full suite wandering (Alec's branch, pulled in mid-merge) |

`#94` rewrites 37 AGENTS.md files, so it landed last and absorbed every other
branch's appended lines. All 29 additions were re-applied into the matching
`AGENTS-HISTORY.md`, verified line by line; every rewritten AGENTS.md is still
inside the 300-word cap. The repo-root `AGENTS.md` is the architecture doc and
is deliberately outside that cap.

## The two rulings that unblocked the merge

Both were left open by the original handoff and decided by Alec on 2026-09-03.

**Header tabs draw at 13 pt system, not an 11 pt token.** `item.view = button`
re-stamps the cell's font before the first layout pass, so a font set at init
is gone by the time anything draws and the pill ends up sized from a
measurement of type it never shows. The font line and its assertion are
deleted; the width constraint is read from `intrinsicContentSize` at the
shipping font. Setting the font after adoption was the alternative and was not
taken.

**The hands-free hold's return rebuilds, forced.** Holding the 16 kHz reading
means no subscriber ever tracked it, so a return to the rate they still track
diverged from nothing and `deliverToSubscribers` fired nobody, while the
transition that opened the window had already silenced their taps for good.
`deliverToSubscribers(forcingRebuild:)` now bypasses the per-subscriber
divergence check at that one site. A Bluetooth connect burst pays about two
rebuilds rather than one, against the four the raw notifications buy. The
branch's own test pinned the old behaviour and is inverted; it fails on the
unforced code.

## Owed to Alec

Hardware and judgment only. Nothing below has been checked on a real machine —
the code is on main, none of it is live-verified. Full lists are in each PR body.

- **#90** — the T5 by-ear test on a signed build with an AirPlay speaker and
  `~/Library/Logs/Audiout/telemetry.jsonl` open: fast burst; steady 1-3
  clicks/s for 5 s (expect one `synced_local_churn_resync` with
  `recentTransitions >= 2`, no permanent silence); Mac-only then a fresh
  AirPlay device within a second; one unhurried select/deselect (expect no
  resync line). Accepted cost: changing your mind within ~2 s pays one brief
  re-sync.
- **#88** — Voice Memos with a Bluetooth headset while streaming (expect
  `default_output_rate_held`, no `create_and_start_done rate=16000`);
  disconnect and reconnect the headset mid-stream; a volume isolation check.
  NOTE: this test covers only the SUSTAINED window. A sub-1.2 s flip is the
  case the second ruling fixes, and this test would not catch it either way.
- **#89** — staging build on macOS 26 with an `AUDT-` key on the clipboard: no
  paste alert on launch, empty field. Click Paste key and note whether the
  system alert appears and whether Audiout then shows in System Settings'
  pasteboard pane. If it never appears there, the arrival-fill path is dead and
  can be removed. Also the two-link row look, Tab order, and VoiceOver.
- **#87** — read the new PRODUCT.md paragraph; hand
  `dev/notes/website-privacy-iphone-remote-spec.md` to the website owner and
  pick its date; decide whether to schedule the approval-secret build (three
  repos, one phone-in-hand test); confirm "on by default" stands, since the
  reviewer assumed the opposite.
- **#91** — fresh-defaults build: hint reads on one line in light and dark,
  disappears on first speaker click, stays gone across relaunch. Hover the
  Source and Offset legends (the legend row is also the collapse click target,
  so check the hover is not swallowed). Decide whether AirPlay rows should get
  an Offset control.
- **#95** — tabs read as icon + name pills and the 13 pt names sit right
  against the rest of the header; the lockup stays centred with nothing in the
  overflow menu at 623 pt; Quit draws the word; press-and-hold does not blank a
  label; VoiceOver announces each tab once.
- **#92** — all five on/off rows show a switch in one column; hints sit under
  their titles without changing row height; flip "Allow control from iPhone"
  off and on with a phone on the network. Approve or replace the reworded
  consent hint. Decide whether to regenerate the settings snapshot PNGs.
- **#93** — eyes on the popover ("App Routing" card, "Output" column, Groups
  sidebar still "System Audio" over "Main Audio"). The iPhone app
  (`audiout-remote`) and the copy-review skill still say "Main Out": reconcile
  to "Main Audio" or overrule. `docs/companion-app-store.md` lines 50 and 70
  describe the phone's "Main Out" slider.
- **#94** — read one rewritten file (suggest
  `AudioutCore/Sources/AudioutOnboardingUI/AGENTS.md`) plus the executor's list
  of must-keep bullets that fell off the cap, and decide whether 300 words is
  right for the four large files.
- **#86** — optional: sleep the Mac mid-stream, wake, confirm the next
  `write_cadence_drift` line shows `stallCount` up by one and
  `netDriftTotalSeconds` unchanged.

Leave each track's worktree in place until its check lands.

## Traps learned this run

- **A doc paragraph can land stale on main.** #88's AGENTS.md text was written
  before the review fix that shipped with it, and still claimed a returning
  reading never reaches a subscriber. It was corrected inside the #94 merge.
  When a late review fix changes behaviour, re-read the AGENTS.md that branch
  wrote.
- **The commit guard reports failure on commits that actually landed.** Twice
  the pre-commit guard printed "REFUSED: full test suite failed" while the
  commit succeeded. Check `git log` before re-running anything. #98 fixes the
  underlying wander (roadmap 071): hand-rolled wall-clock deadlines that give
  up silently under load and report as whatever the test asserted next.
- **An uncommitted handoff in a worktree is not storage.** The original of this
  file, and the `work-orders/` folder it called "the only part with no other
  copy", were pruned with their worktree. Commit a handoff on its branch and
  push it the moment it is written.
- `audiout.localSlots` was lowered during the original run and is back to 3.
  Verify with `git config --get audiout.localSlots` before blaming the machine.
- **Workflow resume cache is order-based.** `resumeFromRunId` replays only the
  longest unchanged prefix of `agent()` calls, so restructuring a script
  re-runs everything after the divergence. Bake concurrency limits into the
  first version.
- Original run id `wf_6eb82461-33f`; 81 agents on the final pass, 2 h 17 m.
