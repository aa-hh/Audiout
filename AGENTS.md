# AirPlay Controller

## Purpose

A macOS app (native AppKit) for sending system audio to multiple AirPlay 2
speakers at once with per-device volume, mute/solo, saved groups, per-app
routing, and perfect multi-room sync — capabilities Apple's own Music/TV apps
have but the rest of macOS lacks. The product requirements, phased build plan,
and UI design are fully specified in [SPEC.md](SPEC.md); this file only orients
an agent to *where things live in the repo*, not what the product should do.

Status (2026-07-17): Phase 0 (feasibility) and Phase 1 (the AppKit app + mock
backend + popover/mixer UI + per-app routing) are both complete. Phase 2
extracted OwnTone's AirPlay 2 sender into a standalone, neutrally-named engine
package this project owns (`AirPlayEngine/`), which passed its gated
live-hardware test 2026-07-17 — it audibly played a real AirPlay 2 speaker (see
[AirPlayEngine/AGENTS.md](AirPlayEngine/AGENTS.md) and
`AirPlayEngine/docs/first-light-report.md`). Phase 2b then built the real,
in-process native backend on top of that engine:
`NativeBackend`/`NativeDiscovery`/`NativeCaptureCoordinator` in
`AirPlayControllerCore`, selectable via `AIRPLAY_BACKEND=native`. **The app
now has three interchangeable backends** — `mock` (fabricated fleet, default,
primary dev target), `owntone` (a COMPLETE HTTP-polling backend against an
external OwnTone server — **superseded** by `native` and not carried forward;
it is NOT a stub, and no unimplemented() stub call — deliberately un-backticked,
since no such symbol exists in any .swift file — survives anywhere in it,
whatever older docs claimed), and `native` (real AirPlay 2 sender, in-process,
no external server — the shipping path). AP1-only receivers are discovered and shown in the UI
(dimmed, "coming soon" explanation) but not yet driven — the AirPlay 1 sender is
deferred to the next iteration (PLAN-PHASE-2B.md D6). One gated
live-verification session with real hardware remains before `native` is
considered production-ready — see `dev/notes/p2b-nativebackend-runbook.md`.

Several folders under `dev/notes/` contain pre-implementation research briefs
for upcoming phases — read the relevant one before starting related work (see
"Research briefs" below).

Keep this file up to date when: a new top-level folder is added, a backend is
added/removed/promoted (stub → real → superseded), SPEC.md's phase status
materially changes, or the dev tooling gains a new layer.

## Folder Map

- [AirPlayControllerCore/](AirPlayControllerCore/AGENTS.md) — the Swift
  package: the `Device` model, the `OutputBackend` protocol seam, the
  `MockBackend`/`OwnToneBackend`/`NativeBackend` implementations, per-app
  routing (`AppRoutingController`), the AppKit UI targets
  (`AirPlayControllerSharedUI`, `AirPlayControllerPopoverUI`,
  `AirPlayControllerWindowUI`, `AirPlayControllerSettingsUI`) — menu-bar
  popover (System / Selected Devices / Applications-routing cards), the full
  mixer window, group management, and the Settings window — and the shipping
  app target (`AirPlayControllerApp`). Depends on `AirPlayEngine` (local path
  dependency, `Package.swift`) for the `native` backend. This is the app.
- [AirPlayEngine/](AirPlayEngine/AGENTS.md) — a standalone SwiftPM package
  that extracts OwnTone's AirPlay 2 sender (vendored GPL/BSD/MIT C, license
  headers preserved) into an engine this project owns, names neutrally, and
  wraps in a Swift `actor` API — **no OwnTone runtime dependency**. Passed a
  gated first-light session against a real Sonos speaker
  (`docs/first-light-report.md`); every follow-up from that session is now
  fixed (`PLAN-PHASE-2B.md` D3). This is what `NativeBackend` drives.
