# Individual local outputs — handover

Written 2026-09-26 from a cloud session that could read the repo but not build,
test, or touch hardware. Everything below is verified against source or is an
owner decision; nothing has been compiled. Start at "What to do next".

## Situation in one paragraph

A user asked for the Mac's local output to be split into one item per physical
output (speakers, headphone jack, USB, HDMI). The owner was grilled and made
seven decisions; they are in `spec.md` and are settled — do not re-open them.
Six tickets exist in `issues/`. No code has been written. The one gate before
code is ticket 01, a hardware pass the owner does on their Mac with wired
headphones in the jack and a display with speakers (no USB DAC is available;
the ticket names stand-ins). Draft PR #227 (`claude/local-audio-outputs-t8u20m`)
holds only these markdown files and is clean against `main`.

## Files

- `spec.md` — findings, decisions 1–7, design shape, done criteria.
- `issues/01-hardware-verification.md` — ready-for-human. Five questions; answers
  go under its `## Answer`.
- `issues/02-wired-kind-and-enumerator.md` — `Device.Kind.wired` + enumerator.
- `issues/03-wired-sink.md` — pinned synced sink per selected wired output.
- `issues/04-popover-rows-and-drawer.md` — Mixer rows, glyphs, drawer/wizard.
- `issues/05-routing-scope.md` — per-app, groups, companion snapshot.
- `issues/06-this-mac-plays-on-built-in-with-dac-default.md` — suspected
  pre-existing bug, independent of the feature; verify via ticket 01 Q5.

## Facts the next agent must not re-derive (all cited in spec.md)

- "This Mac" is ONE fixed-id row (`local-mac`) that follows the system default
  output; ~78 sites key off `Device.isLocalDevice`. Keep it exactly as is.
- Whole-system routing makes the public "Audiout" aggregate the default output,
  and that aggregate wraps ONLY the built-in output. The synced local sink
  renders through the default. This is the basis of ticket 06.
- Bluetooth rows are the template: `BTDeviceEnumerator` (transport filter,
  UID as id) + `BTDeviceSink` (pinned `AVAudioEngine`, `setDeviceID` before
  first start, refuses aggregate/virtual, delayed to `BTReferenceTimeline`).
- Licence: build the wired sink from the licence-clean `BTSyncedSink.swift` /
  `SyncCore.swift` family, never by copying the GPL `SyncedLocalSink.swift`.
- House rule: `kAudioHardwarePropertyDefaultOutputDevice`, never
  `…DefaultSystemOutputDevice`; a test fails the build on the wrong selector.

## What to do next, in order

1. **Owner, on the Mac:** do ticket 01. Plug wired headphones into the jack and
   attach a display with speakers (USB-C monitor counts as the USB stand-in).
   Run `system_profiler SPAudioDataType`, dump the HAL device list per the
   ticket, answer the five questions in the ticket file, set its
   `Status: resolved`. Question 5 also settles ticket 06.
2. **Agent, on the Mac:** `git worktree add .claude/worktrees/local-wired-outputs
   claude/local-audio-outputs-t8u20m` (the branch already exists on origin),
   `git config core.hooksPath .githooks`, then run
   `/scope-and-run3 .scratch/local-wired-outputs/issues/02-wired-kind-and-enumerator.md`.
   If ticket 01 found an Intel-style data-source flip, ticket 02's snapshot
   carries the data-source name so one row relabels (already written in).
3. Tickets 03 → 04 → 05 in that order, each through the pipeline, each its own
   PR merged with `--no-ff` per AGENTS.md. 04 and 05 both depend on 03 only, so
   they may run as parallel tracks once 03 is on the branch.
4. Ticket 06 is a separate fix on its own branch once Q5 confirms it; the
   options are in the ticket. If confirmed, consider landing it before 03: a
   wired sink that pins by device id makes option (b) nearly free.

## Rules that bit before, restated

- Never bare `swift test` / `swift build`; `scripts/run-tests.sh --filter`.
- Never edit in the `main` checkout; worktrees only; `main` is merge-only.
- Hold `scripts/livetest.sh acquire` before building the shared dev id; a
  fresh bundle id needs no slot.
- New tests name their defect in one comment sentence, or are not written.
- New `Analytics.capture` events are registered in
  `audiout-shared/docs/analytics-events.md` BEFORE being sent from here.
- `.scratch/` is committed with the branch; keep ticket `Status:` lines current.

## PR housekeeping

PR #227 is a docs-only draft. Either merge it so the spec lands on `main`
before code starts, or let ticket 02's PR carry these files; do not leave both
open with diverging copies of `spec.md`.
