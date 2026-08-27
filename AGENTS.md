# Audiout

## Purpose

A native AppKit macOS app for sending system audio to several AirPlay 2 speakers
at once — per-device volume, mute, saved groups, per-app routing, multi-room
sync. [docs/SPEC.md](docs/SPEC.md) is the source of truth for *what* to build; this file
orients an agent to where things live and the rules that apply everywhere.

## What belongs in an AGENTS.md (HARD RULE)

An AGENTS.md tells an agent what the **code cannot**, before it edits that
folder. It is not a summary of the code.

**The test, applied to every line: would this become wrong if someone changed the
code without thinking about docs?** If yes, it does not belong. Document intent,
constraints and traps — never implementation.

**Three sections, ≤150 lines per folder AGENTS.md — most folders need far fewer:**

1. **Purpose** — what lives here, why it is separate, what it must never do.
2. **Rules** — constraints an agent breaks by accident: architectural
   boundaries, invariants, and **traps** (where the obvious reading is wrong).
   This is the highest-value content in the file; give the *why* in a clause.
3. **Map** — one line per type, ≤12 words: name → what it is.

**Never document:** signatures, parameters, defaults or types (the compiler owns
them) · what a function does step by step (read it) · flows narrating a call
chain (they rot on every refactor) · dates, changelogs, "NEW", task or decision
ids (git owns history) · test-coverage tables (the test names own that) ·
diagrams that restate imports.

**Every symbol you name is a rot point** — Guard 2 verifies each one exists, so
name only what earns it. Over budget means you are describing code.

Corollary for readers: **docs orient, code decides.** If an AGENTS.md names a
symbol you cannot find in source, believe the source and fix the doc.

## Folder Map

- [AudioutCore/](AudioutCore/AGENTS.md) — the Swift package:
  the `Device` model, the `OutputBackend` seam and its implementations, per-app
  routing, the AppKit UI targets, and the shipping app target. This is the app.
- [AirPlayEngine/](AirPlayEngine/AGENTS.md) — standalone package: a vendored
  AirPlay 2 sender wrapped in a Swift `actor`. No OwnTone runtime dependency.
- [dev/](dev/AGENTS.md) — offline dev tooling, plus `dev/notes/`, the home for
  research briefs and phase write-ups.
- [scripts/make-app.sh](scripts/make-app.sh) — wraps the executable into a real
  `.app` with a stable bundle id, signed with a Developer ID identity when one
  is present in the keychain (auto-detected, override with `CODESIGN_IDENTITY`),
  else ad-hoc. Required for the `native` backend's TCC-gated process tap; a
  bare `swift run` loses the grant.
