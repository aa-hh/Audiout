---
target: main popover screen
total_score: 31
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
timestamp: 2026-08-10T19-19-02Z
slug: udiouterpopoverui-popoverpanelviewcontroller-swift
---
# Critique — Audiouter main popover

Method: dual-agent (A: design review · B: detector/evidence). Target: AudiouterCore/Sources/AudiouterPopoverUI/PopoverPanelViewController.swift (the main popover surface). Evidence: 6 offscreen renders (light/dark × default, meters, connection-states) + source review + deterministic scans. Web detector inapplicable (Swift sources, exit 0 with zero scannable files); browser overlay N/A (native AppKit).

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 4 | Halo rings, live meters, FEED pills, "Didn't respond" pill — best-in-class |
| 2 | Match System / Real World | 2 | One concept, four names: SYSTEM AUDIO / Main Audio / "System" pill / "Selected Devices"; "Feed"/"Redirect" jargon |
| 3 | User Control and Freedom | 3 | Good revert/dismiss paths; no undo for deselect or volume slips |
| 4 | Consistency and Standards | 3 | Grid alignment superb; trailing column named Output/Feed/Redirect across cards; 7 distinct animation durations, only 1 shared token |
| 5 | Error Prevention | 4 | Blocked toggles carry reasons; wizard refuses without audible reference |
| 6 | Recognition Rather Than Recall | 3 | Hollow rail node is the add-speaker control with no label; effective loudness (Main × Group × Device) never shown |
| 7 | Flexibility and Efficiency | 3 | ⌘1/2/3, ⌥-click wizard; no solo (spec §2 promises it), no global shortcuts |
| 8 | Aesthetic and Minimalist Design | 3 | Four permanently disabled slider clusters; orphan SYNC header over empty Bluetooth section |
| 9 | Error Recovery | 4 | Diagnosis panel: plain cause + concrete action + Try Again; selection survives failure |
| 10 | Help and Documentation | 2 | Tooltips exist; nothing teaches the rail interaction to a first-run user |
| **Total** | | **31/40** | **Good** |

## Design Specificity Verdict

Authored, not interchangeable. The gold membership rail (signal-flow spine with filled/hollow nodes, PopoverColumnGrid.swift:393-457), warm surface ladder, halo connection rings, and "thickness = master bus" meter rule read as a mixing console, not a checkbox list. Token file ships light/dark/increase-contrast variants with measured WCAG ratios per hex — verified: raised/well documented 1.186:1/1.251:1, computed 1.187:1/1.253:1.

Gaps: the rail language stops at App Exceptions (colored chips = second dialect); the empty-mix state — where a new user starts — renders the signature rail as a near-invisible thread.

Deterministic scan: web detector found 0 scannable files (native Swift). Manual scans found: 0 NSLocalizedString in either UI target (33+ hardcoded English strings); 0 preferredFont(forTextStyle:) with 9 call sites hardcoding 10/11/12/14pt past the token layer; sub-24pt hit targets (sync chip 18pt, drawer controls 22pt, GroupRowView activate 18pt / chevron 14pt, header "+" 24×22); unlabeled icon-only controls (GroupRowView muteButton, BTSyncDrawerView ± steppers); failure text on panel = 4.48:1 in dark mode (under AA 4.5:1; light passes at 5.27:1); 7 distinct animation durations.

Both assessments independently flagged: orphan SYNC header (PopoverController.swift:1185, all six renders), dashed-placeholder app icon reading as broken, tiny rail-node hit target. Detector-side extra catches the review missed: the 4.48:1 dark failure text, the unlabeled mute/steppers, zero localization. False positives ruled out: BTAlignmentPromptView buttons (titled → AppKit derives labels), fixed 623pt width (deliberate), muteWidth exactly 24.

Unadjudicated visual fact from renders: "Idle Speaker" in connection-states shows a filled gold node but no bold name/ring while "Connected Speaker" with the same node is bold+ringed — possibly a fixture artifact; verify in live app.

## Priority Issues

1. **[P1] No height overflow strategy.** AGENTS.md bans NSScrollView; a realistic fleet + open drawer + diagnosis panels exceeds screen height with unreachable content. Fix: scroll inside the OUTPUT DEVICES card body only, or auto-collapse subsections past a row budget. → /impeccable adapt
2. **[P1] One concept, four names.** SYSTEM AUDIO / Main Audio / "System" pill / "Selected Devices" within 100pt. Fix: "Main Audio" everywhere; keep "Selected Devices" only as the dropdown value. → /impeccable clarify
3. **[P2] Primary action undiscoverable + undersized.** The 11-15pt hollow node is the add-speaker control: no label, no dedicated hover affordance, sub-minimum hit size. Fix: expand transparent hit zone to full 30pt gutter column, ember hover ring on the node, one-time empty-mix hint via existing card-note slot. → /impeccable onboard
4. **[P2] Accessibility/contrast cluster.** Unlabeled muteButton + ± steppers; diagnosis dismiss ✕ 9.5pt tertiary glyph (small AND low contrast, no device context in label); dark-mode failure text 4.48:1; 22pt drawer controls; zero localization infrastructure. → /impeccable harden
5. **[P3] Render noise.** Orphan SYNC header over empty BT section (gate columnTitle on non-empty rows); four disabled slider clusters on non-controllable rows; dashed placeholder icon reads as broken. → /impeccable polish

## Persona Red Flags

**Alex (power user):** no overflow plan for a 12-speaker fleet; no solo — "just the office for a second" is 5 unchecks; disabled sliders can't pre-stage volume.

**Sam (VoiceOver/keyboard):** genuinely well served (composed row labels, spoken sync offsets, blocked-reason help text). Red flags: ~5 elements × 7 rows to traverse with no accessibilityCustomActions; "Dismiss" ×2 ambiguous with multiple failures; VOLUME/FEED/SYNC headers visual-only; muteButton/steppers unlabeled (B-confirmed).

**Priya (first-time multi-room user):** wall of 3 cards, ~30 controls, nothing says "click the circle to add a speaker"; four names for one concept; SYNC header labels a column with zero rows directly above "Connect a Bluetooth device…".

## Cognitive load

3/8 failures: chunking (6 undifferentiated AirPlay rows, selected not floated), >4 options per decision point (~28 interactive elements in one card), working memory (sent volume = Main × Group × Device, product never shown).

## Minor Observations

- Diagnosis dismiss ✕ lacks device name in a11y label unlike siblings (ConnectionDiagnosisView.swift:282).
- Empty meter track under idle app rows reads as underline decoration.
- Diagnosis fonts literal 11pt, dodging Tokens.Font (ConnectionDiagnosisView.swift:121,126) — part of the 9-site hardcoded-size set.
- Open/close fades use 0.16/0.12; window resize 0.2; collapse token 0.15 — one motion system, four clocks.
- Music-app red tether chip collides with failure-red family at pill scale.

## Questions to Consider

1. If the rail is the signature, should the empty rail BE the onboarding instead of disappearing?
2. At 623pt × 3 cards × 3 tabs, is this honestly a window — would pin-by-default serve better than popover transience?
3. Where is the hierarchy of habit — most-used speakers first — in a product promising "my rooms, instantly"?
