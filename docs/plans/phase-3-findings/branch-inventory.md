# Branch inventory — release hygiene audit (Task A9)

Every `claude/*` branch, verified against `main` (tip `bcd6086`), with a
plain-language merge-or-drop call for each. Goal: don't spend Phase-3 polish
effort on a surface that's about to change out from under it.

## Method

- Enumerated every local `claude/*` branch (51 total, excluding this task's
  own branch) with `git for-each-ref`.
- For each, `git rev-list --count main..<branch>` — 44 came back `0` (the
  branch tip is already an ancestor of `main`; some of those are stale refs
  whose real work now lives only in a worktree's uncommitted files, see "At-risk
  work found in passing" below). Only the 7 with a nonzero count are examined
  below in depth, per the brief.
- For each of the 7: `git diff --stat main...<branch>` (merge-base diff),
  `git log --reverse --oneline main..<branch>` for commit subjects, then a
  targeted `git grep` / `git show` / `git log --grep` pass against `main` to
  check whether the same functionality already shipped another way (by
  content, not just by branch ancestry — several of these branches predate one
  or two renames, so a literal merge would fail even where the *feature* is
  long since on `main`).
- Read the root `AGENTS.md`, `AudioutCore/AGENTS.md` and
  `AudioutCore/Sources/*/AGENTS.md` first, per the coordinator's instruction,
  before touching source — this surfaced the stale `speaker-input-responsiveness`
  reference below directly (root cause: `AudioutCore/AGENTS.md`'s
  `RemoteControlPriming` row cites that branch as "not yet merged," so it was
  checked first rather than trusted).
- All commands were read-only (`log`/`diff`/`show`/`branch`/`grep`/`merge-base`/
  `rev-list`/`status`/`fsck`/`reflog`/`worktree list`, plus one headless `swift
  build`). No checkout, merge, commit, or working-tree edit was made in this or
  any other worktree.

## Branch table

| Branch | Commits ahead | True diff size (main...branch) | What it is | Recommendation |
|---|---|---|---|---|
| `claude/onboarding-permission-priming` | 17 | 156 files, +3285/−400 | First-run permission-priming onboarding flow (17 commits of real iteration: redesign, third permission row, fixed-width columns, live status, ControlPanel-shell adopt+revert, audio-tone add+drop, menu-bar recovery), tangled with one in-branch rename commit. | **DROP** — see Trap 2 below: already fully on `main`. |
| `claude/focused-nightingale-42a9fd` | 4 | 3707 files, +130093/−54 | "Playback meters" — VU meter UI + real per-app/per-device/main-out level sources. Huge diff is an artifact, not real scope. | **DROP** — see Trap 1 below: already fully on `main`. |
| `claude/light-dark-appearance-icon` | 2 | 3 files, +123/−3 | Adds a **middle fallback tier** to `make-app.sh`'s icon build: a classic light/dark `appiconset` (via `actool`, works on any Xcode ≥16) between the new Liquid Glass `.icon` path (Xcode 26+ only) and the plain single-image `.icns` last resort. Also fixes a real bug: the first attempt at this claimed to work "on any Xcode" but actually produced a silently non-functional (identical light/dark) icon below Xcode 16 — second commit adds a functional post-build check (render both appearances, hash-compare) instead of trusting `actool`'s exit code. | **MERGE-BEFORE-POLISH** (or cherry-pick both commits: `d75b351`, `ad167d5`). Upside: closes a real gap — `main`'s icon pipeline today only has "Liquid Glass" and "flat `.icns`," so any build machine on Xcode 16–25 currently ships a non-appearance-aware icon; this is the app icon on a paid release, worth getting right. Downside: touches the same `scripts/make-app.sh` and icon assets that icon/visual polish tasks will also touch — land it first so nobody's polish pass conflicts with or gets silently overwritten by this fallback-tier logic. |
| `claude/serene-elion-24763c` | 1 | 1 file, +1/−1 | Changes the popover header icon buttons' `bezelStyle` from `.accessoryBar` to `.smallSquare`. | **DROP.** A *later* commit already on `main` (`91cc028`, "Header buttons: borderless glyph style instead of solid-outline bezel") deliberately went the other way — explicitly moved *away* from `.smallSquare` ("a boxed, always-visible outline") *to* `.accessoryBar`, to match the borderless toolbar-glyph style used elsewhere in the popover. Applying this branch would silently undo a considered, already-shipped design decision. |
| `claude/device-audio-playback-connect-a3389b` | 1 | 3 files, +509/−6 | "Seed device volume from system output on connect" — fixes the −30 dB silent-connect bug (new AirPlay connections streamed inaudibly until the user touched the slider). | **DROP.** Byte-for-byte the same fix already shipped on `main`: current `AudioutCore/AGENTS.md` documents `connectVolumeSeed`, the `bufferReAdding` gate, and the `volumeInFlight`/`volumePending` serialization in the exact same language as this commit's own message. This branch predates even the `AirPlayControllerCore`→`Audiouted` rename (its paths are still `AirPlayControllerCore/`) — a historical duplicate, not new work. |
| `claude/brave-matsumoto-85c3aa` | 1 | 2 files, +17/−0 | Guards `CaptureCoordinator.spawnCapture()` against a stale, detached-Task respawn resurrecting a pipeline that has already reached a terminal `.failed`/`.stopping` state — fixes a real, reproducible test flake under CPU load. Small, self-contained, includes a strengthened test. | **PARK** (defer past release). Upside: cheap, well-tested, real bug fix. Downside: the file it touches, `CaptureCoordinator.swift`, backs `OwnToneBackend` — the app's own docs mark that backend "superseded" by the native backend that actually ships (`AIRPLAY_BACKEND=native`). Confirmed: `main`'s current `CaptureCoordinator.spawnCapture()` still lacks this guard, so the bug is real and live in-tree, but it's in a code path users of the shipping build don't exercise. Not worth a release-blocking merge; worth pulling in whenever that legacy backend is next touched (or removed as dead weight). |
| `claude/angry-bartik-f7c42f` | 1 | 4 files, +115/−0 | Adds a warn-only pre-commit script (`.githooks/agents-md-check.sh`, POSIX sh) that flags staged code changes whose owning `AGENTS.md` wasn't also staged, plus a matching Claude-Code `PreToolUse` hook and an `AGENTS.md` policy note. | **DROP.** `main` already has a materially stronger version of the same idea, built later and differently: `.githooks/pre-commit` today runs a **blocking** Guard 1 (refuses a bare `git commit` on `main`) plus a Python **Guard 2** (`.githooks/agents-md-symbol-check.py`) that verifies every symbol an `AGENTS.md` *names* actually exists in that commit's source — a stronger signal than "was the file staged." This branch's mechanism is superseded, not complementary. |

**Branch count ahead of main: 7** (of 51 `claude/*` branches checked; the other 44 are already fully contained in `main`'s history).

## The two traps untangled

### Trap 1 — `claude/focused-nightingale-42a9fd` ("playback meters")

**Verdict: fully superseded. DROP. Nothing left to cherry-pick.**

Evidence:
- Of the reported "4 commits," only 2 are real work: `5ed6c69` ("Playback
  meters: real per-app / per-device / main-out, source-level" — Stage 2) and
  `c378696` ("Playback-level meter: leading VU column across popover rows" —
  Stage 1, the original `LevelMeterView`). The other 2 (`4add5e9`, `be331c8`)
  are "Merge branch 'main' into claude/focused-nightingale-42a9fd" housekeeping
  commits.
- The reported 3707-file / 130k-line diff is **not real scope** — sampling it
  shows it's dominated by a `.build/` directory that was accidentally
  committed straight into this branch's history (compiled `.o` files,
  `.dSYM` bundles, `.swiftdeps`, link databases — build output, not source).
  The branch's tip tree also still contains a stale `AirPlayControllerCore/`
  directory alongside `AudioutedCore/` (one rename behind current
  `AudioutCore/`), confirming it's an old, never-cleaned-up branch.
- `main`'s own history has `1e59770` — "Merge claude/focused-nightingale-42a9fd:
  real playback meters (per-app/per-device/main-out)" — whose own message says
  it's "Content-merge of the playback-meter Stage 2 work... into the
  consolidated worktree. Recorded as a regular commit rather than a true git
  merge." Its file list shows `LevelMeterView.swift` landing as a **new
  218-line file** in that same commit — i.e. both Stage 1 (`c378696`'s
  `LevelMeterView`) and Stage 2 (`5ed6c69`'s real per-app/per-device sources)
  content reached `main` together, by hand, under new commit hashes. That's
  why `git rev-list` still shows the branch "ahead" — the commits themselves
  never became ancestors of `main` even though their content did.
- Confirmed independently on the code, not just the merge commit's claim:
  `main` has `AudioutCore/Sources/AudioutSharedUI/LevelMeterView.swift`,
  `LocalPlaybackEngine.onAppLevel`, and `docs/PROGRESS.md` documents "Playback
  meters — real per-app/per-device/main-out sources" as five completed tasks
  (T1–T4b, "verify pass" on each). `AudioutCore/AGENTS.md`'s own Rules
  section describes the exact three-source metering model (per-app
  `.appLevel`, per-device MAX-of-sources, Main Out = system mix, excluded apps
  never metered) that this branch was building toward.

### Trap 2 — `claude/onboarding-permission-priming` (~17 commits)

**Verdict: fully superseded. DROP. Nothing left to cherry-pick, individually or otherwise.**

The brief asked to separate real onboarding refinements from rename churn and
list the former individually. Investigation found a stronger answer: **there's
nothing left to list** — every commit's *content* is already on `main`, not
just the rename.

Evidence:
- `main`'s own history has `560eab4` — "Port onboarding/permission-priming
  flow from claude/onboarding-permission-priming" — whose message explains why
  it's a hand-port rather than a merge: "that branch's double rename history —
  `AirPlayControllerCore` → `Audiouted` → `Audiout` — ... made automatic
  merge machinery unreliable." It lists porting the entire
  `AudioutOnboardingUI` module (`OnboardingWindowController`/
  `OnboardingViewController`/`PermissionRowView`/`SystemSettingsOpener`),
  `SetupModel` + all three permission-priming probes (audio tone, local
  network, remote control/Accessibility — i.e. the "third permission row"),
  `AppSettings.hasCompletedSetup`, the first-run gate, Settings' "Run Setup
  Again..." button, and the `Info.plist` keys in `make-app.sh`. 769/769 tests
  green at merge time.
- Direct file-by-file diff (`git diff main:<path> branch-tip:<path>`) for
  every onboarding source file confirms this: `RemoteControlPrimer.swift`,
  `OnboardingViewController.swift`, `OnboardingWindowController.swift`, and
  `SystemSettingsOpener.swift` are **byte-identical** between `main` and the
  branch tip. `SetupModel.swift`, `AudioCapturePermissionProbe.swift`,
  `LocalNetworkPrimer.swift`, and `PermissionRowView.swift` differ by exactly
  **one line each** — and that line is purely cosmetic: the branch still says
  "the case the owner hit" / "the bug this exists to fix (owner, ..." in a code
  comment, where `main`'s later personal-name-scrub commit (`3b35d64`,
  already merged separately) changed those same comments to say "ahh" instead.
  `AppDelegate.swift` differs by more (146 lines), but that's `main` having
  grown *unrelated* functionality since (ControlPanel shell, per-app routing,
  etc.), not missing onboarding work.
- Net effect: the 17-commit branch's real, cumulative end-state (after all its
  internal iteration — redesign, third row, fixed-width columns, tone
  add/remove, shell adopt/revert, menu-bar recovery) was captured whole by the
  `560eab4` hand-port. The branch itself is now a historical artifact with
  zero unique, mergeable content.

### At-risk work found in passing (not one of the two named traps, flagged per the coordinator's "flag stale AGENTS.md claims" instruction)

`AudioutCore/AGENTS.md`'s `RemoteControlPriming` row says the Accessibility
permission was "primed AHEAD of the feature that needs it (speaker-side
transport controls simulating Mac media keys — **not yet merged, see
`claude/speaker-input-responsiveness-b8123f`**)." That branch reference is
**stale and misleading as written**: `claude/speaker-input-responsiveness-b8123f`
itself has **zero commits ahead of `main`** — its tip (`3b35d64`) is an old,
already-merged checkpoint with no speaker-input code in it at all (confirmed:
`git grep -l "makeRemoteEventStream\|airplayengine_remote_fire" main` and
`git grep --all` return nothing anywhere in reachable history).

