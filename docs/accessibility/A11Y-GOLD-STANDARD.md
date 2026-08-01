# Audiouter Accessibility Gold Standard (A11Y-STD v1.0)

**Status:** Draft for the 2026-08-01 audit · **Owner:** accessibility audit session
**Conformance target:** WCAG 2.2 Level AA equivalence for non-web software (per W3C
WCAG2ICT), **plus** a macOS platform-excellence layer (Apple HIG Accessibility +
NSAccessibility API correctness) that WCAG alone does not capture.

This is the rubric Audiouter is judged against — by this audit, and by any future
UI change. Criteria carry stable IDs (`A1`, `B3`, …); findings, tests, and plans
cite them. Update the rubric only by appending or revising criteria explicitly,
never by renumbering.

---

## 1. Why these sources

| Source | Role here |
|---|---|
| **WCAG 2.2 (W3C Recommendation, Oct 2023; errata 2025-06 / 2025-10)** | The operative interoperable standard — errata only, no new success criteria. AA is the level regulators and buyers reference. WCAG 3.0 (Mar 2026 Working Draft; Rec ≥2028) is monitor-only. |
| **WCAG2ICT (W3C Group Note, edition of 2025-12-11; actively maintained)** | The official interpretation of WCAG 2.2 for **non-web software** — how each Success Criterion applies to a native desktop app, coordinated with the EN 301 549 rewrite. Key sentence for AppKit: programmatic determinability "is best achieved by using the accessibility services of platform software" — 1.3.1/4.1.2 conformance on macOS *means* correct NSAccessibility exposure. |
| **EN 301 549 (v3.2.1 operative; V4.1.1 — WCAG 2.2-based — expected in the EU Official Journal ~Oct 2026)** | The EU standard. Clause 11 (software) imports WCAG at AA; **11.5** interoperability with assistive technology; **11.7** user-preference respect (follow platform settings for color, contrast, font, focus); **5.4** don't disrupt platform accessibility features; clause 12: accessible documentation & support. This rubric already targets the V4.1.1 superset. |
| **European Accessibility Act (applies since 2025-06-28; enforcement live — first FR/SE cases 2025–26)** | Legal driver. A third-party consumer desktop utility is **not a listed EAA category**; the concrete hooks are the seller's own EU storefront (an in-scope e-commerce service), broader member-state transpositions (FR/IT/ES), and the microenterprise exemption (<10 staff, <€2M). Treated as: *comply with EN 301 549; the legal-exposure question then answers itself.* |
| **Section 508 (US)** | Federal procurement only — WCAG AA core plus software chapters 502 (AT interop) / 503 (user preferences), which mirror EN 11.5/11.7. Relevant as VPAT/ACR material for enterprise buyers; no consumer obligation. |
| **Apple HIG — Accessibility + NSAccessibility protocol docs** | The platform contract: VoiceOver, Full Keyboard Access, Voice Control, Switch Control, and the system display settings (Reduce Motion, Increase Contrast, Reduce Transparency, Differentiate Without Color, Text Size, Hover Text, Zoom). For a native app this layer is *mandatory* quality, not garnish — and it is where most native apps actually fail. macOS 26 added `accessibilityDefaultFocus` (sanctioned initial-VoiceOver-focus pattern), Magnifier for Mac, Braille Access, and Accessibility Reader; macOS 27 adds natural-language Voice Control and Liquid Glass contrast refinements with user-adjustable transparency. |
| **App Store Accessibility Nutrition Labels (Apple, since 2025; macOS product pages included; voluntary as of 2026-08, mandatory "eventually" per Apple)** | Self-declared per-feature support (VoiceOver, Voice Control, Dark Interface, Differentiate Without Color, Sufficient Contrast, Reduced Motion, …). Declaration rule: **every common task completable using that feature alone**; inaccurate labels are an App Review 2.3 (accurate metadata) violation. Apple's per-feature evaluation criteria are the closest thing to a published native-app audit protocol — this rubric is the evidence base for truthful declarations. |

