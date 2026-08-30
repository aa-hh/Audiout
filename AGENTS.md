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

**Three sections, ≤300 words per folder AGENTS.md:**

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
Not a folder here, but linked into the app: **`AudioutProtocol`**, the wire
contract for the Mac↔iPhone companion app (messages, commands, snapshot
schema), lives in https://github.com/aa-hh/audiout-shared. MIT, not GPL,
because the closed-source iPhone app links the same code, and a repository of
its own because SwiftPM cannot depend on a package inside a subdirectory of
another repo. `AudioutCore` pins it by version.

### Shared-code changes (AudioutProtocol / ProbeKit)

The pin above makes `audiout-shared` read-only from inside this repo, which
is exactly why a local copy of one of its types is the path of least
resistance — and exactly what `.githooks/guard-shared-leak.sh` blocks. The
sanctioned path for a wire-format field, a protocol case, or a ProbeKit
tweak:

1. Edit it in `~/Projects/audiout-shared` directly — never here.
2. Test there: `swift test` (no wrapper scripts in that repo).
3. Tag and push: `git tag X.Y.Z && git push origin main --tags`. Whether
   that also needs a `CompanionProto.version` bump is audiout-shared's own
   rule — see its AGENTS.md, don't re-derive it here.
4. Bump the pin in **both** consumers in the same session — this repo
   (`AudioutCore/Package.swift` + `Package.resolved`) and audiout-remote's
   Xcode package pin. A protocol change ships to both apps together or not
   at all.
- [AirPlayEngine/](AirPlayEngine/AGENTS.md) — standalone package: a vendored
  AirPlay 2 sender wrapped in a Swift `actor`. No OwnTone runtime dependency.
Not a folder here, but linked into the app: **`ProbeKit`**, the sync-probe DSP
(sweep synthesis + matched filter), lives in https://github.com/aa-hh/audiout-shared
together with the companion wire protocol. MIT, not GPL, because the
closed-source iPhone app links the same code, and a repository of its own
because SwiftPM cannot depend on a package inside a subdirectory of another
repo. `AudioutCore` pins it by version.
- [dev/](dev/AGENTS.md) — offline dev tooling, plus `dev/notes/`, the home for
  research briefs and phase write-ups.
- [scripts/make-app.sh](scripts/make-app.sh) — wraps the executable into a real
  `.app` with a stable bundle id, signed with a Developer ID identity when one
  is present in the keychain (auto-detected, override with `CODESIGN_IDENTITY`),
  else ad-hoc. Required for the `native` backend's TCC-gated process tap; a
  bare `swift run` loses the grant.
- [docs/SPEC.md](docs/SPEC.md) — the product spec. Code cites its sections ("SPEC.md §9").
- `docs/plans/PLAN-*.md` — the phased execution plans and their resolved decisions.

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
- **"Does this code exist anywhere?" needs more than `git grep`.**
  `git rev-list --all` and `git grep <branch>` cannot see unreachable commits or
  other worktrees' uncommitted work — a dropped stash once made a shipped feature
  look as though it had never existed. Also check `git fsck --unreachable`,
  `git stash list`, the reflog, and the other worktrees. Quote every path: this
  repo's own path contains a space, which silently breaks unquoted loops.
- **When a fix rests on a claim about live system state, verify that claim with a
  real command before writing the fix.** Much of what decides behavior here lives
  outside the code — which device macOS currently treats as the default output,
  what the public aggregate device is made of, which permissions are granted. The
  tests that run routinely cannot see any of it (the real-hardware suite is
  opt-in and skips by default), so they encode what you believed rather than
  what is true, and the suite stays green while the app is broken. Check against
  a running system sitting in the failing state instead of inferring from source:
  `system_profiler SPAudioDataType | grep -B3 "Default Output Device: Yes"` names
  the device macOS is really playing through, and
  `AUDIOUT_CORE_AUDIO_DIAGNOSTIC=1 swift run --package-path AudioutCore
  core-audio-diagnostic` lists the Core Audio process objects behind per-app
  routing.
- **Inner-loop test command:** see [AudioutCore/AGENTS.md](AudioutCore/AGENTS.md) for
  guidance on scoping tests with `--filter`, and for the "tests must stay
  invisible" rule every UI test has to obey.
