# Shared brief: Mac app migration to the iOS DESIGN.md system

You are one of eight scoping agents. You research ONE slice of the Audiout Mac app and return migration OPTIONS. You do not write code, do not edit repo files, do not run builds or tests. Return your findings as plain text in your final message (a hook blocks writing `report-*.md` files, so do not try).

## The decision already made (owner's call, 2026-09-03)

- The Mac app's design authority becomes the iOS companion's DESIGN.md at `~/Projects/audiout-remote/DESIGN.md` (1201 lines, Impeccable format: YAML frontmatter of tokens, then prose with Named Rules per section). READ IT FULLY FIRST. Its Overview, Colors, Typography, Layout, Elevation, Shapes, Components, Named Rules and Do's/Don'ts sections are the standard the Mac surfaces must be re-designed to meet.
- `docs/FIGMA-DESIGN-SYSTEM.md` and the Figma file are being abandoned. Do not propose Figma work.
- The unmerged Mac DESIGN.md on branch `origin/claude/design-record-refresh` (PR #102) is being discarded. You may read it (`git show origin/claude/design-record-refresh:DESIGN.md`) as a description of the Mac's CURRENT design, which is useful for "what exists today", but it is not the target.
- Light mode: the owner prefers the iOS cool-neutral light chassis over the Mac's current warm light ("Circuit theme", PRODUCT.md:92), BUT "if it makes sense, we can keep certain elements from the existing design system." So for every Mac element you touch, say explicitly: adopt iOS, keep Mac, or hybrid, and why. Elements that earn keeping should be argued for, not assumed.
- The Mac app is native AppKit (not SwiftUI). The iOS file's rules are the target; the mechanisms (fonts, layers, drawing) will differ. Translate rules, not code.

## Repo facts

- Working tree: `~/Projects/AirPlay Controller/.claude/worktrees/delay-trim-sync-wizard-b99148` (a git worktree; work from here, never cd to the main checkout).
- Read `AGENTS.md` at the repo root, then the `AGENTS.md` in every source folder you read. They record traps the code cannot tell you.
- Mac tokens: `AudioutCore/Sources/AudioutSharedUI/Tokens.swift` (colours as `Tokens.Color` cases, fonts as `Tokens.Font`), layout constants in `AudioutCore/Sources/AudioutSharedUI/PopoverColumnGrid.swift` and `SurfaceLayout.swift`.
- UI targets under `AudioutCore/Sources/`: `AudioutSharedUI` (tokens + shared components), `AudioutPopoverUI` (menu-bar popover and the sync wizard views), `AudioutWindowUI` (Groups/mixer window), `AudioutSettingsUI`, `AudioutOnboardingUI` (onboarding + licence gate), `AudioutApp` (menu bar status item, media keys, Touch Bar).
- Snapshot harness targets exist: `popover-snapshot`, `window-snapshot`, `settings-snapshot`, `onboarding-snapshot`, `wizard-snapshot`. Golden images under `window-snapshot` must NEVER be regenerated (they are unreproducible across machines). Mention tests that will need updating, but do not run them.
- Tests live in `AudioutCore/Tests/AudioutCoreTests`. Grep there for tests that assert on specific colours, sizes, or token values in your slice; list them so the executor knows what will break.
- Product spec: `docs/SPEC.md` section 9 ("UI design — pure AppKit") and `PRODUCT.md`. If the iOS system contradicts a spec decision, name the conflict; do not resolve it.

## You may use the `impeccable` skill

Load it (`Skill` tool, name `impeccable`) if it helps you frame the critique or the options. It is web-oriented; take its design reasoning, ignore its web mechanics.

## What to return (fixed template, fill every heading, keep it tight)

```
# <Slice name>

## What exists today
5 to 12 bullets. Each names a file:line. Colours, type, spacing, depth, components as actually drawn. Include which Mac tokens this slice consumes.

## Where it breaks the iOS rules
Bullet per violation. Quote the iOS Named Rule or token it violates (section name), then the Mac file:line that violates it.

## Worth keeping from the Mac
Bullet per element you argue should survive (as-is or as a hybrid). One sentence of why each. If nothing, say "nothing".

## Options
Two or three. For each:
### Option <letter>: <short name>
- What changes (concrete: which files, which tokens, which drawing code)
- What stays
- Light mode handling
- Effort: S / M / L / XL, with a one-line justification
- Risk: what could break, which tests assert on it
- Dependencies: which shared-token decisions this needs first (name the token or rule)
- Recommendation: recommended / viable / not recommended, one sentence why

## Open questions for the owner
Only real forks where two readings lead to materially different work. Zero is fine.

## Files touched (union across options)
Plain list of repo-relative paths.
```

Ground every claim in a file:line you actually read. If unsure, say unsure. Do not invent terms; use the names in the iOS DESIGN.md and the Mac code.
