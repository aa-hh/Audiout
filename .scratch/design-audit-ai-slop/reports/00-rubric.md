# AI-slop audit rubric — Audiout Mac app, pre-launch first pass

## What "AI slop" means for this audit

Merged from three sources: the Impeccable craft floor ("Refuse" list in
/Users/alechenderson/.claude/skills/impeccable/reference/craft-floor.md), the Impeccable product
and native slop tests (reference/operate.md "The product slop test", reference/ios.md "The iOS slop
test" read as a Mac test, reference/audit.native.md §4 "System drift"), and the unslop-ui tells
catalog (/Users/alechenderson/Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin/4c8d4460-7d8f-4e0a-b707-4f1f8f7df7ec/ad8dafcd-010d-4a41-ae06-402ff7b6e60f/skills/unslop-ui/references/tells.md).

The one-line definition: **a tell is an unspecified default.** Something is on screen because it is
what "good UI" auto-completes to, not because someone chose it for this product and can say why.
Impeccable's product test: the failure mode of product UI is strangeness without purpose —
over-decorated buttons, mismatched form controls, gratuitous motion, display fonts where labels
should be, invented affordances for standard tasks. The bar is earned familiarity: a fluent Mac
user trusts every screen without pausing at an off-spec control.

A documented decision (DESIGN.md, PRODUCT.md, a code comment naming the reason) is not slop.
A documented decision that STILL reads as a template to a viewer who cannot read DESIGN.md is
reported at P3 with the label "chosen, but reads as a tell".

## Tell families — check every one on every screen

**A. Scaffolds and containers**
- Same-size cards of icon + heading + text as the page structure; nested cards; "a box around everything".
- Kicker / eyebrow label above a heading (Impeccable: an outright ban, no brief earns it back).
- Section numbers (01 / 02 / 03) where the sequence carries no information.
- Hero-metric template: big number, small label, supporting stats, accent.
- A modal or sheet for a task that needs neither interruption nor protected focus.
- Everything centered, endless whitespace; every section the same weight, nothing leading the eye.

**B. Surface habits**
- Gradient text; gradients on several surfaces; glass or blur as decoration rather than one specific effect.
- Unprompted glow: zero-offset colored halos, neon `0 0 N` shadows, especially on dark grounds.
- One large radius applied uniformly; pill buttons as the only button shape; rounded corners on everything.
- A colored left/right stripe above 1 px on cards, rows, callouts, alerts.
- Hard zero-blur offset shadows outside a world that chose neobrutalism.
- Sparklines, progress rings, soft-shadowed rounded rectangles standing in for content.
- Monospace as a costume for "technical" rather than for data, code, or measurement.
- Emoji or Unicode glyphs standing in for an icon; mixed icon sets (anything that is not SF Symbols or the app's own drawn marks).
- Decorative motion: the same entrance on every element, hover-grow, scattered effects instead of one authored moment; Reduce Motion ignored.
- Stock illustration, clipart, generic 3D.

**C. Native conformance (macOS / AppKit)**
- Platform controls reinvented for flavor: custom toggles, checkboxes, popups, sliders, segmented controls, scrollbars, text fields where stock AppKit exists and nothing the user would thank you for is gained. (Custom drawing that DESIGN.md names and justifies is allowed; check the execution instead.)
- Web-shaped buttons; hover-only affordances with no click or keyboard path.
- Custom global navigation, mixed navigation metaphors, off-platform sheets, alerts or dialogs, toolbars that are not toolbars.
- Hand-rolled materials where a system material is expected, or a system material used purely as decoration.
- Type: a display face where a label belongs; sizes off the platform scale with no reason; uppercase transforms; kerning tricks.
- System drift: a decorative pattern repeated across screens that conflicts with the product, the platform, or DESIGN.md.

**D. Copy on screen** (rules from /Users/alechenderson/.claude/skills/audiout-copy-review/SKILL.md — read it)
- Banned words (seamless, effortless, elevate, supercharge, streamline, robust, empower, harness, ...), binary contrasts ("not X, it's Y"), colon reveals, throat-clearing, importance puffery, trailing "-ing" analysis, em dashes in UI strings, pep talks, an over-personified app.
- Hero clichés: "Transform your X", "Your X, reimagined", "Unleash".
- Errors with no next action; empty states that do not point forward; a bare OK; Title Case labels; terminology drift against the copy-review table (speaker not device, scene not group in user-facing text, Main Audio, Try again not Retry, Add scene not New/Create).

**E. Layout quality**
- Text that overflows, clips or truncates with real strings; padding and gap values with no scale behind them; near-miss alignment; inconsistent gutters between columns.

## Pinned by the brief — NOT slop (flag only if the execution is off, or at P3 "chosen, but reads as a tell")

- Gold (#E8B84B dark / #A67C1E light) for audio state, calls to action, selection and completion; the Warm Signal cool-neutral chassis; one flat light ground with separation by edge weight.
- ProminentButton: gold pill, dark ink, both appearances (owner's call).
- Radius ladder 10 / 16 / 26 pt, plus 12 pt popover shell and 10 pt grouped section.
- The alignment wizard's fixed-dark stage and the EQ scope: instruments never theme.
- Five permission identity hues plus the Bluetooth brand blue, fenced to first-run Setup.
- The muted periwinkle and the equalizer green, fenced to the device row.
- Micro label 10 pt / 600 sentence case; readouts in tabular digits; the "no uppercase transform" rule.
- Menu section headers with indented entries (owner's call, departs from the HIG on purpose).
- The Metal emitter field behind the licence gate (brand mark).
- ClashDisplay for the product name only.
- The hybrid voice: console nameplates on chrome ("MAIN OUT"), plain speech on anything the user acts on.
Read DESIGN.md (repo root) and the "Brand Commitments" section of PRODUCT.md before judging; they are
the record of what was chosen.

## How to work

1. Read DESIGN.md and PRODUCT.md "Brand Commitments", then the AGENTS.md nearest every folder you read.
2. Look at every screenshot in your slice (use Read on the PNG). Then read the source that draws it.
   Every finding is verified in source and cites file:line. A screenshot impression you cannot
   anchor in code goes in a separate "unverified impressions" list, never in the findings.
3. Read-only. Do not fix anything, do not write into the repo, do not run builds or tests.
   The screenshots were rendered for you already; do not regenerate them.
4. This pass is AI-slop only. Do not re-audit accessibility, performance or general HIG conformance.
   Contrast only where a slop tell causes the problem.
5. Noise budget: ten sharp findings beat forty weak ones. Every finding says why it reads as machine-made.
6. Report positives too: three to six things that read as a person's decision, one line each.

## Finding format — exact, findings from four agents are merged verbatim

```
[P1|P2|P3] <screen / state> — <file:line> — <screenshot filename or "no screenshot">
  tell:  <family letter + short name, e.g. "B glow", "C reinvented control", "D copy">
  now:   <what is on screen / in code, concrete>
  why:   <why it reads as AI-made or template, one or two sentences>
  fix:   <specific replacement; for copy, the exact new string>
```
P1 = a stranger clocks it as AI-made at a glance, or it breaks native trust.
P2 = noticeable on a second look, or a pattern repeated across screens.
P3 = polish, or "chosen, but reads as a tell".

## Report shape

1. Verdict in two sentences: does this slice read as a person's decisions or as a template? Name the single highest-impact change.
2. Findings, P1 first, in the format above.
3. Repeated patterns across the slice (one short paragraph each).
4. Positives.
5. Unverified impressions (screenshot-only, no code anchor).
6. Screens or states in your slice you could NOT see (no screenshot, no way to render), listed so nothing goes unaudited silently.