The real feature — `DACPServer.swift`, `MediaKeyController.swift`,
`RemoteEventStreamTests.swift`, plus modified `AirPlayEngine.swift`/
`airplay_events.c`/`engine_bridge.c` and a `dev/notes/speaker-input-brief.md`
— exists, but only as **uncommitted working-tree changes** in a *separate*
worktree at `.claude/worktrees/nostalgic-nash-ea4a1e` (currently checked out
on that same branch name). That worktree's files still say `AudioutedCore`/
`AudioutedApp` in their paths — pre-dating the most recent rename — meaning
this work has been sitting uncommitted since at least that point.

This is exactly the loss pattern the root `AGENTS.md` calls "the repo's most
expensive failure" (the `f1f3e94` incident: real work surviving only as an
unhashed, droppable stash/working-tree state). Recommend: whoever owns that
worktree commits this work to a branch (even a throwaway one) before any
future worktree-cleanup pass touches `nostalgic-nash-ea4a1e` — it is not
currently protected by git in any way. Flagging for the coordinator/owner
rather than acting — I did not touch that worktree beyond a read-only
`git status`.

## Excluded-workstream integration checkpoints

Per the brief, these two are being built by other agents elsewhere; their
*content* was not audited — only touched file paths (via read-only `git
status` in their worktrees) to scope what polish should avoid/anticipate.

