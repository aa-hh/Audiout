# Phase 3 — Polish: Execution Report

**Branch:** `claude/dev-plan-progress-assessment-88f195` (NOT merged to main — the owner's call)
**Status at writing:** all functional work done; 868 tests / 0 failures; Developer-ID-signed build produced.

This is the consolidated record of the Phase 3 polish effort: the pre-release
pass to take Audiout from "works for me" to "a stranger would pay for it."
It has two halves — a discovery/audit phase and a fix-execution phase.

---

## 1. Discovery (how we found the work)

Ten independent headless audits fanned out over the codebase (window mechanics,
cold-user UX, crash/hang surface, visual consistency, copy, accessibility,
performance, branch hygiene, payments research, commercial-wrapper gap
analysis), each writing an evidence-backed findings file in this directory.
Then the owner drove a live walkthrough of the running app (`gated-ux-walkthrough.md`)
which **confirmed, refined, or refuted** the headless findings against real
behavior and surfaced ~24 issues no static audit caught.

Key lesson from the walkthrough: several "green suite" features were actually
**dead in the running app** — the audits and the live session saw different
slices, and both were needed.

Full findings: the `*.md` files in this directory. Business/commercial research:
`payments-research.md`, `commercial-wrapper.md`. Design-judgment items got
written proposals instead of code: `proposals/`.

---

## 2. Fixes shipped (this branch)

Every item below is committed and headless-verified unless marked otherwise.

### Correctness / "dead feature" bugs
- **Dead connection-diagnosis panel** — the "Couldn't connect / Try again / Copy
  details" panel never attached to the view tree (wrong hierarchy level); now
  renders. Added a test that walks the real view tree (the gap that let it ship).
- **Groups window forgot its position** — `center()` overrode the restored frame
  every launch; hidden from the live test because the window is reused per-process.
  Fixed via `setFrameUsingName` + explicit re-apply.
- **Crash guard** — wrapped the 5 unguarded AVFoundation calls in
  `LocalPlaybackEngine` in the existing ObjC-exception shim (output-device change
  mid-playback could hard-crash). *Live crash-repro deferred to signed build.*
- **Header-click misroute** + **group activation** — fixed on `main` by another
  session (dropdown handler expected the wrong control type); verified, not
  duplicated here.

### UX / flows
- **Onboarding "Done" now confirms** when required permissions are ungranted
  (was: silently completed with nothing granted).
- **Onboarding tone** no longer replays on app refocus — only on the explicit
  Allow tap.
- **Right-click Quit menu + ⌘Q** — a Dock-less app had no discoverable quit and
  no keyboard shortcut; added a status-item context menu (Settings/Groups/Quit)
  and a minimal app main menu for ⌘Q / ⌘,. *Interactive behavior needs signed-build check.*
- **Config windows follow the active Space** (`.moveToActiveSpace` +
  `.fullScreenAuxiliary`) instead of yanking you to another Space / out of a
  fullscreen app.
- **Buried-window recovery** — shipped via the control-panel shell (below).

### Control-panel shell (now the default chrome)
- Made the floating-panel window shell launch-ready: **visible close button**,
  status-item toggle-close, Escape via `cancelOperation`, and a **dark-mode
  half-render fix** (content pane was stuck light). Real test coverage added.
- Defaulted **on** in the shipped build (via `LSEnvironment`), so Groups and
  Settings both use it and the "buried window with no way back" bug is gone.

### Accessibility
- Icon picker made keyboard/VoiceOver operable; root-caused and fixed the
  window-wide "Tab does nothing" gap (no key-view loop was ever set up).
- Four VoiceOver label fixes (theme selection, icon names, group-row activation,
  app-row routing/status).

### Copy & content
- Settings wording ("Run Setup Again…" → "Check Permissions…"; the truncated
  wake-restore label; jargon → plain language).
- Onboarding "Wi-Fi" orphan-wrap fixed; real app icon in the welcome header
  (*headless snapshot shows a placeholder — real icon appears only in the bundled
  app*).
- **About/Credits panel** built (Settings › General): version, GPL notice,
  three-license attribution from `NOTICE`, support link. **TODO placeholders for
  the owner: source-code URL + support contact.**

### Release readiness
- **RELEASE-CONFIG** (`scripts/make-app.sh`): real **Developer-ID signing**
  (auto-detected identity, hardened runtime, timestamp — verified non-interactive),
  real/bumpable version, **min-OS raised 13.0 → 14.2**, **double-click defaults to
  the native backend** (was mock = fake speakers!), control-panel shell on. Dev
  overrides (`AIRPLAY_BACKEND=mock`) preserved.
- **PERF-CODEC**: minimal audio-only ffmpeg, statically linked, dropping **~30 MB**
  of unused video-codec code (bundle ~38-40 MB → ~9-11 MB). Bit-identical ALAC
  (same encoder source). Safe fallback to full ffmpeg when the minimal build is
  absent. Wired into `make-app.sh`'s bundling path (idempotent). *Live audio
  verify deferred to signed build.*
- **CONNECT-VOLUME**: connecting a speaker now seeds a safe default volume
  (Settings › Audio, default 35 %, floor 5 % to avoid the −30 dB silent-connect
  trap) instead of inheriting the Mac's possibly-loud level. *Live loudness verify
  deferred to signed build.*
- **HOUSEKEEPING**: deterministic snapshots (pinned 2× scale across all 4
  generators), stale doc/branch references corrected, signing-doc line updated.

### Reconciled (contradicted findings, resolved before "fixing" the wrong thing)
- **VU meter "sliver at rest"** — REFUTED. The green mark was an artifact of the
  offscreen snapshot tool (proven by dumping the meter's actual state at capture
  time); no real bug. Finding retired.
- **Window position memory** — the audit was right, the live test was misleading
  (window reuse). Fixed.

---

## 3. Verified now vs. needs the signed-build session

**Headless-verified:** everything above that isn't marked otherwise — 868 unit
tests, window-harness 48/48, snapshot generators, targeted feature tests.

**Needs the Developer-ID signed build (`build/Audiout.app`, now available):**
- crash guard (toggle output device during playback)
- onboarding permission flows + real TCC grant behavior
- right-click Quit menu + ⌘Q interactive behavior
- real app icon rendering
- native-audio default on double-click
- connect-volume perceived loudness
- codec-trimmed bundle audio + size

These fold into ONE user-present signed-build session (single-instance on the PTP
ports — coordinate with other live sessions).

---

## 4. Handed off (deliberately not done here)

- **Design/UX polish → the "Warm Signal" redesign**: dark-mode Groups styling,
  window copy, mute-button feedback/color, empty-network state, popover copy, and
  the device-row accessibility cue + app-picker polish. Not worth polishing
  surfaces about to be redesigned.
- **Other sessions own:** the app-icon branch (incl. reconciling its
  onboarding-icon change with ours), AirPlay-1/RAOP (merged), the PTP-helper
  daemon (merged), the group-activation fix (merged).
- **Deferred functional:** real per-cause connection diagnosis (NATIVE-DIAG) was
  scoped but not built this round — it needs live hardware and is a larger piece.

---

## 5. Branch state & how to use it

**Merge reality (multi-session, tangled — read carefully):** the *earlier* half
of Phase 3 (diagnosis panel, crash guard, About panel, control-panel shell,
accessibility, quit menu, Spaces, onboarding/copy fixes, etc.) is **already on
`main`** — it reached main indirectly when the icon session cross-merged this
branch into theirs and up to main. What is NOT yet on main is the **recent
functional batch**, unique to this branch:

- `RELEASE-CONFIG` (Developer-ID signing + native default + min-OS)
- `CONNECT-VOLUME` (safe connect volume)
- `HOUSEKEEPING` (snapshot determinism etc.)
- `PERF-CODEC` (minimal ffmpeg)
- the `make-app.sh` minimal-ffmpeg wiring
- this report

This branch is also **~8 commits behind main** (the icon work + other session
merges it doesn't yet have). So landing the remaining 6 is a small, deliberate
step (merge main in here then land, or cherry-pick the 6 onto main) — the owner's
call, and worth coordinating given how many sessions have been cross-merging.

- Build/test: `cd AudioutCore && swift build && swift test` (868 tests).
- Signed build: `bash scripts/make-app.sh` (auto Dev-ID signs; add
  `AUDIOUT_BUNDLE_DYLIBS=1` for the self-contained, codec-trimmed bundle — first
  such build compiles the minimal ffmpeg once, then caches it).
- Notarization is deliberately deferred (signing only).

---

## 6. Open decisions / owed

1. **Merge to main** — when the owner's ready (coordinate with the icon session's
   overlapping onboarding-icon change).
2. **About panel placeholders** — real source-code URL + support contact.
3. **Repo visibility** — currently private; GPL obliges source availability
   before charging money (make public or a written-offer mechanism). See
   `commercial-wrapper.md`.
4. **Payment provider** — recommendation is Lemon Squeezy, one-time $39-49 with a
   license key; not yet decided. See `payments-research.md`.
5. **Signed-build verification session** — the items in §3.
6. **NATIVE-DIAG** — build real connection-failure detection when ready (needs
   hardware).

---

*Process note: this effort ran as orchestrated sub-agents. Two collision
incidents (a shared-worktree edit-sweep; an agent committing to the wrong
checkout) were caught and recovered without loss; the lesson — serialize or
isolate, and always verify the combined tree — is recorded in memory. A third
near-miss (an isolated worktree that had silently absorbed another session's
branch) was caught at merge and unwound to a clean cherry-pick.*
