# Docs, process, cleanup — scoping report

## What exists today
- docs/FIGMA-DESIGN-SYSTEM.md 433 lines, named "design system of record" at PRODUCT.md:102. Only home for the Circuit mapping table (:317-400), two off-Circuit re-tunes (well #E2DFD3, hairline #D0CDC3), measured light ratios, One Case supersession note (:180-185).
- AGENTS.md:286-288 = house rule "must be mirrored in the Figma file". AGENTS.md:280-285 names dev/notes/warm-signal-v3.md as design authority for custom-drawn pieces.
- Swift doc comments carry mirror rule: PopoverColumnGrid.swift:682, :759; BTSyncDrawerView.swift:89. Tokens.swift:203,206,215 cite the Figma doc as SOURCE of light hexes (+~20 Circuit rationales).
- No DESIGN.md in repo. PR #102 = 580 lines, single-file branch.
- .impeccable/design.json only in MAIN checkout, gitignored (.gitignore:37); nothing reads it; iOS repo has no .impeccable/ at all → OUT OF SCOPE.
- Repo ships .claude/agents/impeccable-documenter.md (model inherit, effort medium, maxTurns 30).
- ROADMAP 034 in_progress; 035/036 done. 9 entries in_progress overall.
- Guards: 4 = full suite on any AudioutCore Swift commit; 7 = self-review; merge-approval hook on every git merge.

## Figma references — verdicts
DELETE: docs/FIGMA-DESIGN-SYSTEM.md (harvest first); AGENTS.md:286-288; HANDOFF-wizard-v2.md:382; HANDOVER-popover-critique.md:70; docs/plans/PLAN-BT-SYNC-DRAWER.md:607-611; dev/notes/wizard-stage-v2-spec.md:434; dev/notes/first-mix-wizard-default-work-order.md:332-333.
REWRITE: PRODUCT.md:102 → point at new DESIGN.md + phone's; PLAN-BT-SYNC-DRAWER.md:131 keep "all new metrics go here"; PopoverColumnGrid.swift:682,:759 → "Named constants only."; BTSyncDrawerView.swift:89; Tokens.swift:203,206,215 → repoint or inline measured values (ONLY pointer to where light hexes came from).
LEAVE: PRODUCT.md:94 (icon Figma, different file); BrandMark.swift:12 (frame 111:2, see Q3); Audiout-Hero-1024.svg data-figma-skip-parse; dev/notes boards; PLAN-BT-SYNC-DRAWER.md:152 task graph; AGENTS-HISTORY.md:40 (optional); ROADMAP 035/036.
"design-record" grep: one hit in roadmap 059's what. No code references the discarded branch.
Roadmap 034: close DROPPED not done. Command:
echo '{"id":"034","status":"dropped","notes":"Superseded 2026-09-03 (the owner): the Figma design system and docs/FIGMA-DESIGN-SYSTEM.md are abandoned; the Mac design authority becomes DESIGN.md in the Impeccable format, mirroring the iPhone companion at aa-hh/audiout-remote. The Figma file aGvr1qZ3tbqGD2e3jmA1Ru is no longer mirrored and the AGENTS.md mirror rule is removed."}' | node ~/.claude/plugins/cache/foundry/foreman/0.46.0-alpha/scripts/roadmap.js update-status
Roadmap 059 + 076 cite the discarded branch's rules → annotate when the new file lands.

## New Mac DESIGN.md — schema + outline
- Schema (~/.claude/skills/impeccable/reference/document.md): top-level keys ONLY name, description, colors, typography, rounded, spacing, components. Component props ONLY backgroundColor, textColor, typography, rounded, padding, size, height, width. Eight canonical sections in fixed order (Overview, Colors, Typography, Layout, Elevation & Depth, Shapes, Components, Do's and Don'ts); unknown sections preserved (iOS carries Haptics, Decision Record, The sync surfaces).
- Four-variant problem: frontmatter = dark half, prose names light (iOS :177-179 pattern; PR #102 same). Mac adds one sentence: IC columns stay in Tokens.swift with measurement; DESIGN.md states the rule, doesn't list 4×45 hexes.
- Mac-only sections: permission identity hues + reserved-band arithmetic; accent dial ("iOS deferred, say so"); alignment stage; Groups membership bus (One Wire Rule, Rim Belongs To The Rail); menu bar status item + Touch Bar (missing from PR #102); four appearance variants + stock AppKit/SF Symbols mandate.
- Point don't duplicate: scope note under H1 with absolute path to phone's DESIGN.md; per-section one-liners where phone owns newer authority (instrument hues, instruments-don't-theme, One Case, sync surfaces). Emitter field: name audiout-shared source, never restate constants.
- Documenter agent: YES, AFTER the build (its doctrine: "ground truth is the shipped artifact"; input contract "existing DESIGN.md path means update"). Hand it PR #102's file as existing input; run per-surface into scratch to fit maxTurns 30.

## Light mode paperwork (if light flips)
- PRODUCT.md:92 "Light mode is the Circuit theme" = BRAND COMMITMENT; needs the owner's explicit sign-off.
- Tokens.swift ~20 Circuit rationales: every ratio re-measured against new grounds (the real cost).
- AppTetherColor.swift:475-480 pill alpha 0.28→0.40 BECAUSE Circuit fill #D0CDC3; AppTetherColorTests pins it.
- AppearanceSettingsViewController.swift:336-337 swatches; AlignmentWizardViewController.swift:249 Circuit-banding tint.
- AccessibilitySignalSweepTests.swift:237 asserts canvasHi==canvas in light → SURVIVES.
- Plain truth: Circuit #FBFBF9 vs iOS #FAFAFB near-identical lightness; structure already agrees (flat, edge-weight separation). Only HUE moves. Drop the name "Circuit" (third-party @sumup-oss token set no longer used).

## Options — branch/PR structure
### A: tokens PR to main, then per-surface PRs — viable, right skeleton
### B: long-lived migration branch + sub-branches — NOT recommended (defers all live verification; drifts from main with 9 in_progress entries; one enormous final review)
### C: A + guard avoidance + shared-component ownership — RECOMMENDED
1. PR 1 tokens: complete target set up front (all four variants, measured), new grid constants, contrast test updates, the 3 Swift Figma-comment edits + Tokens.swift pointer fixes. PURELY ADDITIVE.
2. PR 2 docs, Swift-free: delete Figma doc, rewrite AGENTS.md/PRODUCT.md:102, strip 4 plan lines, close 034. Zero Swift → skips Guards 4/6/7.
3. PRs 3-8 one per surface, parallel, consume PR 1 tokens only. Independently live-verifiable.
4. PR 9 light-mode hue flip LAST: re-values scaffolding, deletes superseded, rewrites PRODUCT.md:92, re-measures.
5. PR 10 DESIGN.md by documenter from shipped code.
- HARD RULE: after PR 1, a surface needing a new token adds it to a shared top-up branch every surface rebases on — never its own.
- SECOND collision zone: SharedUI views (DeviceRowView, AppRowView, PopoverColumnGrid) consumed by popover, Groups, wizard. Assign each shared component to exactly ONE surface branch; others depend on it.
- window-snapshot goldens never regenerated → Groups window verified by eye + non-golden harnesses.

## Options — DESIGN.md authoring
- D1 hand-write up front: stale guaranteed; viable as WORK ORDER not as DESIGN.md.
- D2 documenter only: six executors with six readings of iOS → six apps. Not alone.
- D3 BOTH — RECOMMENDED: target spec as work order in dev/notes/; PR #102 kept on branch as "what exists today" input; documenter runs after PRs 1-9.

## Open questions
1. Does PRODUCT.md:92 change (Brand Commitment)? 
2. Accent dial survives? (belongs in Settings slice scope)
3. BrandMark.swift:12 frame 111:2 — in the locked icon file or the abandoned design-system file? If the latter, scripts/Audiout-Hero-1024.svg becomes the only master.

## Files touched
PRODUCT.md, AGENTS.md, ROADMAP.jsonl, DESIGN.md (new), docs/FIGMA-DESIGN-SYSTEM.md (delete), PLAN-BT-SYNC-DRAWER.md, HANDOFF-wizard-v2.md, HANDOVER-popover-critique.md, wizard-stage-v2-spec.md, first-mix-wizard-default-work-order.md, Tokens.swift, PopoverColumnGrid.swift, BTSyncDrawerView.swift, AppTetherColor.swift, AGENTS-HISTORY.md (opt), AppearanceSettingsViewController.swift, AlignmentWizardViewController.swift, tests: AccessibilitySignalSweepTests, AppTetherColorTests, TokenContrastMatrixTests, MembershipWellContrastTests, AlignmentTokenContrastTests.