- [docs/SPEC.md](docs/SPEC.md) — the product spec. Code cites its sections ("SPEC.md §9").
- `docs/plans/PLAN-*.md` — the phased execution plans and their resolved decisions.
- `ios/` — the iPhone companion app. Not present in `main` or this worktree;
  staged on `claude/ios-staging` until the whole app is ready to merge. See
  [CLAUDE.md](CLAUDE.md#ios-companion-app) — start any iOS task from that
  branch, never from `main`.

## Rules (all targets)

- **Three backends, one seam.** `OutputBackend` is the only protocol the UI
  depends on; `makeBackend()` resolves the concrete type from `AIRPLAY_BACKEND`.
  Target `MockBackend` for UI/control work — never assume hardware. Only the
  native backend opens real sockets and needs a TCC grant; treat it differently.
- **The engine is a separate package on purpose.** It knows nothing about
  `Device`, groups, or the UI. Never add AirPlay-protocol logic to
  `AudioutCore`, or `Device`/UI-shaped concepts to `AirPlayEngine`. It
  is also a licensing boundary — it vendors GPL/MIT/BSD source.
- **Vendored C stays byte-identical.** Fixes belong in the shims or the Swift
  hosting layer; any exception is ledgered in
  `AirPlayEngine/docs/VENDORED-DIFFS.md` with license, rationale and hunk.
- **UI targets depend on the model, never the reverse.** The
  `AudioutCore` library target imports no AppKit, and that is verified.
- **Read `dev/notes/` before a non-trivial phase** — briefs exist to de-risk work
  before it starts.
- **"Does this code exist anywhere?" needs more than `git grep`.** A dropped
  stash once made a shipped feature look as though it had never existed —
  unreachable commits and other worktrees' uncommitted work don't show up in a
  plain grep. Quote every path: this repo's own path contains a space, which
  silently breaks unquoted loops.
- **Inner-loop test command:** see [AudioutCore/AGENTS.md](AudioutCore/AGENTS.md) for
  guidance on scoping tests with `--filter`, and for the "tests must stay
  invisible" rule every UI test has to obey.
- **Flag finished worktrees `.prunable`; never hand-delete them.** When a
  branch is merged and live-verified (or abandoned with everything pushed),
  `touch .claude/worktrees/<slug>/.prunable`. `scripts/housekeeping.sh`
  (invoked automatically by `run-tests.sh` and `make-app.sh` on every build)
  prunes it and sweeps stale `.build`/Xcode caches machine-wide. A dirty or
  unpushed worktree is refused, not force-pruned.
- **Sweep stale PTP-helper daemons routinely, and always before a native live
  test.** `scripts/purge-stale-ptp-helpers.sh` (dry-run, no sudo, safe to run
  anytime) lists them; `--apply` needs `sudo` and must never run while a
  session is actively streaming — it would unload the running helper too.
- **Uninstall dead hand-off builds with `scripts/purge-dev-installs.sh
  --apply`.** Removes residue (prefs, TCC grants, the aggregate audio device,
  a PTP daemon) left by throwaway bundle ids and the `UserDefaults` domains
  test suites leak. Never touches the shipping id or
  `~/Library/Application Support/Audiout/`. Handles two hard-won quirks:
  CoreAudio silently no-ops when asked to destroy an aggregate device that is
  the current system output; `cfprefsd` rewrites deleted plists from its cache
  unless the daemon is restarted afterward. Dry-run by default.

## `main` is MERGE-ONLY (HARD RULE)

**Never commit directly on `main`** — work happens in a worktree branch and
reaches `main` only via merge. Guard 1 enforces this.

A stray edit in the `main` checkout was once merged with no code behind it,
recovered only from a dropped stash — merge-only makes that structurally
impossible: a doc and its code ride the same branch and become true on `main`
in the same instant.

**Pre-commit guards** (`.githooks/pre-commit`; enable once per clone with
`git config core.hooksPath .githooks`, override once with `--no-verify`). Test
suites (4/6) and warn-only checks (3/5) are documented in the hook file itself:

- **Guard 1**: bare commit on `main` blocked; merges pass.
- **Guard 2** warns when an AGENTS.md names a symbol absent from that commit's
  own source. It checks only the commit being created — not `main`, not the
  working tree. Known false positive: AppKit types named as design guidance
  but used nowhere.
- **Guard 7** blocks a Swift commit until the staged-diff self-review
  (`scripts/self-review.sh`) has run, against
  [docs/REVIEW-RUBRIC.md](docs/REVIEW-RUBRIC.md). The receipt it writes is
  keyed to the exact staged bytes, so restaging invalidates it. A trailing
  `slop-ok` comment exempts a legitimate line from the blocked slop patterns.

## UI / Design Conventions (all targets)

This app must feel like a native macOS citizen, not a cross-platform port.

- **Stock AppKit before custom drawing.** Reach for `NSSwitch`, `NSSlider`,
  `NSPopUpButton`, `NSButton` bezel styles, `NSVisualEffectView` and
  `NSStackView` before writing a custom `NSView` with manual `draw(_:)`. Custom
  drawing is justified only when no system control expresses the design — and
  even then, compose system chrome rather than hand-rolling colors.
- **SF Symbols for every glyph**, template-rendered so tint and appearance track
  automatically. Don't ship custom assets for something SF Symbols covers.
- **System colors and materials, never hardcoded hex** — so Dark Mode, accent
  color and contrast settings all work for free. **One sanctioned exception:**
  `Tokens` (`AudioutCore/Sources/AudioutSharedUI/Tokens.swift`) is the only
  place a custom palette value may ever live — do not add a second token
  module or a raw hex/RGB literal anywhere outside this file. Any custom color
  the module holds must ship light, dark, and Increase Contrast variants plus
  a written contrast rationale before it lands.
- **Respect system settings**: Reduce Motion, Increase Contrast, Reduce
  Transparency.
- **For the sanctioned custom-drawn Warm Signal surfaces**, the design
  authority is `dev/notes/warm-signal-v3.md`, not Control Center; stock AppKit
  interaction and accessibility still apply regardless — the spec governs
  paint, not interaction model.
- **The Figma design system mirrors the UI code.** Any change to `Tokens`,
  `PopoverColumnGrid`, a custom-drawn view, or a screen must be mirrored in the
  Figma file per [docs/FIGMA-DESIGN-SYSTEM.md](docs/FIGMA-DESIGN-SYSTEM.md).
- Deviating is fine when the system has no equivalent — but note *why* in the
  nearest AGENTS.md, so the next agent doesn't "fix" it back to a system control
  that doesn't fit.