### (a) AP1/RAOP sender port — worktree `airplay-one-support-2abab0`

- **Touches:** `AudioutCore/Sources/AudioutCore/NativeDiscovery.swift`,
  `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift`,
  `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift` (plus a
  deleted test file, `DeviceRowUnsupportedTests.swift` — implying older AirPlay
  1 devices are currently shown as an explicit "unsupported" state in the
  popover, and this workstream removes that restriction), and a new
  `AirPlayEngine/Sources/CAirPlayEngine/sender/raop.c`.
- **What "done" must include for release:** the popover's device row must
  stop showing an "unsupported device" state for AP1 speakers once real RAOP
  sending works end-to-end (not just compiles) — i.e. the deleted test file
  should be replaced by passing coverage of the *new* behavior, not just
  removed; a live-hardware confirm against a real AirPlay 1 speaker (this
  codebase's pattern for every backend change, per `dev/notes/`).
- **Where polish should avoid/anticipate it:** any visual-polish pass on
  `DeviceRowView` (icons, badges, unsupported-state styling) should check
  with this workstream first — polishing the soon-to-be-deleted "unsupported"
  badge is wasted work, and finalizing row layout before AP1 support lands
  risks a second layout pass once the new device-capability states exist.
- **Integration checkpoint for the Phase-3 plan:** *before* any popover
  device-row visual polish starts, confirm whether AP1 support has landed or
  been deferred past this release — the row's supported/unsupported states are
  a shared surface between the two workstreams.

### (b) Privileged PTP helper (`SMAppService` daemon) — worktree `ptp-helper-daemon-833a53`

- **Touches:** `AirPlayEngine/Package.swift`, `AirPlayEngine.swift`, the
  `ptpd.c` C shim, `AudioutCore/Sources/AudioutCore/NativeBackend.swift`,
  and — importantly for release polish — **`scripts/make-app.sh`**, the same
  build script `claude/light-dark-appearance-icon` (above) also modifies. New
  `AirPlayEngine/Sources/ptp-helper/` target plus a `scripts/ptp-helper.plist`.
- **What "done" must include for release**, per
  `dev/notes/p2b-helper-productionization-brief.md` (already read; ranked
  risks in that doc, not re-derived here): (1) a real Developer ID Application
  certificate — the brief is explicit that **ad-hoc signing does not work for
  `SMAppService` daemons at all**, which is also this app's current release
  blocker per existing project memory; (2) the Xcode app-target bundle
  plumbing (Copy Files phases, Code-Sign-on-Copy, `Label` matching the plist
  filename) — not yet possible without that cert; (3) first-run checks that
  the AirPlay Receiver system setting is off and the app is running from
  `/Applications` (translocation risk); (4) firewall auto-allow-by-signing
  verified, with `socketfilterfw` as fallback only; (5) the uninstall path
  (`unregister()` + a documented "stale Login Items entry" caveat).
- **Where polish should avoid/anticipate it:** don't finalize
  `scripts/make-app.sh` icon/signing polish in isolation from this
  workstream — it's touching the same script for a different reason (daemon
  bundling vs. icon fallback tiers), so both need to land before a final pass
  on that file, or one will silently clobber the other's untested edits.
