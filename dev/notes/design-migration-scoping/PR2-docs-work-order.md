# PR 2 work order: docs, zero Swift

Executor: Opus, effort medium. One serial track. This PR touches no Swift, so
Guards 4, 6 and 7 do not run. It is independent of PR 1 and may merge before
or after it.

## Goal

Remove the Figma design system as the Mac's design authority, record the
2026-09-03 decisions in the two brand commitments they overturn, and check in
the migration's scoping notes. Nothing else.

## Scope fences

- No `.swift` file. No `Package.swift`. No `.gitignore`. No scripts.
- Do not edit `docs/FIGMA-DESIGN-SYSTEM.md`: delete it (Step 3).
- Do not edit any other line of the files below than the ones named.
- Do not create `DESIGN.md` (PR 9 owns it) and do not touch `.impeccable/`.
- Do not commit `PR1-tokens-work-order.md`, `PR1-pr-body.md`, or any
  `PR3-*.md` from the scoping notes: PR 1 and PR 3 carry their own.
- Do not merge.

## Pre-flight

```bash
cd ~/"Projects/AirPlay Controller"
git fetch origin
git worktree add .claude/worktrees/design-docs -b claude/design-docs origin/main
cd .claude/worktrees/design-docs
git push -u origin claude/design-docs
git config core.hooksPath .githooks
```

All later paths are relative to `.claude/worktrees/design-docs`. Verify each
"currently reads" quote below with `sed -n` before editing; if a line has
moved, find it by content, and if the content differs, STOP and report.

## Step 1 — `AGENTS.md`

1a. Lines 280–285 currently read:

```
- **"Match Control Center / System Settings" is retired as guidance.** For the
  sanctioned custom-drawn Warm Signal pieces (canvas, connection ring, signal
  dot, meter, bus control, fader skin, shell bubble fill) the design authority
  is the Warm Signal spec, `dev/notes/warm-signal-v3.md` — not Control Center.
  Stock AppKit behavior, controls, and accessibility remain mandatory
  regardless: the spec governs paint, not interaction model.
```

Replace with:

```
- **"Match Control Center / System Settings" is retired as guidance.** For the
  sanctioned custom-drawn Warm Signal pieces (canvas, connection ring, signal
  dot, meter, bus control, fader skin, shell bubble fill) the design authority
  is `DESIGN.md` at the repo root once the 2026-09-03 migration lands it, and
  until then the iPhone companion's `DESIGN.md` (`aa-hh/audiout-remote`) plus
  `dev/notes/design-migration-scoping/01-decisions.md`. `dev/notes/warm-signal-v3.md`
  is the historical spec, not the authority. Stock AppKit behavior, controls,
  and accessibility remain mandatory regardless: the design record governs
  paint, not interaction model.
```

1b. Lines 286–288 currently read:

```
- **The Figma design system mirrors the UI code.** Any change to `Tokens`,
  `PopoverColumnGrid`, a custom-drawn view, or a screen must be mirrored in the
  Figma file per [docs/FIGMA-DESIGN-SYSTEM.md](docs/FIGMA-DESIGN-SYSTEM.md).
```

Replace with:

```
- **`DESIGN.md` records the shipped design; nothing mirrors it elsewhere.**
  The Figma design system was abandoned on 2026-09-03. When a change to
  `Tokens`, `PopoverColumnGrid`, a custom-drawn view, or a screen lands, the
  record is regenerated from the code by the `impeccable-documenter` agent
  (`.claude/agents/impeccable-documenter.md`), never hand-mirrored.
```

## Step 2 — `PRODUCT.md`

2a. Line 90 currently begins `- Visual identity: **Warm Signal** — warm near-black ground with gold signal accent in dark.` Replace the whole bullet with:

