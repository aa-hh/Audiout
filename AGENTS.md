# AirPlay Controller

## Purpose

A native AppKit macOS app for sending system audio to multiple AirPlay 2
speakers at once with per-device volume, mute/solo, saved groups, per-app
routing, and perfect multi-room sync — capabilities Apple's own Music/TV apps
have but the rest of macOS lacks. The product requirements, phased build
plan, and UI design are fully specified in [SPEC.md](SPEC.md); this file only
orients an agent to *where things live in the repo*, not what the product
should do.

Status (see SPEC.md §5 "Phased build plan" and PLAN-PHASE-2.md for detail):
Phase 0 (feasibility) and Phase 1 (the AppKit app: menu-bar popover, mixer
window, groups, per-app routing UI) are shipped. Phase 2 — a native,
Swift-wrapped AirPlay 2 sender engine that removes the OwnTone runtime
dependency — passed its gated live-hardware test 2026-07-17: the engine
audibly played a real AirPlay 2 speaker (see
[AirPlayEngine/AGENTS.md](AirPlayEngine/AGENTS.md) and
`AirPlayEngine/docs/first-light-report.md`). The app today still runs on
`OwnToneBackend` (a working OwnTone-backed implementation); wiring the app to
the new engine (`NativeBackend`) is the next major piece of work, and several
folders under `dev/notes/` contain pre-implementation research for it and
other upcoming phases — read the relevant one before starting related work
(see "Research briefs" below).

Keep this file up to date when: a new top-level folder is added, SPEC.md's
phase status materially changes, or the dev tooling gains a new layer.

## Folder Map

- [AirPlayControllerCore/](AirPlayControllerCore/AGENTS.md) — the Swift
  package: `Device`/`OutputBackend` model seam, `MockBackend` (primary
  offline dev target) and `OwnToneBackend` (the real, currently-shipping
  backend), plus the AppKit UI — menu-bar popover (System / Selected Devices
  / Applications-routing cards), the full mixer window, and group
  management. This is the app.