- **Flag finished worktrees `.prunable`; never hand-delete them.** Fifteen
  worktrees' SwiftPM caches once filled the disk to zero bytes free mid-build.
  `scripts/housekeeping.sh` (invoked automatically by `scripts/run-tests.sh`
  and `scripts/make-app.sh` whenever a build starts) does two things: it
  removes any worktree whose root contains a `.prunable` marker — but only if
  it is clean, unreferenced by any running process, and its HEAD is merged
  into `main` or pushed — and it sweeps build caches machine-wide. What counts
  as a cache: every `.build` under any checkout (found by search, so the
  spike packages under `dev/` are included, not just the three top-level
  ones), plus Xcode's own `iOS DeviceSupport` and `DerivedData` directories,
  which the iPhone work fills at ~1.5 GB per attach and which once hit 6.4 GB.
  Any of them untouched for `AUDIOUT_CACHE_MAX_AGE_DAYS` (7) is deleted, and
  below `AUDIOUT_MIN_FREE_GB` (8) free disk they go cheapest-to-lose first —
  Xcode's ahead of any warm `.build`, since a re-attach costs nobody's time
  and a cold rebuild costs ~95s per commit. **The floor is headroom the script
  guarantees with the caches it owns, not a claim on the disk** — when
  reclaiming everything still would not reach it, the shortfall came from
  elsewhere, so the caches stay warm and it says so instead of thrashing.
  Below `AUDIOUT_CRITICAL_FREE_GB` (2) it takes everything anyway. The
  building checkout and any checkout a live process references are never
  touched, Xcode's caches are left alone entirely while Xcode is running, and
  the simulator runtime image (~7.5 GB) and simulator devices are never
  touched at all — those are downloads and test state, not build output.
  When a branch is merged AND live-verified (or abandoned with everything
  pushed), `touch .claude/worktrees/<slug>/.prunable` and let the system
  collect it. The flag is a request, not a command — a dirty or unpushed
  worktree is refused with the reason printed.
- **Hold the live-test slot before building or launching the shared dev id.**
  Only one native Audiout can run at a time (the PTP helper binds UDP 319/320
  exclusively) and the dev loop reuses one bundle id,
  `com.audiout.Audiout.dev`, so its permissions survive rebuilds. Two agents
  therefore cannot both be live-testing: the second overwrites the first's
  `.app` and its copy fights the running one for the same daemon identity,
  and both failures are silent. `scripts/livetest.sh acquire --label <branch>`
  takes the machine-wide slot, `status` says who holds it and who is waiting,
  `done` frees it — and `scripts/make-app.sh` refuses to build that one bundle
  id unless you hold it. **Acquisition never blocks**: exit 2 means busy, so
  report your queue position and go do other work rather than waiting. Free it
  as soon as Alec gives a verdict. Details and the 45-minute expiry rule are in
  [CLAUDE.md](CLAUDE.md) under "Build & run"; the traps are in the script's own
  header. A fresh per-handover bundle id is a different daemon identity and
  needs no slot.
- **Sweep stale PTP-helper daemons routinely — and always before a native live
  test.** Old dev builds and side-by-side copies leave `*.ptphelper` launchd
  jobs bound to UDP 319/320; a single stale one makes a healthy on-demand helper
  look broken (they have piled up 16-deep). `scripts/purge-stale-ptp-helpers.sh`
  lists them (dry-run, no sudo — safe to run anytime, so run it periodically);
  `scripts/purge-stale-ptp-helpers.sh --apply` boots them out. `--apply` needs
  `sudo`, so it prompts and cannot run unattended — an agent runs it only where a
  human can enter the password. Never `--apply` while a live Audiout session is
  actively streaming: it unloads the running helper too. It only ever touches
  `*.ptphelper` jobs. `--keep <label>` spares one exact label.
- **Uninstall dead hand-off builds with `scripts/purge-dev-installs.sh`.** The
  one-bundle-id-per-build rule above is correct and stays, but each throwaway id
  leaves permanent residue that trashing the `.app` does not remove: a
  preferences domain, TCC grants (a dead row in System Settings › Privacy &
  Security forever), a PUBLIC aggregate audio device that keeps appearing in
  Sound settings, and a root PTP-helper daemon. This script finds every
  non-shipping `com.audiout.*` identity across all four surfaces, unions
  them, and removes the lot — plus the preference domains leaked by the test
  suites (`swift test` creates a per-test `UserDefaults` suite and never
  removes it; this had reached **48,769 plists**, 98% of everything in
  `~/Library/Preferences`). Dry-run by default; `--apply` to act. The shipping
  id is a hardcoded literal it refuses to touch, and
  `~/Library/Application Support/Audiout/` (the real saved groups and routes)
  is never in scope. Two traps it already handles, both learned the hard way:
  CoreAudio silently refuses to destroy an aggregate that is the current system
  output — it returns `noErr` and the device is still there — so the script
  switches the system back to the built-in speakers first; and `cfprefsd`
  rewrites deleted plists from its in-memory cache, so `defaults delete`
  precedes every file removal and the daemon is restarted at the end.

## `main` is MERGE-ONLY (HARD RULE)

**Never `git commit` while standing on `main`.** Everything — code, docs,
one-line fixes — is authored and committed in your own worktree and reaches
`main` only as a **merge**. Guard 1 enforces exactly this: merges pass, a bare
commit on `main` is refused.