```
- Visual identity: **Warm Signal** — a cool near-neutral chassis in both appearances (`#0A0A0C` dark, `#FAFAFB` light), with warmth reserved for wherever sound is going and gold for audio state and calls to action. Structure and controls stay native (stock AppKit / SF Symbols on Mac; HIG-conformant SwiftUI on iOS). The design authority is the iPhone companion's `DESIGN.md` (`aa-hh/audiout-remote`) for the shared rules and this repo's `DESIGN.md` for the Mac (written from shipped code at the end of the 2026-09-03 migration). Binding per the owner, 2026-09-03.
```

2b. Line 92 currently begins `- **Light mode is the Circuit theme**`. Replace the whole bullet with:

```
- **Both appearances are cool-neutral** (owner's call, 2026-09-03; supersedes the Circuit light of 2026-08-07 and the warm near-black dark): the scaffolding tokens — canvas, panels, wells, edges — take the iPhone companion's values in light and dark; light is one flat ground and separation there is edge weight, not fill. The name "Circuit" is retired with it.
```

2c. Line 93 currently begins `- **Instruments never theme.** The gold family, failure, caution, rings, meters, fader hardware and permission hues`. Change only the token list to `The gold family, failure, rings, meters, fader hardware and permission hues` (drop `caution`, retired 2026-09-03). Nothing else on the line changes.

2d. Line 102 currently begins `- docs/FIGMA-DESIGN-SYSTEM.md — the design system of record`. Replace the whole bullet with:

```
- `DESIGN.md` (Mac, lands with the migration's final PR) and `aa-hh/audiout-remote` `DESIGN.md` (shared rules; the authority the Mac migrated to on 2026-09-03). The scoping that drove the migration is in `dev/notes/design-migration-scoping/`. Design intent history in `dev/notes/warm-signal-v3.md`. The Figma design system (file `aGvr1qZ3tbqGD2e3jmA1Ru`) is abandoned and no longer mirrors code.
```

Line 94 (app icon master in Figma, locked) is a different Figma file: leave it.

## Step 3 — delete the Figma doc

```bash
git rm docs/FIGMA-DESIGN-SYSTEM.md
grep -rn "FIGMA-DESIGN-SYSTEM" --include='*.md' . | grep -v "\.build\|design-migration-scoping"
```

The grep must return nothing after Steps 4–7. (Swift references to the doc are
PR 1's.)

## Step 4 — `HANDOFF-wizard-v2.md`

Line 382 currently reads `- Figma design-system mirror of the new screen (house rule; not started).` Delete the line.

## Step 5 — `HANDOVER-popover-critique.md`

Lines 70–71 currently read:

```
- Figma design-system mirror of the Tokens/PopoverColumnGrid renames — Figma
  MCP was unauthenticated all session. Owed separately, not blocking.
```

Delete both lines.

## Step 6 — `docs/plans/PLAN-BT-SYNC-DRAWER.md`

6a. Lines 131–132 currently read (inside a bullet):

```
  column" (~lines 578–620) holds every SYNC metric as a named constant. The
  Figma design system mirrors this file 1:1 — **all new metrics go here, none
  inline.**
```

Replace with:

```
  column" (~lines 578–620) holds every SYNC metric as a named constant —
  **all new metrics go here, none inline.**
```

6b. Lines 607–611 are step `3. Figma: follow `docs/FIGMA-DESIGN-SYSTEM.md` exactly …` through `… Figma variable with Swift code syntax, both modes.` Delete the whole numbered item. If a step 4 follows, renumber it 3; if none, nothing else changes. Line 152's task graph mentioning "T8 (docs/Figma)" is history: leave it.

## Step 7 — `dev/notes/`

7a. `dev/notes/wizard-stage-v2-spec.md` line 434 ends with `Figma mirror owed (note, don't do).` Delete that sentence only; the rest of the line stays.

7b. `dev/notes/first-mix-wizard-default-work-order.md` lines 332–334 begin the bullet `- `docs/FIGMA-DESIGN-SYSTEM.md` — the `PopoverColumnGrid` contract mirrors the Figma file 1:1: add the three new constants …`. Delete the whole bullet (read to its end; it continues past 334).

## Step 8 — check in the scoping notes

```bash
mkdir -p dev/notes/design-migration-scoping
SRC=~/"Projects/AirPlay Controller/.claude/worktrees/delay-trim-sync-wizard-b99148/dev/notes/design-migration-scoping"
for f in 00-brief.md 01-decisions.md tokens.md rows.md popover.md groups.md settings.md onboarding.md wizard.md docs.md PR2-docs-work-order.md; do cp "$SRC/$f" dev/notes/design-migration-scoping/; done
ls dev/notes/design-migration-scoping
```

Exactly those eleven files. Not `PR1-*.md`, not `PR3-*.md`.

## Step 9 — close roadmap item 034 as dropped

```bash
echo '{"id":"034","status":"dropped","notes":"Superseded 2026-09-03 (the owner): the Figma design system and docs/FIGMA-DESIGN-SYSTEM.md are abandoned; the Mac design authority becomes DESIGN.md in the Impeccable format, mirroring the iPhone companion at aa-hh/audiout-remote. The Figma file aGvr1qZ3tbqGD2e3jmA1Ru is no longer mirrored and the AGENTS.md mirror rule is removed."}' | node ~/.claude/plugins/cache/foundry/foreman/0.46.0-alpha/scripts/roadmap.js update-status
git diff --stat ROADMAP.jsonl
```

If the roadmap tool refuses or is missing, STOP and report; do not hand-edit `ROADMAP.jsonl`.

## Verification

```bash
grep -rn "FIGMA-DESIGN-SYSTEM\|Figma design system\|Figma design-system\|Figma mirror" --include='*.md' . | grep -v "\.build\|design-migration-scoping\|AGENTS-HISTORY"
#   expected: no output
grep -n "Circuit" PRODUCT.md AGENTS.md
#   expected: only PRODUCT.md:92's "supersedes the Circuit light" clause
git status --short
#   expected: M AGENTS.md, M PRODUCT.md, D docs/FIGMA-DESIGN-SYSTEM.md, M HANDOFF-wizard-v2.md,
#   M HANDOVER-popover-critique.md, M docs/plans/PLAN-BT-SYNC-DRAWER.md, M dev/notes/wizard-stage-v2-spec.md,
#   M dev/notes/first-mix-wizard-default-work-order.md, M ROADMAP.jsonl, ?? dev/notes/design-migration-scoping/
git diff --stat
```

Then:

```bash
git add -A
git commit -m "Docs: retire the Figma design system; the iPhone's DESIGN.md is the Mac's design authority

Deletes docs/FIGMA-DESIGN-SYSTEM.md and the AGENTS.md rule that mirrored
UI code into Figma. PRODUCT.md's brand commitments now record the
2026-09-03 decisions: both appearances cool-neutral (the Circuit light and
the warm near-black dark are superseded), the iPhone companion's DESIGN.md
as the shared authority, and a Mac DESIGN.md written from shipped code at
the end of the migration. Strips the four owed Figma-mirror lines from
handoffs and plans, closes roadmap 034 as dropped, and checks in the
migration's scoping notes under dev/notes/design-migration-scoping/.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push origin claude/design-docs
gh pr create --base main --head claude/design-docs \
  --title "Design migration PR 2: retire the Figma design system (docs only)" \
  --body "$(cat <<'EOF'
Docs-only companion to PR 1. No Swift changes, so the test guards do not run.

- Deletes `docs/FIGMA-DESIGN-SYSTEM.md`; the Figma file is no longer mirrored.
- `AGENTS.md`: the design authority is `DESIGN.md` (Mac, lands with the migration's final PR) and the iPhone companion's `DESIGN.md`; the Figma-mirror house rule is gone.
- `PRODUCT.md`: brand commitments record the 2026-09-03 decisions — both appearances cool-neutral, Circuit light retired, `caution` retired.
- Four owed "Figma mirror" lines removed from handoffs and plans.
- Roadmap 034 closed as dropped.
- Checks in `dev/notes/design-migration-scoping/` (the eight scoping reports, the brief, the decisions, this work order).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Do NOT merge. Report the PR URL, the verification output, and `git show --stat HEAD`.

## Executor rules
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Read the repo root `AGENTS.md` before the first edit.
> - If a "currently reads" quote does not match the file, STOP and report the discrepancy. Do not improvise.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for.
> - "Done" means the Verification commands were run in this session and matched. Paste their output.
> - Touch nothing in the Scope fences list.