- **Integration checkpoint for the Phase-3 plan:** schedule the Developer ID
  certificate decision (an explicit open question in the brief, owner's call,
  ~$99/yr) **before** scheduling any release-signing or notarization polish
  task — multiple workstreams (this daemon, TCC/Accessibility grants per
  existing project memory, and general App Store/notarization readiness) are
  all blocked on the same certificate.

## Sequencing recommendation

**Land `claude/light-dark-appearance-icon` first, before any icon/build-script
polish.** It's the only one of the 7 unmerged branches with real, unique,
low-risk value — everything else on the list is either already on `main`
under a different commit hash (drop) or was a deliberate design decision that
got reversed (drop). Landing it first avoids a Phase-3 polish task
re-discovering the same Xcode-version icon gap from scratch, and avoids a
polish edit to `scripts/make-app.sh` conflicting with this branch's still-open
fallback-tier logic.

**Do not schedule any Phase-3 polish on popover device rows or on
`scripts/make-app.sh` until checking in with the AP1/raop and PTP-helper
workstreams.** Both are actively editing files a "polish" pass would
naturally touch (device-row unsupported-state styling; the icon/signing build
script). This isn't a merge-order dependency — those two workstreams are
explicitly out of scope for this audit and may land well after Phase 3 starts
— but it is a *scheduling* one: polish that touches those specific files
should be sequenced last, or explicitly re-checked once those workstreams
land, rather than being treated as "safe to do now."

**Everything else in this inventory needs no sequencing at all** — the 5
DROP/PARK branches require no action before polish starts; they're either
noise (already-shipped duplicates, a reversed design experiment) or
legitimately deferred (the OwnToneBackend respawn-guard fix, which touches no
code path the shipping app exercises).

**One item is outside this audit's branch scope but worth the owner's
attention before any worktree cleanup:** the speaker-input-responsiveness
feature (media-key/DACP remote-control support) exists only as **uncommitted**
changes in worktree `.claude/worktrees/nostalgic-nash-ea4a1e` — it is not
protected by any branch, commit, or the inventory above, and the repo's own
`AGENTS.md` documents this exact failure mode (`f1f3e94`) as the costliest
mistake in the project's history. Recommend committing it (even to a
throwaway branch) before it can be lost the same way.