- [dev/](dev/AGENTS.md) — offline dev tooling: the in-app `MockBackend`
  reference, an optional shairport-sync "fake speaker" script for
  sanity-checking the real Bonjour/AirPlay-1 wire path (single-device only —
  see that folder's docs for why), and docs for running the real `native`
  backend (`dev/notes/p2b-nativebackend-runbook.md`). **Also** `dev/notes/`,
  this project's home for pre-implementation research briefs and
  phase-completion write-ups — see that folder's AGENTS.md for the current
  brief index.
- [scripts/](scripts/make-app.sh) — `make-app.sh` wraps the
  `AirPlayControllerApp` SwiftPM executable into a real, double-clickable
  `.app` bundle with a stable bundle id and ad-hoc codesign. This is also the
  **required** path for exercising the `native` backend's TCC-gated Core
  Audio process tap — a bare `swift run` doesn't reliably keep the TCC grant
  across rebuilds (see the runbook above).
- [SPEC.md](SPEC.md) — the product spec: problem statement, confirmed
  requirements, feature list (v1/v2/later), technical architecture, phased
  build plan, Phase 0 feasibility findings, and the full UI design (menu bar,
  groups, mixer window). Treat this as the source of truth for *what* to
  build; code comments across the repo cite specific sections (e.g. "SPEC.md
  §9") for the reasoning behind a decision.
- `PLAN-PHASE-2.md` / `PLAN-PHASE-2B.md` / `PLAN-POPOVER-ROUTING.md` /
  `PLAN-0e-0f.md` / `PLAN-PHASE-1.md` — the phased execution plans (each with
  its own resolved decisions and task breakdown) that got the repo to its
  current state. `PLAN-PHASE-2B.md`'s "Resolved decisions" section (D1–D7) is
  the most relevant one for anything touching the native path today.

## Notable Patterns

- **Three backends, one seam.** `OutputBackend` (in `AirPlayControllerCore`)
  is the only protocol the UI depends on. `makeBackend()` resolves which
  concrete type to construct from `AIRPLAY_BACKEND` (`mock` default |
  `owntone` | `native`) — see `dev/README.md`. Anything that needs to "see" a
  device for UI/control-logic work should target `MockBackend`, not assume
  hardware. `native` is the only backend that opens real sockets/PTP ports
  and needs a real TCC grant — treat it differently from the other two.
- **The engine is a separate package on purpose.** `AirPlayEngine` knows
  nothing about `Device`, groups, or the UI — it's a session-primitives
  `actor` (`start`/`stop`/`addOutput`/`removeOutput`/`setVolume`/`write`/
  `makeStateStream`). `NativeBackend` (in `AirPlayControllerCore`) is the
  translation layer that turns those primitives into `OutputBackend`'s
  `Device`/`BackendEvent` contract. Don't add AirPlay-protocol logic to
  `AirPlayControllerCore`, and don't add `Device`/UI-shaped concepts to
  `AirPlayEngine`. It's a standalone package rather than a target inside
  `AirPlayControllerCore` for a second reason too: it vendors GPL/MIT/BSD
  source under per-license-labeled subdirectories, and that licensing boundary
  is cleaner as its own package. Read its own AGENTS.md before touching it.
- **Vendored C stays byte-identical; escape hatches are ledgered.** Every fix
  needed to get the engine working lives in `AirPlayEngine/Sources/CAirPlayEngine/shims/`
  (code this project owns) or the Swift hosting layer, not the vendored
  `sender/`/`evrtsp/`/`pair_ap/`/`libairptp/` sources. The rare exception is
  recorded in `AirPlayEngine/docs/VENDORED-DIFFS.md` with the license,
  rationale, and exact hunk.
- **Discovery is app-owned, not engine-owned.** The engine takes fully
  resolved `DeviceDescriptor`s via `updateDiscovery(_:)`; it runs no mDNS
  itself. `NativeDiscovery` (in `AirPlayControllerCore`) is the `NWBrowser`
  wrapper that feeds it, browsing both `_airplay._tcp` (AirPlay 2) and
  `_raop._tcp` (AirPlay 1) so AP1-only receivers can be shown even though
  they aren't yet driven.
- **Capture is in-process, not a subprocess.** `NativeCaptureCoordinator`
  uses an in-process Core Audio process tap (`AudioHardwareCreateProcessTap`,
  macOS 14.4+) directly inside the app — no `audiocap` subprocess, no IPC.
  `dev/audiocap/` still exists as a separate historical spike/reference; it
  is not what ships.
- **The core package knows nothing about AppKit's dependents.**
  `AirPlayControllerCore` (the Swift package) hosts both the pure logic and
  the AppKit UI targets, but the UI targets depend on the model/backend
  targets — never the reverse. (The `AirPlayControllerCore` library target
  itself imports no AppKit, and that's verified.)
- **Research briefs live in `dev/notes/`, not in this repo's memory/chat
  history.** Before starting a non-trivial phase of work (per-app audio
  routing, synced local output, the PTP helper's production install path,
  auto-reconnect/EQ), check `dev/notes/` for an existing brief — several were
  written 2026-07-17 specifically to de-risk the next phases before
  implementation starts.

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
