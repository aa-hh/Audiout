# PLAN — Accessibility remediation (from the 2026-08-01 audit)

**Inputs:** [`docs/accessibility/A11Y-GOLD-STANDARD.md`](../accessibility/A11Y-GOLD-STANDARD.md)
(the rubric) · [`docs/accessibility/A11Y-AUDIT-2026-08-01.md`](../accessibility/A11Y-AUDIT-2026-08-01.md)
(97 findings, 8 themes, live checklist).
**Shape:** the audit's causes are systemic, so this plan is organized by **root
cause, not by finding** — six waves, each landing a shared mechanism and then
its adoptions, so ~92 unique findings close through a much smaller number of
changes. Fix-the-root over patch-the-site throughout (e.g. one Edit menu closes
SHL-01 + SET-09; one announce seam closes nine findings).

**Definition of done (maps to the standard):** every Major finding closed or
explicitly ledgered by owner decision · the F2 Accessibility-Inspector audit
runs clean per surface · the F3 VoiceOver end-to-end pass and the B-series
keyboard pass complete for every §2 core task · the six Mac-relevant
Accessibility Nutrition Label features (VoiceOver, Voice Control, Dark
Interface, Differentiate Without Color, Sufficient Contrast, Reduced Motion)
are *truthfully declarable* under Apple's "every common task with the feature
alone" test (H3).

