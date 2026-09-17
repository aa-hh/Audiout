# Design audit, first pass: AI slop across every screen

Status: ruled — tickets cut under `issues/`
Date: 2026-09-15
Branch: claude/design-audit-ai-slop-f1de78

Four read-only auditors each took one slice of the Mac app and judged every screen
against one written definition of AI slop (`reports/00-rubric.md`). The definition
merges the Impeccable craft floor and its product and native slop tests with the
unslop-ui tell catalog and the repo's own copy-review rules. The one-line version:
a tell is an unspecified default, something on screen because it is what good UI
auto-completes to, not because someone chose it for this product. A choice recorded
in DESIGN.md or PRODUCT.md is not slop; where such a choice still reads as a template
to a stranger it is listed at P3 as "chosen, but reads as a tell" for the owner to rule on.

Evidence: 100 screenshots rendered today from this worktree (popover, Groups window,
Settings panes, Setup window, alignment wizard, light and dark), plus one live capture
of the licence gate. Every finding cites a file and line that the coordinating session
re-checked in source. The four raw reports with the full text of every finding are in
`reports/`; the table below is the index.

## Verdict

The app reads as a person's decisions far more than as a template. Nearly every
colour, radius and row width carries a measured reason beside it, the controls are
stock AppKit, and the custom drawing is short and named. What reads as machine-made
sits in two layers nobody did a single pass over:

1. **The copy finish.** Em dashes as the standard sentence joint in Settings hints and
   in all four macOS permission prompts, an adjective table that editorialises a
   slider value, seven first-run buttons in two capitalisations, "Wi-Fi" and "network"
   one line apart, straight and curly apostrophes mixed in one file, a colon reveal on
   the wizard, a button named after its code identifier ("Set Up Remote Control…").
   One rule applied in one pass fixes all of it, and it is what a stranger clocks first.
2. **The layer between structure and brand.** A splash and a title-bar wordmark in
   front of a volume control, a device row whose main control is invisible and is
   explained by a printed sentence, a dashed "Add scene" placeholder tile, a page
   header of icon plus title plus count, a teaching caption pinned under every pane.

Along the way the auditors found four places where the UI lies, which PRODUCT.md
principle 2 forbids: the wizard stage draws a light for a speaker that was never
chosen (D1), a converting trial is asked for consent with a shorter disclosure than
the one PRODUCT.md names (C4), the Setup rehearsal shows a gold the real button never
draws in light mode (C9), and the Setup list borrows the user's macOS accent colour
for one of its two selection washes (C1).

**Single highest-impact change:** one copy pass over every user-visible string with
the copy-review rules open (B1, B7, C2, C3, C5, C6, B9, B13, D4, D6, A4, A9). It is
the cheapest fix and it removes the most tells.

## Counts