**Do not work in the `main` checkout at all.** Merely *editing* it starts the
accident, even if you never commit.

**If you find uncommitted edits in the `main` checkout that are in your way:
stop and ask.** Never `reset --hard` / `checkout --` / `stash` them away. They
belong to another session and are unrecoverable once discarded — unstaged work
was never hashed.

**Why this is non-negotiable — the repo's most expensive failure, which nobody
decided to do:** someone edited AGENTS.md directly in the `main` checkout,
describing code that lived in a different session's worktree. An unrelated agent
then couldn't merge past those loose edits, so it did the tidy-looking thing and
committed them (`f1f3e94`: five AGENTS.md, zero `.swift`). `main` now documented
a feature present in no source file, and every agent that read it believed it.
The code survived only as a dropped stash; recovering it cost a full session.
**The half-save was the shape of the accident, not anyone's intent — committing
loose edits looks like helpfulness.**

Merge-only makes docs-ahead-of-code structurally impossible: a doc and its code
ride the same branch and become true on `main` in the same instant.

**Pre-commit guards** (`.githooks/pre-commit`; enable once per clone with
`git config core.hooksPath .githooks`, override once with `--no-verify`). The
two that shape how you work, plus the review gate; the rest (test suites 4/6,
warn-only 3/5) are documented in the hook file itself:

- **Guard 1 blocks** a direct commit on `main`. Merges are unaffected; it never
  fires in a worktree.
- **Guard 2 warns** when an AGENTS.md names a symbol absent from that commit's
  own source — catching a name wrong from birth (`d033466`) or a doc left stale
  after a deletion. It checks the commit you are creating: not `main` (unmerged
  truth is still true) and not the working tree (which would have let `f1f3e94`
  through). Known false positives: AppKit types named as design guidance but used
  nowhere.
- **Guard 7 blocks** a Swift commit until the staged-diff readability
  self-review has run: `scripts/self-review.sh` shows the checklist and writes
  a receipt keyed to the exact staged bytes — READ your staged diff against
  [docs/REVIEW-RUBRIC.md](docs/REVIEW-RUBRIC.md) (change-log narration, stale
  claims, misleading names, reviewer-speak) before committing; restaging
  invalidates the receipt on purpose. It also hard-blocks near-certain slop
  patterns in added comments (trailing `slop-ok` exempts a legitimate line).

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
  `Tokens` (`AudioutCore/Sources/AudioutSharedUI/Tokens.swift`, sub-namespaces
  `Tokens.Color`, `Tokens.Font`, `Tokens.Layout`, `Tokens.Material`) is the
  only place a custom palette value may ever live. Everywhere else in the app
  stays plain semantic `NSColor`/`NSFont`/`NSVisualEffectView.Material` — do not
  add a second token module or a raw hex/RGB literal anywhere outside this file.
  Any custom color the module ever holds must ship light, dark, and Increase
  Contrast variants plus a written contrast rationale before it lands.
- **Respect system settings**: Reduce Motion, Increase Contrast, Reduce
  Transparency.
- **"Match Control Center / System Settings" is retired as guidance.** For the
  sanctioned custom-drawn Warm Signal pieces (canvas, connection ring, signal
  dot, meter, bus control, fader skin, shell bubble fill) the design authority
  is the Warm Signal spec, `dev/notes/warm-signal-v3.md` — not Control Center.
  Stock AppKit behavior, controls, and accessibility remain mandatory
  regardless: the spec governs paint, not interaction model.
- **The Figma design system mirrors the UI code.** Any change to `Tokens`,
  `PopoverColumnGrid`, a custom-drawn view, or a screen must be mirrored in the
  Figma file per [docs/FIGMA-DESIGN-SYSTEM.md](docs/FIGMA-DESIGN-SYSTEM.md).
- Deviating is fine when the system has no equivalent — but note *why* in the
  nearest AGENTS.md, so the next agent doesn't "fix" it back to a system control
  that doesn't fit.
- **Gold-budget house rules, in short:**
  1. Stock AppKit controls before custom drawing, everywhere except the
     sanctioned Warm Signal surfaces.
  2. All custom color lives in `Tokens` and nowhere else.
  3. Every `Tokens.Color` case ships light + dark + Increase Contrast variants
     with a documented contrast rationale.
  4. Warm Signal spec (`dev/notes/warm-signal-v3.md`) governs the sanctioned
     custom pieces; Control Center is no longer the reference.
  5. SF Symbols, template-rendered, for every glyph.
  6. Respect Reduce Motion, Increase Contrast, Reduce Transparency.
  7. No second token module, ever — `Tokens` is the one governed exception.
  8. Any other deviation from system chrome gets a documented "why" in the
     nearest AGENTS.md.