**Workflow constraints honored:** each wave is its own worktree branch off
`main`, merged only with explicit go-ahead after its verification gate; several
unmerged branches (aggregate-device-wave3, audio-routing-exception,
warm-signal-full …) touch the same popover files — **rebase-awareness is part
of each wave's start step**, and waves 1–3 should not start until the currently
hot branches land or an explicit conflict-ownership call is made. Waves are
sequential by default (shared files; the repo's parallel-agents-collide rule),
with per-wave inner parallelism only across disjoint surfaces.

---

## Wave 0 — Shared mechanisms (the kit everything else adopts)

Small, self-contained, no user-visible change yet. All later waves depend on it.

| # | Deliverable | Closes / enables | Notes |
|---|---|---|---|
| 0.1 | `AXAnnouncer` in `AudiouterSharedUI`: `announce(_ text:, priority:, on element:)` generalizing the popover's energize post; one `test_lastAnnouncement` capture seam | Enables Wave 1 (9 findings) | The energize pair (announce-outside-the-RM-gate, wording tests) is the template — promote, don't reinvent. |
| 0.2 | Focus kit: (a) `FocusPreservingRebuild` helper — capture first-responder identity (row id + child control) → rebuild → re-promote + post `.layoutChanged` with the element; (b) seed-on-open convention (`makeFirstResponder` of the first meaningful control; macOS 26 `accessibilityDefaultFocus` where available); (c) `reseedKeyboardFocusIfLost()` for pane-swap hosts | Enables Wave 2 (12 findings) | `promoteFirstResponder(toAppRow:)` (PopoverController:2565) is the proof the pattern works here. |
| 0.3 | **Edit menu** in `installMainMenu` (Undo/Redo/Cut/Copy/Paste/Select All, nil-targeted) + F5 assertion + rewrite the stale "No main menu" AGENTS bullet | SHL-01, SET-09, SHL-09 | ~12 lines; unblocks every text field app-wide. Do first — it is the cheapest Major in the audit. |
| 0.4 | Slider unit helper `bindAXValue(slider:formatter:)` setting `accessibilityValueDescription` from the same formatter as the visible label, on init + change | SET-01, ROW-12 | One helper, five sliders. |
| 0.5 | Sweep test: "every titled control's AX name contains its visible title" over headlessly-instantiated surfaces (+ per-segment/tab image assertions) | Guards T3 forever; SET-13's core | This is the test that would have prevented SET-02/POP-05/GRP-10 from shipping. |

**Gate:** unit tests only (Guard 4). No live items.

## Wave 1 — Announce everything (theme T1 → criterion A4/4.1.3)

Adopt 0.1 at every mutation choke point. Wording lives next to the state
change; every announcement gets a wording assertion via the seam.

- **Popover** (POP-01, POP-07/ROW-18): diagnosis mount (high priority —
  "Couldn't connect to ⟨device⟩. ⟨headline⟩"), silence-fallback banner both
  edges, note-slot resolved-text changes, debounced device set changes, app
  route add/remove, membership auto-swap (`flashRow(announcing:)` — fires even
  under Reduce Motion).
- **Onboarding** (ONB-01): diff-and-announce in both row `update()`s
  ("System Audio allowed" / "…denied — Open Settings to fix", high for
  denials), banner re-word + "All permissions restored".
- **Settings** (SET-03, announce-halves of SET-04/05/07): Apply armed /
  "Reconnecting speakers…" (high) / completion (kept visible until next
  change); hint rewrites on value change; "Removed ⟨app⟩"; launch-at-login
  failure line.
- **Groups** (GRP-09): "No matches"/"N icons shown", refused-rename
  restoration, pane-swap announcement, `sheet.title = "New Group"`.
- **Shell** (SHL-10): "Disconnecting from speakers" on the quit indicator.

**Gate:** wording tests green; spot VoiceOver session on popover + onboarding
(checklist items 20, plus 4/5 partially).

## Wave 2 — Focus discipline (theme T2 → G2/G3/B3/B7)

The Blocker-adjacent wave. Adopt 0.2 everywhere; unify focus and selection.

- **Popover** (POP-02/03/04, SHL-03, ROW-03): seed first meaningful control in
  `popoverDidShow`; wrap `rebuild()` in `FocusPreservingRebuild`; implement
  `cancelOperation` → `performClose` as the guaranteed Esc; `NSApp.deactivate()`
  on close with no key window; `didRequestSelect` defers rebuild one tick +
  promotes (the ↑/↓ path's own pattern); `AppRowView.becomeFirstResponder`
  requests selection + draws a real focus ring; Delete gated on `isSelected`.
  Consider `.applicationDefined` + manual Esc if the live VO+Esc check trips
  the platform bug (standard G2).
- **Groups** (GRP-01/02/03): `reseedKeyboardFocusIfLost()` from `swapContent`
  and after `buildRows`; `cancelRename` → `nextValidKeyView` (never nil);
  `show(groupID:)` guards the name write on `currentEditor() == nil`;
  `buildRows` diffs via `row.apply(...)` instead of razing; icon-picker
  presenters seed the search field and restore the well on close.
- **Settings** (SET-05): promote same-index control after `rebuildList`; seed
  the incoming pane's first key view on tab switch.
- **Onboarding** (ONB-02/08, SHL-07): idempotent `update()` (early-return on
  equal state) in both row classes; transition guard in
  `SetupModel.refreshStatuses()`; focus handoff when a focused accessory is
  genuinely replaced; seed first ungranted Allow in `present()`; steal key only
  when nothing else holds it; never re-center a visible window.

**Gate:** headless focus tests (first responder survives rebuild/pane-swap/
toggle — the GRP-01 test shape) + **live checklist items 1–2, 8–11, 21**
(keyboard entry, Esc behavior with VO, Groups collapse sweep). This wave
graduates most Needs-live-confirm findings.

## Wave 3 — Names, labels, truthful structure (themes T3+T6 → A1/A3/A5/A6/A9/F1)

- **Delete overriding labels; derive from state in one place:** SET-02 (drop
  both overrides), GRP-04 (stable device-name checkbox labels), POP-10
  (volume out of the row label; `configureAccessibility` from `masterChanged`;
  fix "Main Out"/"Audio Out" literals), ONB-04 ("Allow ⟨permission⟩"),
  GRP-10/GRP-13, POP-05 (lead with visible text).
- **Speak the missing states:** ROW-01 (debounced "playing" on main-mix
  signal), ROW-02 ("unavailable" suffix), POP-11 ("connecting" on Main-Out
  value), SHL-02 (status item: "Audiouter — streaming/muted/idle" composed in
  pure `MenuBarStatus`; thread mute through to drain the arc; **wire or delete
  `StatusRoutingIndicator`** — decide, don't leave the orphan).
- **Truthful containers:** POP-08 (cards → labeled `.group`s), POP-09 (banners
  → group with single-spoken copy; both classes), ROW-11 (GroupRowView adopts
  the DeviceRowView contract wholesale: `.group`, value carries "muted",
  "Mute ⟨group⟩", shared pill treatment, "64%"), SET-08 (radio groups),
  ROW-15 (decide: rows are containers; decorative children —
  icons/readouts/pills/badges — explicitly out of the tree; fix AppRowView's
  comments), SET-11, GRP-07 (sidebar: nil icon descriptions, "unavailable"
  value + visible annotation), GRP-11 (`accessibilityTitleUIElement` pairs),
  ONB-05/07, SHL-06 (backing window out of AX).
- **Hints and help:** SET-04's association half (`setAccessibilityHelp` in
  `SettingsForm.row` + the `setHint` helper), ROW-17, ONB-06 (Esc on the
  sheet), SET-07's visible-error half.

**Gate:** the 0.5 sweep test green across all surfaces; Inspector static audit
(checklist 39) expected warning-free for labels/roles; live VO row-traversal
(items 26–30) settles ROW-15's contract question.

## Wave 4 — Visual floors: the light-mode re-tune (theme T5 → C1/C2/C3/C4/C6, D2/D4)

The token file's own "Wave-5 sweep" flags mark most of this work; the audit
supplies the measured targets. **This wave changes shipped pixels — it needs
the owner's design sign-off (Warm Signal is owner-locked), and snapshot PNGs
will churn.** All measurements are in the audit's contrast tables; every
re-tune must be re-measured against the *actual* rendered surface (`canvas`
for popover instruments — the stale-`panel`-reference lesson, ROW-09).

1. **Token re-tunes** (one coordinated `Tokens.swift` pass + rationale
   updates + lock-test updates): light `ringConnected` (→ ≥3:1 vs canvas);
   light `dotSocket`/gold pair (→ ≥3:1 with a real IC delta); `meterTrack` +
   light fill stops (→ ≥3:1 at the moving edge); a dedicated ≥3:1 non-member
   node rim token; `faderRim` decision (fix or ledger); warm
   `textSecondary`/`textTertiary` tokens at ≥4.5:1 with IC variants,
   repointing the aliases (VIS-01 — also resolves ONB-10's surface).
2. **State-composite honesty:** ROW-06/VIS-03 — decide disable-vs-visible
   (see Decisions) and implement so no *enabled* control renders under 3:1;
   ROW-10/VIS-02 — `AppTetherColor` text/chip register split (or chip-only
   tint), test floor updated to match.
3. **Follow-System accent floor:** VIS-04 — escape-valve luminance lift +
   an IC step inside `systemAccentColor(in:scale:)`.
4. **DWC:** ROW-05/VIS-08 — read `shouldDifferentiateWithoutColor` via the
   existing observer infrastructure (+ `test_` seam); non-hue armed cue
   (hollow-vs-solid socket form) and rail-segment treatment in light.
5. **CTA contrast:** ONB-03 — luminance-derived ProminentButton title color +
   the all-accents ≥4.5:1 sweep test.
6. **Targets:** ROW-08 first (the one outright 2.5.8 failure — group
   activate/chevron), then the padded-hit-area constants (POP-06, ROW-13,
   SET-10, GRP-12) — glyphs unchanged, frames grown.
7. **Typography:** VIS-09/SET-12 — raise informational 8.5/10 pt uses to
   ≥11 pt (needs the §3.5 no-reflow renegotiation — see Decisions) and run
   the text-style adoption spike through the one `Tokens.Font` seam; add the
   1.3× layout test.
8. **Ledger resolution:** GRP-05 (owner re-confirms or adopts the costed
   stock-semantic step-up), GRP-06's picker-ring drift (system treatment on
   the system surface), VIS-13/ROW-16 items — each **fixed or ledgered
   explicitly**, none left as code-comment-only.

**Gate:** updated contrast lock tests green (now measuring real surfaces);
snapshot re-approval; live checklist items 31–38 (light-mode measurements, DWC,
IC re-stamp, text scaling).

## Wave 5 — Keyboard reach & platform polish (theme T4 + T8 residue)

- SHL-04: `NSAccessibilityCustomAction` "Show menu" on the status button.
- SHL-05: opt-in configurable global hotkey (Settings › General) invoking the
  existing toggle path — the spec already lists global shortcuts under
  Later/nice-to-have; this promotes it with an accessibility rationale.
- GRP-08: icon-picker grid arrow navigation (one Tab stop).
- SET-06: `ThemeTileButton` focus-ring mask; ROW-20 if the live check confirms
  the fader-thumb ring mismatch (trace the drawn thumb).
- RM stragglers: ONB-09 (window resize honors RM), ROW-14 (meter snap+stop on
  mid-session flip, + the missing `test_reduceMotionOverride` seam).
- VIS-12 standardization (after the item-35 live test decides
  observer-vs-appearance), VIS-10 (tiles resolve real tokens under forced
  appearance; badge literals into Tokens), ROW-21 (shared wash constants).

**Gate:** re-run checklist items 1, 3, 9, 14, 35–36; Voice Control spot pass.

## Wave 6 — Process hardening (theme T7 → F5/H1–H4)

- **F5 assertions ride every earlier wave** (that's the rule, enforced in
  review); this wave sweeps the remainder: SET-13, POP-13, ONB-11, ROW-19
  (incl. GroupRowView label content, mute-label flip actually asserted,
  focus-ring mask geometry, ProminentButton contrast sweep).
- Doc corrections not already landed with their fixes: SET-14 naming, POP-12
  (delete-or-annotate the dormant refusal machinery), remaining AGENTS drift.
- **SPEC.md gains an Accessibility section** referencing the gold standard as
  the acceptance bar for all UI work (H1); AGENTS.md UI-conventions bullet
  pointing at it.
- **Optional (recommended):** a minimal XCUITest target running
  `performAccessibilityAudit()` on the popover and Settings — Apple's only
  sanctioned automated audit; new infrastructure, so explicitly opt-in.
- **H3 evidence sheet:** map each Nutrition-Label feature to its checklist
  items + test names, ready for App Store Connect whenever distribution
  happens.
- §5 ledger updated with every decision taken in Wave 4.

**Gate:** full live checklist (all 42 items) as the release-readiness pass;
Guard 4 green; the standard's §4 audit loop re-run "clean or ledgered".

---

## Decisions needed from the owner (recommended option first)

1. **Muted-unconnected fader honesty (ROW-06).** (a) **Keep it operable and
   render ≥3:1 muted-treatment tokens** — preserves "you can pre-set volume
   while connecting", costs a small design change; or (b) disable during
   connecting/failed — simpler, honest, but removes a capability. Recommend (a).
2. **8.5 pt micro-labels (VIS-09).** (a) **Raise informational uses to ≥11 pt
   and re-negotiate the §3.5 no-reflow line** (sublabel rung grows ~2 pt) —
   compliant, small visual shift; or (b) keep 8.5 pt and ledger it, relying on
   AX duplication — leaves low-vision non-VoiceOver users behind. Recommend (a).
3. **Groups stock-text ledger (GRP-05).** (a) **Adopt the costed step-up**
   (tertiary→secondary, caption-informational→label) — stays inside stock
   semantics, closes the worst ratios; or (b) re-confirm the ledger as-is —
   zero work, keeps 1.87:1 subtitles. Recommend (a); it was originally locked
   against *warm-tinted text*, which (a) does not introduce.
4. **Text-style adoption scope (VIS-09).** (a) **Full `preferredFont`
   migration through `Tokens.Font`** — real Text-Size support, more layout
   QA; or (b) floor-only fixes now, styles later — cheaper, defers the
   platform mechanism. Recommend (a) at Wave-4 scope, (b) acceptable if Wave 4
   must stay small.
5. **Global hotkey (SHL-05).** (a) **Ship the opt-in hotkey in Wave 5** — real
   keyboard-access win, small scope, already spec'd as Later; or (b) defer —
   Ctrl-F8 remains the only path. Recommend (a).
6. **`StatusRoutingIndicator` (SHL-02).** (a) **Wire it** (the documented
   glance dot becomes real); or (b) delete it and its tests + the doc
   paragraph. Either is honest; recommend (a) — the doc, tests, and design
   intent all already exist.
7. **Nutrition Labels (H3).** When distribution is on the table: declare the
   six features only after the Wave-6 full checklist passes. No action now
   beyond keeping the evidence sheet current.

## Sizing & sequencing summary

| Wave | Size | Risk | Blocked by |
|---|---|---|---|
| 0 kit | S–M | none (additive) | — |
| 1 announce | M | low | 0 |
| 2 focus | **L** | medium (interaction changes; live gate) | 0; hot-branch landings |
| 3 names/structure | M–L | low | 0 (0.5 sweep test), ideally 1 |
| 4 visual re-tune | M | medium (pixels; owner sign-off; snapshots) | decisions 1–4 |
| 5 reach/polish | S–M | low | 2 (focus kit), item-35 live result |
| 6 process | M | none | all prior (sweeps their remainder) |

Waves 1–3 are pure additive accessibility with test coverage — low regression
risk and immediately felt by VoiceOver/keyboard users; they deliver the bulk of
the Major-finding closures. Wave 4 is where design judgment concentrates.
Nothing in this plan touches audio routing, backends, or the engine.