| Severity | Count | Meaning |
|---|---|---|
| P1 | 9 | A stranger clocks it at a glance, or it breaks native trust |
| P2 | 20 | Noticeable on a second look, or a pattern repeated across screens |
| P3 | 20 | Polish, or "chosen, but reads as a tell" (owner's call) |

## Findings index

"Decide" marked a finding that overturns a recorded owner's call or a documented
design choice. All ten were ruled on 2026-09-17 ("ruled" in the last column); the
rulings are under "Owner's rulings" below and in the tickets that carry them. Full text: `reports/<letter>-*.md`.

| ID | Sev | Screen | Finding | Anchor | Decide |
|---|---|---|---|---|---|
| A1 | P1 | Mixer device row | Selecting a speaker has no visible control; a printed sentence and a pointing-hand cursor stand in for it | DeviceRowView.swift:2319, 3138-3153; PopoverController.swift:2312 | |
| C1 | P1 | Setup spine | Browsed row washes with the macOS accent colour at 0.16 next to the gold live row; pink on a pink Mac | SetupCardView.swift:528 | |
| C2 | P1 | Setup buttons | Seven step buttons, four Title Case, three sentence case | OnboardingViewController.swift:714-847, 1562 | |
| C3 | P1 | Setup volume keys | "Set Up Remote Control…" names nothing else on its screen; the code case name leaked | OnboardingViewController.swift:798 | |
| C4 | P1 | Trial-to-paid consent | Stock alert with the short card text, not the full disclosure PRODUCT.md names; buttons drift from the card's | AppDelegate.swift:2615-2624 | |
| D1 | P1 | Wizard intro stage | A steel-blue reference light is drawn with no reference speaker chosen, in light mode only | AlignmentStageView.swift:770, 1080-1087 | |
| B1 | P1 | Settings › Audio | Connect-volume hint judges the number ("a moderate, comfortable start") and joins with an em dash | AudioSettingsViewController.swift:308-318 | |
| B2 | P1 | Icon picker | Search field sits under the grid it filters; a hidden typed-SF-Symbol-name path with an Apply button | IconPickerViewController.swift:150, 192, 370-382 | |
| A2 | P1 | First open | Up to 0.6 s of nothing, then a logo held 0.7 to 2.7 s over the mixer | SurfaceSplashView.swift:37, 43; AppSurfaceController.swift:238 | ruled |
| A3 | P2 | Header strip | Wordmark in ClashDisplay centred where a Mac window puts its title | SurfaceToolbar.swift:181 | ruled |
| A4 | P2 | Output Speakers | "Connect a speaker" and "Pair a Bluetooth speaker…" fire the same action | PopoverController.swift:3372, 3476 | |
| A5 | P2 | Device row | `flashRow()` gold pulse has no caller outside its own test | DeviceRowView.swift:3290-3339 | |
| A6 | P2 | Device row mute / EQ | Filled engaged symbols are declared, catalogued and never drawn; comments and DESIGN.md describe the filled version | DeviceRowView.swift:974, 1005; MainOutRowView.swift:630 | |
| B3 | P2 | Scenes overview | "Add scene" is a dashed tile with a ringed plus over a caption, the stock empty-slot card | GroupsOverviewViewController.swift:1041-1097, 137-160 | |
| B4 | P2 | Settings lists | Per-row `minus.circle.fill` and an in-box "Add app…" row, the iPhone editing idiom | AudioSettingsViewController.swift:877, 913; GeneralSettingsViewController.swift:676 | |
| B5 | P2 | Groups window | "Set up scenes here, then switch to the Mixer to play" pinned under every pane, including the speaker page | MixerWindowController.swift:822 | |
| B6 | P2 | Scenes overview | Pane header of icon plus "Scenes" plus "3 scenes" on a screen already named twice | GroupsOverviewViewController.swift:64-105 | |
| B7 | P2 | Settings hints | Five hint lines use an em dash as the sentence joint | AudioSettingsViewController.swift:316, 419, 468, 758; AppearanceSettingsViewController.swift:565 | |
| B8 | P2 | Settings › Appearance | Accent subtitle and Full-gold hint repeat the same nouns; "the brand gold", "the routing dot" are internal words | AppearanceSettingsViewController.swift:98, 563-566 | |
| C5 | P2 | Setup Wi-Fi step | "your Wi-Fi" and "your network" one line apart; the earned title keeps the wrong one | OnboardingViewController.swift:735; SetupCardView.swift:93-118 | |
| C6 | P2 | macOS permission prompts | All four usage strings share one "only X — never Y" shape with an em dash | scripts/make-app.sh:83-91 | |
| C7 | P2 | Setup type | Four labels at 14.5, 11.5, 15 and 12.5 pt, none on the scale or in the ledger | SetupRibbonView.swift:106, 422; UsageStatsConsentCard.swift:81, 89 | |
| C8 | P2 | Setup broken row | A 3 pt red edge bar on top of a red fill and a red triangle | SetupCardView.swift:197, 291 | |
| C9 | P2 | Setup consent rehearsal | The drawn Share button uses light-mode gold #A67C1E; the real button pins #E8B84B | DemoPaneView.swift:2650 | |
| C10 | P2 | Setup final check | "Making sure everything's ready…" truncates in the spine while the hero pane goes blank | SetupCheckRowView.swift:131; OnboardingViewController.swift:1428 | |
| C11 | P2 | Diagnostics alert | "Try a different folder…" with a lone OK and no way to try | AppDelegate.swift:3969-3973 | |
| D2 | P2 | Wizard question screen | About 100 pt of empty plate between the question and its answers, from centring content in the intro-height sheet | BTAlignmentWizardView.swift:370-377, 476-484 | |
| D3 | P2 | First-join note | A gold inline phrase reads as a link; the whole sentence is the button | BTAlignmentNoteView.swift:42-47, 189-193 | |
| D4 | P2 | Wizard "Mac is late" | Copy ends "Try again." above a Try again button; the comment says the words were removed | BTAlignmentWizardView.swift:114-119 | |
| A7 | P3 | Device row | A dashed stroke means "connecting" on the ring and "not set" on the Offset chip | DeviceRowView.swift:3543; HaloRingView.swift:252 | |
| A8 | P3 | Source column | Bordered pills look pressable; none are | FeedPillView.swift:33-51, 105 | ruled |
| A9 | P3 | Failure diagnosis | "Power-cycle it" beside "restart the speaker" | ConnectionState.swift:115, 119 | |
| A10 | P3 | Output Speakers menu | "Bluetooth pairings" is a disabled plain item, against DESIGN.md's section-header rule | PopoverController.swift:3386-3387 | |
| B9 | P3 | Settings, Groups editor | Straight and typographic apostrophes mixed in the same files | GeneralSettingsViewController.swift:512; AudioSettingsViewController.swift:317; GroupEditorViewController.swift:215 | |
| B10 | P3 | Scene cards | Magenta identity glow ships at an alpha nobody can see (2 to 7 RGB levels) | GroupIdentityGlowView.swift:28-29 | ruled |
| B11 | P3 | Zero-scenes canvas | Headline 15 pt grey and subtitle 12 pt, off the scale | GroupsOverviewViewController.swift:71-73; Tokens.swift:1276-1283 | |
| B12 | P3 | Groups editor | "‹ Scenes" and "Done" are two doors to one place | GroupEditorViewController.swift:118, 217-223 | ruled |
| B13 | P3 | Settings › About | "Third-Party Notices" in Title Case; "Questions or problems? Email…" | AboutView.swift:131, 223, 226 | |
| C12 | P3 | Setup finale | A resting glow disc at 0.40 dark / 0.70 light behind the mark; the glow token's doc says transient only | DemoPaneView.swift:2195 | ruled |
| C13 | P3 | Setup usage-stats step | The stage rehearses the app's own consent dialog directly above the real buttons | DemoPaneView.swift:1820-1838 | ruled |
| C14 | P3 | Setup denied recovery | The drawn pane says "System Audio Recording Only", the sentence says "Screen & System Audio Recording"; "▸" is not Apple's separator | DemoPaneView.swift:1675; OnboardingViewController.swift:1580 | |
| C15 | P3 | Licence gate | Underlined grey links; the centred key field parks the caret mid-placeholder | LicenseGateViewController.swift:222, 406-411 | |
| D5 | P3 | Wizard keycaps | One 10 pt radius makes a circle on the 22 pt chip and a capsule on the 44×20 one | AlignmentPlateCell.swift:490-499 | |
| D6 | P3 | Wizard proposal | "Listen: the clicks should land as one." above two answer buttons | BTAlignmentWizardView.swift:157 | |
| D7 | P3 | Sync drawer | Negative offsets print with an ASCII hyphen; every other readout uses a real minus | BTSyncDrawerView.swift:713-715 | |
| D8 | P3 | EQ scope | A 6 pt corner and nine bare constants with no reason recorded | EQResponseCurveView.swift:84-93 | |
| D9 | P3 | EQ scope | Band grid drawn in gold at rest, so gold is everything except the signal | EQResponseCurveView.swift:372-386 | ruled |
| D10 | P3 | Wizard chassis | Canvas grain and the two room-spill washes exist on screen and nowhere in DESIGN.md | WarmCanvasView.swift:19-28; AlignmentWizardViewController.swift:155-274 | ruled |
| D11 | P3 | Wizard bow-outs | The dormant stage is an empty black panel holding the top third of the sheet | BTAlignmentWizardView.swift:8-11 | ruled |

## Patterns across slices

**No rule spans the screens.** Each auditor found the same thing in a different
place: a choice that is fine on its own screen and disagrees with the one next
door. Capitalisation across seven buttons, two words for one action (A4), two words
for one network (C5), three ways to print a keyboard shortcut (wizard keycap chip,
bare "⌘Z", a caption sentence in the drawer), two selection washes in one list (C1),
two apostrophes in one file (B9). None of it was generated; all of it was written
once each and never compared.

**The record trails the pixels.** In every slice a document describes a version that
no longer ships or leaves out one that does: DESIGN.md and the popover AGENTS.md
describe a toolbar the strip has replaced; the mute and Equalizer doc comments and
DESIGN.md describe filled engaged symbols the code no longer draws (A6); the glow
token's own doc lists three transient consumers and the finale is a fourth that
rests (C12); the consent rehearsal claims in a comment to wear the real button's gold
and does not (C9); grain and room spill are on screen and unrecorded (D10). No user
sees this, and the next agent builds on it.

**Brand placed in front of the task.** The splash (A2), the centred wordmark (A3),
the resting finale aura (C12) and the gold scope grid (D9) are the same instinct in
four places. All four are recorded decisions, and together they are the part of the
app that reads as a marketing site's habits applied to a menu-bar utility.

**Template scaffolds where one control would do.** The dashed Add-scene tile (B3),
the icon-title-count page header (B6), the footer caption on every pane (B5), the
consent step rehearsing the app's own dialog (C13), the empty stage on the wizard's
failure screens (D11). Each fills a slot the layout had rather than answering a need
the screen had.

**Off-scale type.** Half-point sizes in Setup (C7) and two one-off sizes in the empty
Groups canvas (B11) sit outside the scale DESIGN.md ledgers.

## What reads as deliberately designed (keep)

- Cards draw no chrome of their own; one hairline separates sections (CardView.swift).
- The connection ring carries state by shape, not only by colour, and keeps it under Reduce Motion.
- The rail's connect pulse is one authored moment on a real event, a stroke and never a shadow.
- The delete confirmation changes its sentence when the scene is playing; Return goes to Cancel.
- The licence sheet's remove alert names both buttons for what they do.
- The Equalizer box is a well, not a card, because the card fill measured identical to the light ground.
- The theme tiles borrow System Settings' miniature-window idiom instead of inventing a swatch.
- The spine row title changes to what you actually got ("3 speakers on your network").
- Denial copy admits the awkward part: "macOS only asks once, so from here it's a switch in System Settings."
- The gate reserves its gutter so no verdict ever moves the field the buyer is typing into.
- The wizard's rung ladder is one source for both the picture and the word, with hysteresis.
- The EQ scope plots the actual biquads and puts the faders on the scope's own axis; gold arrives only with a shaped trace.
- The drawer's value field is a stock bezel after a custom cell was tried and reverted, reasons recorded.

## Not seen

No screenshot exists and none could be rendered for these; they were audited from
source only. Anything visual in them is unverified.

- Menu-bar status item and its menu, the volume HUD, the quitting indicator, the surface splash, the Touch Bar.
- Mixer rows: muted, shaped EQ, sync drawer open, first-join note, "Removed, Undo", the AP1 tag; the silence-fallback and system-AirPlay banners; the unregistered "please buy" note.
- Settings › About, the Enter License sheet, the Settings sidebar, the Main Audio detail page, the General rows that mount conditionally (iPhone control, QR tile, remembered iPhones, licence check-in), the Audio pane's Advanced fold.
- The zero-scenes canvas (the default window capture ran before the Groups content mounted).
- Licence gate in dark mode and in every state but idle; the consent sheet on the Setup window; every NSAlert; the four macOS permission prompts as macOS draws them.
- Sync drawer in any state; EQ editor with a shaped or bypassed curve.
- Hover, pressed, focus and disabled states everywhere; Increase Contrast; the Subtle accent dial; Reduce Motion variants.

## Owner's rulings, 2026-09-17

| ID | Ruling | Ticket |
|---|---|---|
| A2 | The splash was meant to cover loading, not to be an entrance. Measure what the 0.6 s deferral actually hides, then cut the hold to that; if nothing needs covering, delete it. | 04 |
| A3 | Replace the centred wordmark with the current screen's name, keeping ClashDisplay-Semibold 17 pt in the same place. No wordmark on the surface. | 04 |
| A8 | Neither keeping it nor plain text. Design pass with the `impeccable` skill; values stay non-interactive, and hovering "+N" reveals the hidden items. | 09 |
| B10 | Delete the glow view, its layer, its two observers and its re-stamp path. | 06 |
| B12 | No preference stated; taking the audit's fix. "‹ Scenes" is the way out, and the right-hand button shows only while it reads "Save". | 06 |
| C12 | Drop the resting aura. The glow passes with the one-shot and leaves. | 05 |
| C13 | Delete the caption "You'll see this from Audiout". The rehearsal and its greeked body stay. | 05 |
| D9 | Grid in `scopeFlatLine`; gold arrives only with a shaped trace. DESIGN.md's Scope Instrument Rule changes with it. | 07 |
| D10 | Record the grain and both room-spill washes in DESIGN.md with their alphas, dark-only scope and accessibility switches. | 08 |
| D11 | Let the dormant stage collapse its height on the four bow-out screens. | 07 |

## Tickets

Nine tickets under `issues/`, grouped by the fix rather than by screen. Every one of
the 49 findings is carried by exactly one of them.

| # | Ticket | Closes | Status |
|---|---|---|---|
| 01 | One copy pass over every user-visible string | A4, A9, B1, B7, B8, B9, B13, C2, C3, C5, C6, C14, D4, D6, D7 | ready-for-agent |
| 02 | The four places the UI states something untrue | C1, C4, C9, D1 | ready-for-agent |
| 03 | Mixer device row: make selection visible, then delete its stand-ins | A1, A5, A6, A7, A10 | ready-for-agent |
| 04 | Surface shell: first-open wait, screen name in the title position | A2, A3 | ready-for-agent |
| 05 | Setup window: the finish layer | C7, C8, C10, C11, C12, C13, C15 | ready-for-agent |
| 06 | Groups window and Settings: template scaffolds and one broken picker | B2, B3, B4, B5, B6, B10, B11, B12 | ready-for-agent |
| 07 | Wizard and EQ scope: the instrument surfaces | D2, D3, D5, D9, D11 | ready-for-agent |
| 08 | The record catches up with the pixels | D8, D10 | ready-for-agent |
| 09 | Source column: shape it, don't just strip it | A8 | ready-for-human |

Suggested order: 02 (the untrue screens) and 01 (the copy pass) first — the first is
trust, the second is what a stranger clocks. 04 and 03 change what the app feels like
on the first click. 09 needs a design pass before it can be built.