**Interpretation rules:**
- Where WCAG and the platform idiom conflict in mechanism, the platform idiom
  wins as long as the WCAG *outcome* is met (WCAG2ICT's own stance).
- WCAG2ICT scopes 2.4.1, 2.4.5, 3.2.3, 3.2.4 and 3.2.6 to a "set of software
  programs" — a set so narrowly defined that a single app **automatically
  satisfies** them. Audiouter keeps their *spirit* as quality criteria (E3, E5)
  while recording the formal auto-pass.
- 2.4.2 Page Titled applies as "the software (and each window) is titled" —
  folded into G3.
- Web-specific or inapplicable criteria are recorded in the N/A ledger with the
  WCAG2ICT rationale rather than silently dropped.
- Pixel-framed measures (2.5.8, 1.4.10) carry WCAG2ICT's CSS-px framing with no
  native substitution; this rubric adopts the practitioner convention **1 AppKit
  point ≈ 1 CSS px at default scaling**.

---

## 2. Severity model

Severity is **user impact on core tasks**, not standards pedantry. Core tasks:
open the popover · read device list & states · add/remove a device from Main
Audio · adjust volume / mute (device, group, Main) · switch the Main Audio
destination · create/edit/activate a group · add an app and route it · exclude
an app · complete first-run onboarding · change a setting · quit.

| Severity | Definition |
|---|---|
| **Blocker** | A user relying on an accessibility feature (VoiceOver, keyboard-only, Switch Control, a display setting) **cannot complete a core task at all**. |
| **Major** | Core task completable but substantially degraded, or a clear WCAG A/AA failure with only an awkward workaround. |
| **Minor** | Friction or inconsistency; AA edge case; SHOULD-level miss. |
| **Advisory** | Beyond-AA polish (AAA, HIG nice-to-have), or forward-looking hardening. |

**Verification methods** cited per criterion:
`[S]` static code inspection (this audit) · `[T]` automated test assertion
(existing/new harness — rows and windows are instantiable headlessly) · `[L]`
live manual check (VoiceOver / Full Keyboard Access / Accessibility Inspector /
Voice Control), owed as a checklist.

---

## 3. The criteria

### A. Assistive-technology semantics (VoiceOver, Switch Control, Voice Control)

| ID | Requirement | Verify | Sources |
|---|---|---|---|
| **A1** | Every interactive element exposes an accurate **role, label, and (where stateful) value** through NSAccessibility. Labels are human phrases describing purpose, never SF Symbol names or internal jargon. MUST | S,T,L | 4.1.2; HIG |
| **A2** | Every **custom-drawn view** either carries full AX semantics (informational: label/value that mirror the pixels) or is explicitly removed from the AX tree (decorative). No custom view ships in the default "unlabeled group/image" state. MUST | S,T | 1.1.1, 4.1.2 |
| **A3** | Composite rows speak as **one coherent element**: each information channel (identity, membership, volume, connection, live-signal state, refusal reason) is spoken **exactly once**, in a stable label/value/hint contract, with no duplication or contradiction — and the row's child controls remain individually reachable and operable by the VoiceOver cursor. MUST | S,T,L | 1.3.1, 4.1.2 |
| **A4** | **State changes a sighted user sees are announced**: banners appearing/clearing, connection failure/recovery, async results, destructive completions, devices appearing/disappearing while a surface is open. Use `.announcementRequested` (or focus-carrying layout notifications) with sensible priority — polite by default, high only for failures. MUST | S,L | 4.1.3 |
| **A5** | Adjustable controls (sliders) expose **value in human units** ("64 percent"), support AX increment/decrement, and their label names the thing being adjusted ("HomePod volume", not "slider"). MUST | S,T,L | 4.1.2, 1.3.1 |
| **A6** | Icon-only buttons and state-bearing images have labels describing the **action or state**, not the glyph; images whose rendering encodes state (variable-value symbols, filled-vs-outline, tint) expose that state in their AX description too. MUST | S,T | 1.1.1, 4.1.2 |
| **A7** | The AX hierarchy mirrors the visual structure: cards/sections expose their titles as navigable containers, order matches reading order, and nothing visible is missing from the tree (nor anything invisible present in it — collapsed content is not exposed). MUST | S,L | 1.3.1, 1.3.2 |
| **A8** | Meters and purely-visual live signals have an **equivalent non-visual channel**: the information they carry (playing/silent, level, connection form) is available via row value/state wording. Continuous per-frame values need not be spoken continuously — the *state* must be. MUST | S,T | 1.1.1 |
| **A9** | **Voice Control targeting works**: the spoken label of every control starts with (or equals) its visible text, so "Click ⟨what I can read⟩" resolves. Icon-only controls carry the name a user would naturally say. MUST | S,L | 2.5.3; HIG |
| **A10** | Nothing is **hover-only or drag-only**: any affordance revealed on hover (edit badges, tooltips, hover washes) has a permanent or keyboard/AX-visible equivalent, and hover-revealed content is dismissible/persistent per 1.4.13. MUST | S,L | 1.4.13, 2.1.1 |

### B. Keyboard operability

| ID | Requirement | Verify | Sources |
|---|---|---|---|
| **B1** | **Every function is operable keyboard-only**, end to end — including *entering* the app: the status item must be reachable via the system's menu-bar keyboard access, and every surface reachable from there without a pointer. MUST. A user-configurable **global shortcut to open the popover** SHOULD exist (menu-bar traversal is slow and unknown to most users). | S,L | 2.1.1; HIG |
| **B2** | **No keyboard traps.** Esc dismisses the popover, panels, sheets, and pickers; ⌘W closes windows; focus never lands somewhere it cannot leave. MUST | S,L | 2.1.2 |
| **B3** | **Focus order is logical** (visual/reading order); opening a surface places initial focus sensibly (first meaningful control); dismissing returns focus/context to where the user was. Tab traversal keeps working after content swaps and rebuilds. MUST | S,L | 2.4.3 |
| **B4** | **Focus is always visible**: no suppressed or clipped focus rings; custom-drawn controls draw the system ring (or an equivalent ≥3:1 indicator); the focused control is never obscured by other chrome. MUST (2.4.13 Focus Appearance: SHOULD) | S,T,L | 2.4.7, 2.4.11 |
| **B5** | **Standard shortcuts exist and are discoverable**: ⌘, Settings · ⌘W Close · ⌘Q Quit, carried on real menu items (main menu and/or status-item menu) so the system can reveal them. No single-character (unmodified) app-wide shortcuts. MUST | S,L | 2.1.4; HIG |
| **B6** | Custom first-responder views implement the full pattern by hand: `acceptsFirstResponder`, Space/Return activation, arrow keys where the visual pattern implies them (grids, lists), and an AX press action. MUST | S,T | 2.1.1, 4.1.2 |
| **B7** | Works under **Full Keyboard Access** (Tab-to-everything), not just default key views — including controls inside rebuilt/swapped content and popover height changes not stranding focus. MUST | L | 2.1.1; HIG |
| **B8** | Any drag/scroll-wheel interaction has a **single-pointer-click and keyboard alternative** (sliders: arrows; reorder: buttons/menu). MUST | S | 2.5.7, 2.1.1 |

### C. Visual: contrast, color, text

| ID | Requirement | Verify | Sources |
|---|---|---|---|
| **C1** | Text contrast ≥ **4.5:1** (normal) / **3:1** (≥18 pt regular or ≥14 pt bold) against its *actual rendered background*, in **both** light and dark appearance, in every state (enabled/disabled/hover/key/non-key). MUST. Known deliberate exceptions are ledgered in §5. | S,T,L | 1.4.3 |
| **C2** | **Non-text contrast ≥ 3:1** for everything a user must perceive to operate: control boundaries, checkbox/switch states, the route-armed dot lit-vs-dark, halo-ring forms, meter fill vs. trough, fader fill/thumb vs. trough, focus indicators, status-item glyph states. MUST | S,T,L | 1.4.11 |
| **C3** | **Color is never the sole channel** for any state: every color-coded distinction (armed gold, failure red, granted tint, streaming accent) also differs by shape, fill, glyph, position, or text — and remains distinguishable under **Differentiate Without Color**. MUST | S,T,L | 1.4.1; HIG |
| **C4** | **Text scales**: adopt `NSFont.preferredFont(forTextStyle:)` so the macOS **Text Size** setting (System Settings → Accessibility → Display; systemwide + per-app since Sonoma, adoption expanded in macOS 26) can reach the app; no informational text below 11 pt; truncated text remains fully available (tooltip, AX value, or wrapping). Layout tolerates ~1.3× text without clipping or overlap. (Apple's Nutrition-Label taxonomy says "Larger Text" is not a Mac label — text styles remain the forward-compatible mechanism; WCAG2ICT scopes 1.4.4 to "the text sizing capabilities of the platform".) MUST-where-platform-supports, else SHOULD | S,L | 1.4.4 (2ICT); EN 11.7 |
| **C5** | Surfaces stay usable under **display zoom and larger text** — fixed-height rows and fixed-width columns must not clip grown content; the popover grows rather than clips. SHOULD | S,L | 1.4.10 (2ICT) |
| **C6** | **Click targets ≥ 24×24 pt** with adequate spacing; small glyph buttons get padded hit areas rather than pixel-tight bounds. (The HIG publishes no normative macOS pointer minimum — 44 pt is the touchscreen rule — so WCAG 2.2's 24×24, read at 1 pt ≈ 1 CSS px, is the defensible desktop floor. 2.5.8's spacing exception applies: an undersized target passes if a 24 px circle centered on it collides with no neighbor's circle.) MUST | S,T | 2.5.8; HIG |
| **C7** | Every custom color ships **light + dark + Increase Contrast variants** with a written contrast rationale (already a house rule for `Tokens`); semantic system colors everywhere else. MUST | S,T | house rule; 1.4.3/1.4.6 |
| **C8** | Information-bearing custom drawing (rails, membership nodes, grain, gradients) either meets C1/C2 on its own or is redundant with a compliant channel. MUST | S,T | 1.4.1, 1.4.11 |

### D. Motion, transparency & system display settings

| ID | Requirement | Verify | Sources |
|---|---|---|---|
| **D1** | **Reduce Motion** suppresses or replaces *every* non-essential animation (blooms, breathing, sweeps, fades, collapse animation), including animations already in flight when the setting flips mid-session. Announcement/state equivalents still fire. MUST | S,T,L | HIG; 2.3.3 (as platform MUST) |
| **D2** | **Increase Contrast** takes effect live everywhere: system controls inherit it; custom tokens resolve their IC variants; measured deltas actually increase. MUST | S,T,L | EN 11.7; HIG |
| **D3** | **Reduce Transparency**: no legibility depends on vibrancy/materials; custom canvases flatten to opaque; text over materials stays compliant when materials vanish. MUST | S,T,L | EN 11.7; HIG |
| **D4** | **Differentiate Without Color** is honored wherever color encodes state (see C3) — verified per-instrument, not assumed. MUST | S,L | HIG |
| **D5** | Nothing flashes more than 3×/second; no strobe-like meter or ring behavior even at pathological signal levels. MUST | S | 2.3.1 |
| **D6** | The app **never disrupts platform accessibility features**: no swallowing of AX events, no fighting VoiceOver focus, no key-event monitors that break Full Keyboard Access or Switch Control scanning. MUST | S,L | EN 5.4/11.6.2 |

### E. Understandable: labels, errors, status

| ID | Requirement | Verify | Sources |
|---|---|---|---|
| **E1** | Every control has a visible label or an unambiguous context; instructions never rely on sensory characteristics alone ("the gold dot", "on the right") without a named equivalent. MUST | S | 3.3.2, 1.3.3 |
| **E2** | Errors are **identified in text, explained, and carry a recovery action** — and reach assistive tech (A4). Failure copy names the device/app concerned. MUST | S,T | 3.3.1, 3.3.3 |
| **E3** | **Consistent identification**: the same concept carries the same name and iconography on every surface (Main Audio, Selected Devices, groups, exclusion). MUST | S | 3.2.4 |
| **E4** | **No surprise context changes** on focus or input: focusing a row doesn't activate it; picking a value doesn't navigate; anything that *does* move audio is an explicit activation. MUST | S,T | 3.2.1, 3.2.2 |
| **E5** | Help/recovery affordances live in consistent places across surfaces (diagnosis panels, "Open System Settings", hints). SHOULD | S | 3.2.6 (2ICT) |
| **E6** | Permission and onboarding copy explains consequences in plain language before the OS prompt fires; state wording ("Requested", "Granted") matches what the OS will show. MUST | S | 3.3.2; HIG |

### F. Robustness: AX API correctness & regression safety

| ID | Requirement | Verify | Sources |
|---|---|---|---|
| **F1** | Roles are truthful (a thing that acts like a button *is* `.button`), AX frames match hit areas (VoiceOver click-through lands), and parent/child relationships are consistent — no orphaned or duplicated elements. MUST | S,L | 4.1.2 |
| **F2** | **Accessibility Inspector audit runs clean** (no warnings) on every surface: popover, Settings (all tabs), Groups window (all panes), onboarding, control-panel shell, status item. MUST | L | HIG |
| **F3** | **VoiceOver end-to-end passes** for every core task (§2 list), scripted as a repeatable checklist. MUST | L | HIG |
| **F4** | **Switch Control and Voice Control spot-passes** for the popover's core loop (derives from A/B correctness but is verified, not assumed). SHOULD | L | HIG |
| **F5** | Every new control/state ships **AX assertions in the test harness** (labels, roles, values, announcement wording) — the existing headless-instantiation pattern makes this cheap; absence of an AX test for new UI is a review defect. MUST | T | house process |

### G. Surface-specific requirements (menu-bar app shape)

| ID | Requirement | Verify | Sources |
|---|---|---|---|
| **G1** | **Status item**: labeled with the app name + current state (streaming / muted / idle) so VoiceOver identifies it among 20 menu extras; state changes update the label; secondary-click menu fully accessible; primary/secondary behavior documented. MUST | S,T,L | A1/A6; HIG |
| **G2** | **Popover**: reachable and openable keyboard-only (system paths: **Ctrl-F8** "Move focus to status menus"; VoiceOver **VO-M-M**); on keyboard-open, focus enters the popover — VoiceOver focus does *not* reliably enter NSPopover content by itself, so set it deliberately (macOS 26 `accessibilityDefaultFocus`, or explicit first-responder + AX focus management); Esc closes and returns focus to the status item — **verified with VoiceOver running** (documented platform bug: Esc on a `.transient` popover under VO can dismiss the popover *and* its anchoring window; `.applicationDefined` + manual Esc handling is the sanctioned dodge); full traversal inside; height changes and rebuilds never strand VoiceOver/keyboard focus; transient dismissal doesn't eat unsaved state. MUST | S,L | B1–B3; HIG |
| **G3** | **Windows** (Settings, Groups): standard titled chrome, ⌘W, frame restore never off-screen; Tab traversal seeded on show **and re-seeded after content swaps**; sheets get Esc/Return, initial focus, and announced titles. MUST | S,T,L | B-series |
| **G4** | **Onboarding**: completable keyboard-only; every status flip (Requested→Granted, banner appear/clear) is announced; re-fronting on app-activate doesn't steal or reset focus mid-form; "Continue Anyway?" sheet is fully accessible. MUST | S,T,L | A4, B-series |
| **G5** | **Control-panel shell** (flagged surface — audited before its flag flips): visible close affordance + Esc; decorative backing window invisible to AX; beak/bubble never intercept AX hit-testing; focus behavior matches G2. MUST | S,T | B2, F1 |
| **G6** | **Per-app routing UI**: add/remove segmented control labeled per-segment; route menus keyboard-openable and AX-complete; Delete-key removal has a discoverable, announced equivalent; app rows meet the same composed-announcement contract as device rows. MUST | S,T | A3, B-series |

### H. Process & governance

| ID | Requirement | Verify | Sources |
|---|---|---|---|
| **H1** | This standard lives in-repo; UI-touching changes cite the criteria they affect; findings and fixes reference IDs. MUST | S | — |
| **H2** | A **live AX checklist** (F2–F4, the `[L]` items) runs before any release and after popover/window structural changes. MUST | L | — |
| **H3** | If distributed via the App Store: **Accessibility Nutrition Label declarations must match verified reality**. Target declaration set for a Mac utility: VoiceOver · Voice Control · Dark Interface · Differentiate Without Color · Sufficient Contrast · Reduced Motion — each held to Apple's own pass condition, "every common task completable using that feature alone" (this rubric + the live checklist are the evidence; a false label is an App Review 2.3 violation). Voluntary as of 2026-08; Apple has said it becomes mandatory. MUST | L | Apple 2025 |
| **H4** | AX regression tests (F5) are part of Guard 4's suite — accessibility cannot silently regress once encoded. (Apple's only sanctioned *automated* audit, `XCUIApplication.performAccessibilityAudit()`, requires a UI-test target this package doesn't have; the in-repo equivalent is the headless AX assertion pattern, with an XCUITest audit target as an optional later addition.) MUST | T | — |
| **H5** | User-facing documentation and support channels, when they exist, are themselves accessible. SHOULD | — | EN 301 549 cl. 12 |

### N/A ledger (WCAG 2.2 AA criteria not applicable, per WCAG2ICT)

| SC | Why N/A here |
|---|---|
| 1.2.x Time-based media | No audio/video *content* UI (the app routes audio; it doesn't present media with dialogue). |
| 1.3.4 Orientation | Fixed-orientation desktop platform. |
| 1.3.5 Input Purpose / 3.3.7 Redundant Entry / 3.3.8 Accessible Auth | No user-data forms about the user, no process re-asks previously-entered information (onboarding re-*checks* status, never re-asks input), no authentication. |
| 1.4.2 Audio Control | The app plays no auto-starting content audio of its own (the onboarding probe tone is user-triggered and <3 s). |
| 1.4.12 Text Spacing | Applies in principle (WCAG2ICT keeps it for software), but AppKit static text exposes no user style-adaptation mechanism to break; satisfied by default. Re-examine if text styling ever becomes user-adaptable. |
| 2.2.x Timing | No time limits; polling timers impose none on the user. |
| 2.4.1/2.4.5, 3.2.3 (+3.2.4/3.2.6 as E3/E5's formal basis) | "Set of software programs" criteria — WCAG2ICT: a single program automatically satisfies them. Spirit retained via E3/E5. 2.4.2 *applies* (software/window titled) — covered by G3. |
| 2.5.1/2.5.4 Pointer Gestures / Motion Actuation | No multipoint/path gestures, no device-motion input. |
| 3.1.2 Language of Parts | Single-language UI. |
| 4.1.1 Parsing | Obsolete in 2.2. |

---

## 4. How an audit runs against this rubric

1. **Static pass** (`[S]`): per surface, walk every criterion; findings cite
   `file:line`, the criterion ID, *why* it fails (mechanism, affected user, which
   assistive context), and the concrete remediation.
2. **Instrumented pass** (`[T]`): check what the existing AX tests already prove;
   flag claims the tests make that the code no longer honors, and gaps with no
   assertion.
3. **Live pass** (`[L]`): the owed checklist — VoiceOver end-to-end, Full Keyboard
   Access sweep, Accessibility Inspector audit per surface, one Voice
   Control/Switch Control spot-check. Static findings marked "live-confirm"
   graduate or close here.
4. Every finding gets: **ID · surface · criterion · severity · confidence
   (Confirmed-in-code / Needs-live-confirm) · why · fix**.

## 5. Deliberate-exception ledger

Documented decisions that knowingly sit below a criterion. An exception must name
its decision record and is re-surfaced (not silently skipped) in every audit.

| Exception | Criterion | Decision record |
|---|---|---|
| Groups window keeps stock `.secondaryLabel`/`.tertiaryLabel` text in light mode (≈<3:1 in places); contrast lifts from surfaces, not text hue. | C1 | `AudiouterWindowUI/AGENTS.md` — locked by owner; re-confirm before any change. |
| Gold on the warm pane measures ≈2.3–2.5:1 against the system-sheet white; gold is therefore confined to warm surfaces that carry it. | C2 | `AudiouterWindowUI/AGENTS.md` (MembershipRowView surface split). |

---

## 6. Currency (verified 2026-08-01)

Researched against primary sources on 2026-08-01; re-verify at next audit.

- **WCAG 2.2**: Recommendation, Dec 2024 republication; 2025-06-27 and 2025-10-28
  errata (definitions/wording only, no new SCs). ISO/IEC 40500:2026 republication
  expected late 2026. **WCAG 3.0**: Working Draft 2026-03-03 (~174 "requirements",
  scoring model); Candidate Rec ~Q4 2027 at earliest — monitor-only.
- **WCAG2ICT**: Group Note edition 2025-12-11 (coordinated with the EN rewrite);
  a further draft dated 2026-07-29 is in progress.
- **EN 301 549**: v3.2.1 operative; draft V4.1.0 published Nov 2025; V4.1.1
  (WCAG 2.2-based) expected to be cited in the EU Official Journal ~Oct 2026. No
  harmonized standard yet cited under the EAA as of 2026-08.
- **EAA**: applies since 2025-06-28; enforcement live (first French lawsuits Nov
  2025; Swedish product inspections Oct 2025; a June 2026 French ruling against a
  major retailer). Desktop utilities not per-se listed; storefront e-commerce is.
- **US**: DOJ's ADA Title II rule (state/local web + mobile) had its deadlines
  extended by an Interim Final Rule on 2026-04-20 (now Apr 2027/2028) with an
  NPRM reconsidering provisions — no bearing on consumer desktop software.
- **Apple**: Accessibility Nutrition Labels on macOS product pages for devices on
  OS 26+; voluntary as of 2026-08, mandatory "eventually". macOS 26 (Tahoe):
  Magnifier for Mac, Braille Access, Accessibility Reader, `accessibilityDefaultFocus`.
  macOS 27 (current dev platform): natural-language Voice Control, VoiceOver
  Image Explorer, Accessibility Reader AI features, Liquid Glass contrast
  refinements with user-adjustable transparency. Claims of a macOS "Larger Text"
  accessibility pane addition remain unverified — C4's text-styles mechanism is
  the stable adoption path either way.
