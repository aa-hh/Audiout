# Handoff — live-test the alignment-wizard-default work

Date 2026-09-03. Written for whichever agent picks up live testing next.
Everything below is what I know as of handoff; verify anything you rely on
rather than trusting it blind.

## What this branch does

Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/delay-trim-sync-wizard-b99148`
Branch: `claude/delay-trim-sync-wizard-b99148`
Work order (full spec, already executed): [`dev/notes/first-mix-wizard-default-work-order.md`](first-mix-wizard-default-work-order.md)
Approved mock (three rounds, all decisions traceable): claude.ai/code/artifact/11ed7cb2-fa33-447d-b11c-370c11337f49
Critique snapshot: `.impeccable/critique/2026-09-03T01-59-30Z__urces-audioutpopoverui-btalignmentpromptview-swift.md` (27/40, pre-fix)

Alec's direction: the guided alignment wizard becomes the default way to
sync a Bluetooth speaker's delay. The old three-button "first-mix card"
(Align with your music / Align with ticks / Not now) is gone, along with
its hold-silent join and its permanent dismissal. The Mac popover row now
advertises the sync tool and the equalizer the way the iPhone app already
does, without adding a fourth column.

**Nine decisions, each confirmed with Alec via a structured question,
recorded in memory as [[first-mix-wizard-default-decisions]]:**

1. No hold-silent. A never-aligned Bluetooth speaker plays immediately,
   out of step, from the moment it joins a mix.
2. No permanent dismissal. The old "Not now" forever-record is deleted.
3. The wizard never auto-opens. On first join, a one-sentence note mounts
   under the row (this is the phone's invite-card pattern, on the Mac's
   inset seat). It stays until the speaker is measured; its ✕ hides it
   for the current session only, and it comes back next launch if the
   speaker is still unmeasured.
4. The untuned Bluetooth chip is the tuning fork: reads **Align** with a
   `tuningfork` glyph, opens the wizard directly. A measured chip is
   today's readout and opens the drawer.
5. The drawer gained **Align again…** (re-runs the wizard) beside
   **Align by ear** (the metronome). **Revert** and the hidden ⌥-click
   are both deleted.
6. The equalizer is a button beside mute, on every row that has an
   equalizer (AirPlay + Bluetooth; not the Mac's own row). Secondary ink
   at rest; a 1 pt **magenta** (`Tokens.Color.partySignal`, the wizard's
   reference-light colour) outline when that speaker's curve is not
   flat. The glyph itself never changes colour — only the border.
7. The popover (and the Groups window, same frame) widened
   `SurfaceLayout.width` 623 → 653 to make room, at Alec's explicit call
   ("we can expand the total width of our app").
8. The wizard stays a sheet — Alec live-approved that across v7-v14; this
   branch doesn't touch it.
9. **The iPhone app is completely untouched.** Alec's opening phrasing
   ("the tuning fork should trigger the Mac wizard") was a misstatement
   he corrected mid-session — he meant the Mac row should advertise the
   tool the way the phone's fork glyph already does, not that the phone
   should remote-control the Mac's sheet. Do not build that.

## Build state right now

A signed dev build is **already running** as of this handoff:

- App: `build/Audiout Dev.app`, bundle id `com.audiout.Audiout.dev`
- Built from the branch **after merging `origin/main`** (see below) — HEAD
  is `1179057d`, tree has the branch's changes staged on top, nothing
  committed yet.
- Launched via `open "build/Audiout Dev.app"`. Check `pgrep -lf "Audiout Dev"`
  before assuming it's still up — Alec may have quit it between sessions.
- **Live-test slot**: I hold it, label `delay-trim-sync-wizard-b99148`, ~25
  min left as of this handoff (`bash scripts/livetest.sh status` to check
  the real number). **Re-acquire under your own label before you build or
  relaunch** — don't assume my hold is still valid, and don't skip the
  check because the app happens to still be running. If you don't need to
  change code, you don't need the slot at all to just look at what's
  already open.
- `.env` is present in this worktree (copied from the main checkout,
  gitignored, needed for `POSTHOG_PROJECT_TOKEN` at build time — see
  Traps below). Leave it; don't recopy unless it goes missing.

## Live-test progress (2026-09-03, second session)

**Passed by eye on the dev build, dark AND light:** the untuned chip (dashed,
`tuningfork`, "Align"), the 653 pt frame with nothing clipped and the
Source/Offset headers over their columns, no equalizer button on the Mac's own
row, the equalizer button leading of mute everywhere else. `supportsEqualizer`
is `!isLocalDevice && kind != .localMac`, so CAST rows carry one too — that is
the same predicate the existing context-menu item already used, not a defect.

**Passed by code:** all four analytics checks (item 10) — `door` on both
`bt_sync:wizard_started` and `eq:opened`, `bt_sync:note_hidden` on the ✕, and
`method_chosen` gone from the tree.

**Tests:** the nine touched suites are green (242 tests), and so are the
neighbouring nine (154 tests).

**ONE REAL BUG FOUND AND FIXED.** Clicking Align on a connected speaker that
was not in a mix did nothing at all — no sheet, no message.
`startBTAlignmentWizard` guarded on `btAlignmentTargetIsLive`
(`isAvailable && wantsAudio`) and dropped the click with a bare `return`,
while the chip's own enablement is only `device.isAvailable`
(`DeviceRowView.swift:742`). Alec's ruling: **the click IS the join** — it
selects the speaker into the mix and runs (he rejected dimming the chip, and
rejected a transient explain-on-click line). The target then STAYS in the mix,
unlike the run's reference, which `engageBTWizardReference` borrows and hands
back. Fixed at that one shared entry point so the chip, the note and the
"Align speaker…" menu item all inherit it; a refused join now speaks through
`handleSelection` instead of vanishing. Two tests cover it. Alec live-verified:
"it worked".

**Still owed** — everything that needs a speaker in a mix and a pair of ears:
items 2, 3, 5, the magenta EQ outline in item 7, and the two-speaker case.

## What to actually check

Walk through with a real Bluetooth speaker if one's available; the app is
in `AIRPLAY_BACKEND=native` mode as a signed build, so mock speakers won't
appear unless you also set the env var and relaunch.

1. **Untuned Bluetooth row.** Its Offset chip reads **Align** with a
   tuning-fork glyph, dashed outline (same visual weight "not set" used
   to have). Click it → the wizard sheet opens directly, no card.
2. **First join of a never-aligned speaker.** It should be **audible
   immediately** — no silence, no 2-minute hold. A one-line note appears
   under its row: "`<name>` will play a little behind the other speakers
   until it's aligned. **Align it now.**" Click the sentence → wizard
   opens. Click ✕ → note disappears; it should NOT come back until you
   quit and relaunch the app (session-only hide) — verify by re-adding
   the same speaker to a mix without relaunching (should stay hidden) vs.
   after a relaunch (should reappear, since it's still unmeasured).
3. **Tuned Bluetooth row.** Its chip shows the measured offset (e.g.
   "−22 ms"), click opens the drawer. Drawer band should read
   **Align again…** · **Align by ear** · **Reset alignment** · the ±
   stepper cluster. No Revert button. ⌥-clicking the metronome should do
   nothing special now (no hidden wizard shortcut) — the visible
   **Align again…** button is the only door.
4. **Reset alignment.** Click it on a tuned row: drawer should collapse
   (this was one of the fix-batch items — a stale/open drawer with no
   door back to it was a real bug caught in review) and the chip should
   flip back to **Align**.
5. **Cast row**, if you have one: drawer should show NO "Align again…"
   button at all (not just disabled) — this was the other blocking defect
   from review. Confirm by opening its drawer via the row menu or
   whatever door Cast still has for sync.
6. **The Mac's own row.** Untouched: no equalizer button, chip behaves as
   before (trim, not latency).
7. **Equalizer button**, left of mute, on AirPlay and Bluetooth rows only.
   Give a device a non-flat EQ curve (Groups window → device detail →
   Equalizer) and confirm the button's outline turns magenta on the
   popover row, and reverts when you flatten the curve again. Click the
   button → opens that device's equalizer in the Groups window (same
   destination the row's context-menu "Equalizer…" item already goes to).
8. **Window width.** Popover and Groups window should both be visibly
   wider than before (653 pt vs. the old 623). Check nothing clips at the
   new trailing edge, and that the "Source"/"Offset" column headers still
   line up over their columns.
9. **Light appearance.** Nobody has looked at this in light mode yet —
   the mock was dark-only and this is explicitly listed as "not mocked."
   Toggle System Settings → Appearance and re-check items 1-3 and 7,
   especially the note's inset seat (it changed rim token mid-merge, see
   Traps) and the magenta EQ outline's contrast.
10. **Analytics**, if you have PostHog access: `bt_sync:wizard_started`
    should carry a `door` property (`chip` / `note` / `drawer` / `menu`)
    on every launch path. `bt_sync:note_hidden` should fire on the ✕.
    `eq:opened` should carry `door` (`row_button` / `menu` /
    `main_out_menu`). The old `bt_sync:method_chosen` event is retired —
    confirm nothing still emits it.

## Traps / things that bit me this session

- **`.env` doesn't exist in a fresh worktree.** `make-app.sh` fails with
  `POSTHOG_PROJECT_TOKEN is required` until you `cp "<main checkout>/.env" .`
  into the worktree. It's gitignored — don't try to commit it, don't
  worry about it leaking.
- **The live-test slot's `acquire` can silently not stick** — I hit
  `refusing to build … you do not hold the live-test slot` immediately
  after a successful-looking `acquire`. Re-running `acquire` a second
  time fixed it. If `make-app.sh` refuses, don't assume you're locked
  out — just re-acquire and retry once before escalating.
- **This branch was merged with `origin/main` mid-session** (Alec asked
  for it explicitly, along with pulling `audiout-shared`'s main — that
  one was already up to date, no-op). Main had landed ~90 commits since
  this branch forked, including a design-system change: inset-container
  seats (`well` fill) now use a new `Tokens.Color.containerEdge` rim
  token instead of `hairline` for their *outer* edge. The merge produced
  exactly one real conflict — main had edited the old
  `BTAlignmentPromptView.swift`'s rim token while this branch deletes
  that file (renamed to `BTAlignmentNoteView.swift`) — resolved by
  carrying the `containerEdge` change into the new note view. **If you
  find any other inset seat in files this branch touched that still says
  `hairline` on its outer rim, that's likely the same unlanded rule —
  check `git log --all -- '**/*.swift' -S containerEdge` for the
  originating commit before assuming it's a bug.**
- **Full test suite is flaky under load, unrelated to this branch's
  code.** Two consecutive full runs (3,451 then 3,457 tests) each showed
  a handful of failures, each time in a *different* set of tests
  (`NativeBackendTests`, `CompanionEndToEndTests` — capture lifecycle and
  companion-socket timing tests, nothing this branch touches). Every one
  of them passed clean when re-run in isolation with
  `bash scripts/run-tests.sh --filter <Suite>`. If you see a full-suite
  failure, isolate it before treating it as a regression — and don't
  change `audiout.remoteSlots` (the mule's concurrency cap) while a suite
  is mid-run; doing that made round two of the full suite noisier than
  round one.
- **`audiout.remoteSlots` is currently 4** (Alec's explicit instruction
  this session — was 3, briefly 6, corrected to 4). It's shared git
  config across every worktree of this repo, not a per-worktree setting.

## What's still owed

- **Everything above** — nobody has touched the running build yet.
- **Main Audio's row has no equalizer button in this pass** — explicitly
  out of scope, noted as a follow-up in decision 9 of the work order.
- **Light appearance**, as above.
- **A live merge/reconnect edge case nobody's tried**: two never-aligned
  Bluetooth speakers joining the same mix at once should produce two
  separate notes (no queue, unlike the old card) — worth a real check if
  you have two speakers.
- **Nothing is committed.** The working tree is dirty on purpose — nine
  small fixes plus the two blocking ones from an independent review are
  folded into the same uncommitted diff as the original work order, on
  top of the merged main. Committing is Alec's call, not something to do
  unprompted (per this repo's standing rule — see
  `[[feedback-no-merge-without-explicit-go-ahead]]` in memory).

## When you're done

- `bash scripts/livetest.sh done` to release the slot if you hold it —
  don't sit on it.
- Report findings back to Alec directly; if something's broken, fix it in
  this same worktree (don't spin up a parallel one — see
  `[[parallel-agents-shared-worktree-collide]]`) and re-verify through
  `scripts/build.sh` / `scripts/run-tests.sh`, never a bare `swift`
  command.
- If Alec gives the go-ahead to merge, that's a `git merge` into `main`
  (this repo is merge-only on `main`, Guard 1) — not something to do
  without being asked either.