- [AirPlayEngine/](AirPlayEngine/AGENTS.md) — a standalone SwiftPM package:
  OwnTone's AirPlay 2 sender vendored + shimmed into an engine this project
  owns, wrapped in a neutral Swift API. Not yet wired into the app (that's
  `OutputBackend`'s `NativeBackend` implementation, still to be written) —
  today it's proven out via a gated CLI (`engine-probe`) and passed its first
  real-hardware test 2026-07-17.
- [dev/](dev/AGENTS.md) — offline dev tooling (mock speakers, a Core Audio
  capture CLI) **and** `dev/notes/`, this project's home for
  pre-implementation research briefs and phase-completion write-ups. See
  that folder's AGENTS.md for the current brief index.
- [SPEC.md](SPEC.md) — the product spec: problem statement, confirmed
  requirements, feature list (v1/v2/later), technical architecture, phased
  build plan, and the full UI design. Treat this as the source of truth for
  *what* to build; code comments across the repo cite specific sections
  (e.g. "SPEC.md §9") for the reasoning behind a decision.

## Notable Patterns

- **The core package knows nothing about AppKit's dependents.**
  `AirPlayControllerCore` (the Swift package) hosts both the pure logic and
  the AppKit UI targets, but the UI targets depend on the model/backend
  targets — never the reverse.
- **`AirPlayEngine` is a separate package on purpose** (not a target inside
  `AirPlayControllerCore`) — it vendors GPL/MIT/BSD source under
  per-license-labeled subdirectories, and that licensing boundary is cleaner
  as a standalone package. See its own AGENTS.md before touching it; the
  vendored sender code should almost never be edited (see that file's
  Notable Patterns).
- **Research briefs live in `dev/notes/`, not in this repo's memory/chat
  history.** Before starting a non-trivial phase of work (NativeBackend,
  per-app audio routing, synced local output, the PTP helper's production
  install path, auto-reconnect/EQ), check `dev/notes/` for an existing brief
  — several were written 2026-07-17 specifically to de-risk the next phases
  before implementation starts.

## `main` is MERGE-ONLY — author in your own worktree (HARD RULE)

**Never run `git commit` while standing on `main`.** Everything — code, docs,
notes, one-line fixes — is authored and committed in YOUR OWN worktree and
reaches `main` only as a **merge**. `main` receives merges; it never receives an
original commit. Guard 1 in `.githooks/pre-commit` enforces precisely this line:
merges pass untouched, a bare `git commit` on `main` is refused.

**The consequence that makes this non-negotiable: an `AGENTS.md` change
describing code then CANNOT reach `main` ahead of that code.** They sit on the
same branch, so they land in the same merge, and become true on `main` at the
same instant. That guarantee is free — it falls out of merge-only, rather than
depending on anyone remembering to be careful. Other agents read `main`'s
AGENTS.md as their map of this repo: a doc describing code `main` does not have
doesn't merely fail to help them, it sends them hunting for symbols that do not
exist, and they will not think to doubt it. Docs ahead of code are worse than no
docs.

**How to work (Alec, 2026-07-17):**
1. **Do not work in the `main` checkout at all.** Use a worktree. This is the
   root fix, not an aesthetic preference — see the incident below. Note that
   merely EDITING `main` starts the accident even if you never commit: your loose
   edits become the next agent's blocked merge, and it will commit them for you.
2. Author code and its `AGENTS.md` together in your worktree.
3. Commit both there, then merge the branch into `main` as ONE unit.
4. Never commit a docs-only "I'll land the code next" change. There is no "next".
5. If the code is dropped, deferred, or stashed, the doc describing it does not
   land either. Landing half is what creates an orphan.
6. **If you find uncommitted edits in the `main` checkout that are in your way:
   STOP AND ASK. Do not commit them to unblock yourself, and never
   `git reset --hard` / `checkout --` / `stash` them away.** They belong to
   another session, they are unrecoverable once discarded (unstaged work was
   never hashed), and committing them is exactly what caused the incident below.

**This is not hypothetical — it is the most expensive failure this repo has had,
and NOBODY DECIDED TO DO IT.** Understanding the actual sequence is the point:
- Someone edited AGENTS.md **directly in the `main` checkout**, describing a
  feature whose code lived in a different session's worktree. Those edits then
  sat there, loose, for hours.
- A completely unrelated agent (`musing-wescoff`, in its own worktree, doing its
  own job correctly) went to merge its branch and **couldn't — the loose edits in
  `main` were in the way.** So it did the tidy-looking thing: it committed the
  mess it found, then merged. That commit is `f1f3e94` (5 AGENTS.md, **zero**
  .swift). It had no idea the matching code was in a third session's worktree,
  twelve minutes from being stashed and forgotten.
- Result: `main` documented `appRouteTargets` / `redirectOutputIDs()` /
  `reapplyRouting()` / `routedAppNames(for:)` — a feature present in zero .swift
  files — and every agent that read `main` believed it. Recovering it took a full
  session (landed 2026-07-17, `432aa7d`; the code had survived only as a stash
  under tag `recovered-stash`).
- **The lesson: loose edits in a shared checkout are a trap for the next agent
  through, and the trap is that committing them looks like helpfulness.** The
  half-save was the SHAPE of the accident, not anyone's intent. That is why rule
  1 is "don't work in the main checkout" and why Guard 1 below blocks the commit
  outright rather than warning — a warning is exactly what an agent trying to
  unblock itself will read and reason past.
- `d033466` shows the OTHER half of the rule: it shipped code and docs together,
  but the doc named three methods — setAppRoute, setAppVolume, removeAppRoute
  (deliberately un-backticked here: none has ever existed in any .swift file, and
  this sentence should not read as a reference to real API) — while the code in
  that very commit declared `addRoute` / `setDestination` / `setVolume` /
  `removeRoute`. Same-commit is necessary but NOT sufficient — **re-read the code
  you just wrote and confirm every symbol you name in a doc actually exists.**
  Nobody did, for months, and agents kept propagating the fiction.

Corollary for readers: docs orient, code decides. If an `AGENTS.md` names a symbol
you cannot find in source, believe the source and fix the doc — do not assume you
are looking in the wrong place. `git grep '<symbol>' -- '*.swift'` settles it.

**Enforced by two pre-commit guards** (`.githooks/`, enable once per clone with
`git config core.hooksPath .githooks`; override once with `git commit --no-verify`):

- **Guard 1 — BLOCKS a direct `git commit` on `main`.** Merging a branch into
  `main` is deliberately unaffected (verified: a clean merge never invokes
  pre-commit, and a conflict-resolution merge commit is allowed via `MERGE_HEAD`).
  Only standing in the main checkout and committing is refused. Costs nothing in a
  worktree — it never fires there.
- **Guard 2 — WARNS (never blocks)** when an AGENTS.md change names a symbol that
  exists nowhere in the commit's own source. This catches what Guard 1 can't: a
  name wrong from birth (d033466) or a doc left stale after code was deleted. It
  compares against **the commit you are creating** — deliberately NOT against
  `main` (which would falsely accuse every worktree whose work hasn't merged yet;
  truth in an unmerged worktree is TRUE) and NOT against the working tree (which
  would have let f1f3e94 through, since its code was unstaged at commit time).
  Backtested over this repo's whole AGENTS.md history: fires on f1f3e94 and
  d033466, quiet on every honest docs+code commit. ~0.08s. Known false positives:
  an AppKit type named as design guidance but used nowhere (hudWindow,
  NSLevelIndicator) — ignore those.

## UI / Design Conventions (all targets)

This app should look and feel like a native macOS citizen, not a cross-platform
port. When building or reviewing ANY UI code in `AirPlayControllerPopoverUI`,
`AirPlayControllerWindowUI`, `AirPlayControllerSharedUI`, or `AirPlayControllerApp`:

- **Prefer stock AppKit components over custom-drawn ones.** Reach for
  `NSSwitch`, `NSSlider`, `NSPopUpButton`, `NSStackView`, `NSTextField`,
  `NSButton` (bezel styles), `NSVisualEffectView`, `NSSplitViewController`,
  toolbar items, etc. before writing a custom `NSView` subclass with manual
  `draw(_:)`. Custom drawing is justified only when no system control expresses
  the design (e.g. `StatusDotView`'s on-icon badge, `CardView`'s Control-Center
  chrome) — and even then, compose system chrome (`NSVisualEffectView`,
  system colors/materials) rather than hand-rolling colors.
- **Use SF Symbols for every glyph.** Any icon/glyph should be
  `NSImage(systemSymbolName:accessibilityDescription:)`, template-rendered so it
  tracks appearance/tint automatically (see `StatusItemController`'s
  `speaker.wave.3.fill` with `variableValue`). Don't ship custom icon assets for
  something SF Symbols already covers.
- **Use system colors and materials, not hardcoded hex/RGB.** `.labelColor`,
  `.secondaryLabelColor`, `.controlAccentColor`, `.windowBackgroundColor`,
  semantic materials (`.sidebar`, `.headerView`, `.hudWindow`) — so Dark Mode,
  accent color, and accessibility contrast settings all work for free.
- **Respect system-level user settings.** Reduce Motion (see
  `StatusDotView`'s static fallback), Increase Contrast, Reduce Transparency,
  and Dynamic Type-equivalent text scaling should all be checked, not assumed
  off.
- **When in doubt, match Control Center / System Settings**, since this app's
  design brief (SPEC.md §9) is explicitly modeled on them — not a bespoke
  design language.
- Deviating from any of the above (a genuinely custom control, a one-off
  color) is fine when the system has no equivalent, but note *why* in the
  nearest AGENTS.md so the next agent doesn't "fix" it back to a system control
  that doesn't actually fit.
