# C — First-run surfaces (licence gate, Setup window, consent, alerts, permission prompts)

## 1. Verdict

These screens read as a person's work at the level of structure and reasoning: the spine, the
rehearsal pane, the reserved gutter on the gate and the recovery copy are all decisions somebody
argued for in the code. What reads as machine-made is the finish layer, where nothing enforced one
answer: seven consecutive call-to-action buttons in two different capitalisations, two different
selection colours in one seven-row list, three font sizes that exist nowhere else in the app, and
"your Wi-Fi" and "your network" for the same thing one line apart.

Highest-impact single change: put one rule on the seven step buttons and the spine wash. Sentence
case for every call to action, and the app's own `engagedChrome` wash for the browsed row instead of
the macOS accent colour. Those two fixes clean up every screen of the flow.

## 2. Findings

[P1] Setup spine, a granted row opened for reading — AudioutCore/Sources/AudioutOnboardingUI/SetupCardView.swift:533 — onboarding-light-browse-granted.png, onboarding-dark-browse-granted.png
  tell:  C reinvented control / system drift
  now:   The browsed row fills with `NSColor.selectedContentBackgroundColor` at 0.16, so a blue row
         sits directly above the live row's gold wash. `selectedContentBackgroundColor` follows the
         user's own macOS accent setting, so on a Mac set to pink or graphite the first screen shows
         a pink or grey selected row beside the gold one.
  why:   Two selection vocabularies in one seven-row list, and one of them is not a Warm Signal
         colour at all. DESIGN.md's own Don't says the washes stay on `engagedChrome`, and
         PopoverColumnGrid.swift:532 sets the app's selection wash as `engagedChrome` at 0.18. This
         row uses the hover colour at a third alpha. That is what "nobody decided it" looks like.
  fix:   `fill = dynamicBlend(Tokens.Color.panel, fraction: PopoverColumnGrid.rowSelectionWashAlpha,
         of: Tokens.Color.engagedChrome)` — the same neutral engaged wash every other list in the app
         draws, at the same 0.18.

[P1] Setup, all seven step buttons — OnboardingViewController.swift:714, 736, 761, 777, 798, 820, 847 and 1562 — onboarding-*-step*.png
  tell:  D copy (sentence case)
  now:   "Enable system audio", "Enable Local Network", "Enable Bluetooth Access", "Turn on at
         login", "Set Up Remote Control…", "Continue", "Share Usage Counts", plus "No Thanks" and
         "Skip for now". Three sentence case, four Title Case, in a fixed sequence the user walks
         end to end.
  why:   The copy-review rule is sentence case for every label except the macOS menu items Apple
         itself title-cases. "Local Network" earns its capitals because it quotes the name of the
         macOS permission; "Bluetooth Access", "Remote Control", "Usage Counts" and "Thanks" do not.
         Each button was clearly written on its own card and nothing compared them, which is exactly
         the tell: seven strings, no shared rule.
  fix:   "Enable Bluetooth" (the pane is called Bluetooth), "Allow volume keys…", "Share usage
         counts", "No thanks". Leave "Enable system audio", "Enable Local Network", "Turn on at
         login", "Continue" and "Skip for now" as they are.

[P1] Setup, the volume-keys step — OnboardingViewController.swift:798 — onboarding-dark-step5-remotecontrol.png, onboarding-light-step5-remotecontrol.png
  tell:  D copy (terminology)
  now:   The card says "Use your volume keys", the spine row says "Volume-key control", the macOS
         pane the rehearsal draws says "Accessibility", and the button says "Set Up Remote
         Control…". "Remote Control" appears nowhere else on the screen, and the very next spine row
         is the iPhone step, whose app is named Audiout Remote.
  why:   "Remote Control" is the code's own case name (`SetupStep.remoteControl`) surfacing on a
         button. Nothing the user can see is called that, and the one thing that sounds like it is a
         different feature one row below. A button whose noun does not appear anywhere on its own
         screen reads as generated from the identifier rather than written for the person.
  fix:   "Allow volume keys…" — the ellipsis is still correct, since the click opens a macOS alert.

[P1] The one-time consent ask a converting trial gets — AudioutCore/Sources/AudioutApp/AppDelegate.swift:2615-2624 — no screenshot
  tell:  D copy (incomplete disclosure) + C off-platform inconsistency
  now:   A stock `NSAlert` with "Share anonymous usage counts" and the body "Audiout counts which
         features get used. No audio, speaker names or your license key are ever part of it."
         Buttons "Share Usage Counts" / "No Thanks".
  why:   Two problems. First, the words are the spine card's short `detail` string, not
         `UsageStatsConsentCard.bodyText`, so this is the only place a user is asked for consent
         without being told about the Mac model, macOS version, locale, timezone, network type,
         licence status, per-install ID and coarse city that PRODUCT.md says are actually sent.
         PRODUCT.md names `UsageStatsConsentCard.bodyText` as the app's statement of what is
         collected. Second, it is a stock alert, while the identical ask during Setup is a drawn
         Warm Signal card — and OnboardingViewController.swift:2041 records that an `NSAlert` was
         tried for this ask and rejected by the owner.
  fix:   Present `UsageStatsConsentViewController` here too, so both asks are one surface with one
         set of words. If a modal is unavoidable at this point in launch, at minimum set
         `informativeText` to `UsageStatsConsentCard.bodyText` and take the button titles from
         `UsageStatsConsentCard.shareTitle` / `.declineTitle` so they cannot drift.

[P2] Setup, the Wi-Fi step and its earned titles — OnboardingViewController.swift:735, SetupCardView.swift:93, 94, 117, 118 — onboarding-dark-step3-bluetooth.png (spine row 2), onboarding-*-step1-audio.png
  tell:  D copy (terminology)
  now:   The headline says "Find speakers on your Wi‑Fi" and the line under it says "Audiout needs
         this to reach the speakers on your network." After the grant, the spine row reads
         "3 speakers on your network".
  why:   The copy-review table settles this word: use "Wi-Fi network", never "your network". The two
         spellings sit one line apart on the same card, and the earned title a user reads for the
         rest of the flow is the wrong one. Same concept, two words, no reason.
  fix:   Why line: "Audiout needs this to reach the speakers on your Wi‑Fi." Earned titles:
         "1 speaker on your Wi‑Fi" / "\(count) speakers on your Wi‑Fi".

[P2] The four macOS permission prompts — scripts/make-app.sh:83, 86, 89, 91 — no screenshot
  tell:  D copy (em dash, template)
  now:   All four usage strings run the same shape: a claim, an em dash, then a denial.
         "…never recorded, saved, or sent anywhere else." / "It only finds speakers — it doesn't
         read or collect anything else about your network." / "It only reaches speakers you choose —
         it never scans for or reads anything else." / "The recording is analysed on your Mac and
         thrown away — nothing is saved or sent anywhere."
  why:   The copy rules ban em dashes in UI strings outright, and these are UI strings: macOS renders
         them inside the system prompt. Four for four, all with the same "only X — never Y" rhythm,
         is one template filled in four times, and it is the first Audiout prose most users will
         read.
  fix:   Replace each em dash with a full stop and a new sentence. For example: "Audiout connects to
         Bluetooth speakers you have already paired so it can play your Mac's audio on them. It only
         reaches speakers you choose. It never scans for anything else." Vary the second sentence per
         permission so the four stop sharing one shape.

[P2] Setup hero and the consent card, body type — SetupRibbonView.swift:106, SetupRibbonView.swift:422, UsageStatsConsentCard.swift:81, UsageStatsConsentCard.swift:89 — every onboarding screenshot
  tell:  C type off scale
  now:   Four real (non-mock) labels set their own sizes: the why line at 14.5 pt medium, the status
         line at 11.5 pt semibold, the consent headline at 15 pt semibold, the consent body at
         12.5 pt. None is a `Tokens.Font` value.
  why:   DESIGN.md's "Off-Scale Sizes Are Ledgered, Not Silently Tokenized" names exactly four
         permitted one-off sizes (`syncReadout`, `keycap`, `plateTitle`, `detail`) and none of these
         is among them. Half-point sizes in particular are the giveaway: 14.5 and 12.5 and 11.5 are
         not picked off a scale, they are what you land on nudging until it looks right. The app
         already has `body` 13, `caption` 11, `captionEmphasized` 11/600, `heading` 16 and
         `plateTitle` 15 for these jobs.
  fix:   Why line → `Tokens.Font.heading` (16/600) or a new ledgered `Tokens.Font.lede`; status line
         → `Tokens.Font.captionEmphasized`; consent headline → `Tokens.Font.plateTitle` (already
         15/600); consent body → `Tokens.Font.body`. Whichever stays off scale gets a ledger entry in
         `Tokens.swift` and a line in DESIGN.md, like the other four.

[P2] Setup spine, a permission that was granted and is off again — SetupCardView.swift:197, 291, 545 — onboarding-dark-permission-lost.png, onboarding-light-permission-lost.png
  tell:  B coloured stripe
  now:   A broken row draws a 3 pt red bar down its leading edge, on top of a red-tinted row fill
         (`panel` blended 0.08 toward `failure`) and a red alert triangle in the trailing marker slot.
  why:   Three marks saying one thing, and the extra one is the coloured left border the craft floor
         names as a default: nothing in macOS's own grouped lists draws a coloured leading edge, and
         the file's own comment at SetupCardView.swift:539-543 already argues an edge bar beside a
         selection fill "said the same thing twice" — then keeps one anyway. The fill plus the
         triangle already carry the state at a glance.
  fix:   Drop `edgeBar` and keep the failure-tinted fill and the alert triangle. If the row needs to
         be louder, raise the fill fraction rather than adding a shape.

[P2] Setup, the usage-counts rehearsal in light mode — DemoPaneView.swift:2650 — onboarding-light-checking.png, onboarding-light-step7-usagestats.png
  tell:  B surface / brand fidelity
  now:   The drawn Share button inside the rehearsal fills with `Tokens.Color.gold` resolved live,
         which in light mode is `#A67C1E`. Measured off the capture: light mock fill (166, 124, 30) =
         #A67C1E, dark mock fill (232, 184, 75) = #E8B84B. The real button it rehearses
         (`ProminentButton.fill`, ProminentButton.swift:45) pins `#E8B84B` in both appearances.
  why:   The pane's contract is "this is what you'll see", and in light mode it shows a gold the
         sheet will never draw. DemoPaneView.swift:2558 states the mock "wears what the real button
         wears — `ProminentButton`'s gold"; it does not, because the mock resolves the token live and
         the real button pins it dark. The test hook at DemoPaneView.swift:2659 compares against
         `Tokens.Color.gold`, so it passes while the two disagree.
  fix:   Resolve the mock's prominent fill the same way the real button does — reuse
         `ProminentButton`'s pinned value rather than reading `Tokens.Color.gold` live — and change
         the test hook to compare against that pinned value.

[P2] Setup, the final check running — SetupCheckRowView.swift:59, 131 and OnboardingViewController.swift:1428 — onboarding-light-checking.png, onboarding-dark-checking.png
  tell:  E layout (truncation) + A empty template
  now:   The spine row reads "Making sure everything's read…", truncated, in the fixed 288 pt spine
         (207 pt of text width after the tile and marker slots). At the same moment the hero pane has
         no headline, no why line, no status line and no button: `ribbonContent` returns an empty
         `RibbonContent`, so the previous step's rehearsal stays on stage under a caption that says
         "You'll see this from Audiout", above a hairline with nothing under it.
  why:   The one string that says what the app is doing is the one that gets cut, and the rest of the
         screen has gone blank. Both appearances, every first run, on a window whose size is fixed at
         820 x 560 so it cannot resize its way out. A stranger reads it as half-loaded.
  fix:   Shorten the running title to "Checking everything" (or add
         `allowsDefaultTighteningForTruncation = true` at SetupCheckRowView.swift:59, which
         `SetupSpineRowView` already sets at SetupCardView.swift:307). Give the hold beat a status
         line in the ribbon — "Checking everything before you start." with the spinner — so the hero
         is never wordless.

[P2] Diagnostics save failure — AudioutCore/Sources/AudioutApp/AppDelegate.swift:3969-3973 — no screenshot
  tell:  D copy (bare OK)
  now:   `NSAlert` with "Audiout couldn't save the diagnostics file" / "Try a different folder, or
         check that the disk isn't full." and no `addButton` call, so AppKit supplies a lone "OK".
  why:   The body names two recoveries and the dialog offers neither. Dismissing is the only action,
         which is the bare-OK dead end the copy rules call an error. Every other alert in this file
         names its buttons; this one took the default.
  fix:   `alert.addButton(withTitle: "Try again")` (re-run the save panel) and
         `alert.addButton(withTitle: "Cancel")`.

[P3] Setup finale — DemoPaneView.swift:2195, 2196, 2142 — onboarding-light-complete.png, onboarding-dark-complete.png
  tell:  B unprompted glow — chosen, but reads as a tell
  now:   A radial `CAGradientLayer` in `Tokens.Color.glow` sits permanently behind the brand mark at
         resting opacity 1, peaking at alpha 0.40 in dark and 0.70 in light, on a 184 pt disc behind
         an 88 pt mark, centred in an otherwise empty pane.
  why:   The choice is documented in the file, so it is not an accident. But `Tokens.Color.glow`'s
         own doc (Tokens.swift:726-729) names its consumers as "the rail bead, the ring's arrival
         pulse and the header-dot bloom: transient strokes and fills, never a shadow", and this is a
         fourth consumer that never goes away. DESIGN.md's Elevation and Depth section says depth is
         flat and light separates by edge weight. At 0.70 on the flat `#FAFAFB` ground the result is a
         soft yellow disc in the middle of a white panel, which is the first thing a viewer who has
         not read DESIGN.md will call a generated glow.
  fix:   Keep the aura as part of the one-shot and let it settle to a much lower resting alpha
         (dark 0.18, light 0.25 as a starting point), or drop the resting aura entirely and let the
         rings carry the moment. Either way add the finale to `glow`'s doc comment as a named
         consumer, and say there that this one rests rather than passing.

[P3] Setup, the usage-counts step — DemoPaneView.swift:1820-1838, OnboardingViewController.swift:1387 — onboarding-dark-step7-usagestats.png, onboarding-light-step7-usagestats.png
  tell:  A scaffold — chosen, but reads as a tell
  now:   The stage draws a miniature of Audiout's own Share / Don't Share card, captioned "You'll see
         this from Audiout", directly above the real "No Thanks" and "Share Usage Counts" buttons
         that ask the same question.
  why:   Every other step's pane rehearses a macOS surface the user is about to meet, which is the
         idea the whole window is built on. This step has no foreign surface, so the template gets
         applied to the app's own dialog and the user reads a picture of a choice immediately above
         the choice. The file's own comment concedes the risk ("reads as the ask itself, not as a
         preview of one") and answers it by greeking the body text, which leaves a panel of grey bars
         where the privacy statement should be.
  fix:   Drop the rehearsal for this one step and put `UsageStatsConsentCard.bodyText` on the stage
         as real copy, with the two real buttons underneath. The user then reads the promise and
         answers once, which is what the sheet would have shown anyway.

[P3] Setup, the denied and permission-lost recovery — DemoPaneView.swift:1675 vs OnboardingViewController.swift:1580 — onboarding-dark-denied.png, onboarding-dark-permission-lost.png
  tell:  D copy (two names, one destination)
  now:   The drawn System Settings pane is titled "System Audio Recording Only" while the sentence
         60 px below it says "Turn Audiout on under Privacy & Security ▸ Screen & System Audio
         Recording".
  why:   Both strings are real, and the reason for the short one is written down (the word "Screen"
         is what the card's copy exists to defuse). The side effect was not: on the one screen whose
         whole job is helping someone find a switch, the picture and the instructions name two
         different places. The "▸" is also not the separator macOS writes; Apple uses ">".
  fix:   Use one name in both. Either title the mock "Screen & System Audio Recording" and let the
         card copy keep defusing it, or shorten the sentence to "…under Privacy & Security, in System
         Audio Recording Only". Swap "▸" for ">".

[P3] Licence gate, the key field and the two quiet links — LicenseGateViewController.swift:222, 406-411 — gate-idle-light.png
  tell:  C web-shaped affordance / E layout
  now:   "Paste key" and "I lost my key" are grey underlined text. The key field is centre-aligned,
         so at rest the insertion caret sits in the middle of the greyed placeholder, splitting
         "AUDT-XXXXX-XXX|XX-XXXXX-XXXXX".
  why:   Grey underlined text is the web's link convention, not AppKit's; macOS marks a text button
         by its accent-coloured label, and an underline on a neutral grey reads as a page rather than
         a window. The split caret is a small thing a person would have caught on first sight: it
         looks like the hint has been typed into and broken.
  fix:   Drop the underline and set the two buttons' titles in `Tokens.Color.goldText` or the system
         link colour, keeping them borderless. Left-align the key field (`alignment = .natural`, the
         value the email mode at line 572 already uses) so the caret rests at the start of the hint.

## 3. Repeated patterns across the slice

**Nothing enforces one rule across the seven steps.** The buttons disagree on capitalisation, the
copy disagrees on "Wi-Fi" versus "network", four labels invent their own font sizes, and the spine
carries two selection colours. Each individual choice is defensible where it was made; none of them
was made against the other six. This is the single loudest signal on these screens and it is all in
the finish layer, not the structure.

**The rehearsal pane is applied as a template, not as a judgement.** It is the right idea for the
five steps that raise a macOS surface. For the usage-counts step there is no foreign surface, so it
draws Audiout's own dialog inside Audiout. For the final-check beat there is nothing to rehearse at
all, so the previous step's picture stays on stage while the rest of the pane empties out. In both
cases the template survives past the point where it carries information.

**Documented decisions drifted away from the documents.** The finale aura is a fourth consumer of a
token whose own doc says it is for transient marks. The consent-card rehearsal claims in a comment to
wear the real button's gold and does not in light mode. `GlassPanelView` is a custom-drawn chrome
surface that DESIGN.md's "Custom Drawing Is a Short, Named List" rule requires to be named in
`AudioutOnboardingUI/AGENTS.md`, and is not. The rules are good; nothing is checking them.

## 4. Positives

- The spine row title changes from the ask to what you actually got, and for Wi-Fi it carries the
  real count ("3 speakers on your network") instead of a generic tick — something the user can check
  (SetupCardView.swift:81-96).
- Locked steps genuinely read locked: dimmed tile, padlock in the same trailing slot every other
  marker uses, and a click that refuses silently rather than shaking the row (SetupCardView.swift:583-596).
- The denial copy admits the awkward part instead of hiding it: "You chose Don't Allow. macOS only
  asks once, so from here it's a switch in System Settings."
- `UsageStatsConsentCard.bodyText` names what is actually sent, including the Mac model, macOS
  version, city and licence status, rather than a reassuring summary (UsageStatsConsentCard.swift:164).
- The finale's motion is a single shot that is spent once and never loops, and Reduce Motion spends it
  without moving anything (DemoPaneView.swift:2070-2077).
- The gate reserves two lines of gutter that are always there and empty at rest, so no verdict,
  wait or error ever moves the field the buyer is typing into (LicenseGateViewController.swift:252-256).

## 5. Unverified impressions (screenshot only, no code anchor)

- In `gate-idle-light.png` the gold Register button measures roughly #CDB55D at its top edge falling
  to #C5A948 at its bottom, against the #E8B84B that `ProminentButton.fill` pins. That is AppKit's
  `.rounded` bezel shading the fill, which is the same mechanism the class's own doc describes for
  the light-mode value it rejected. I could not confirm whether the captured window was key, and a
  capture can shift colour through display profiles, so this needs an eye on a real screen before it
  is called a regression.
- In the same capture the translucent panel over the emitter field is nearly invisible: 60 % of
  `canvas`, which in light is #FAFAFB, over a near-white field. The rings read as decoration on paper
  rather than as a dimmed backdrop behind type. I have the alpha in source but no dark-mode capture to
  compare against, so I cannot say whether the effect lands in dark and only fails in light.

## 6. Screens and states in this slice I could not see

No screenshot existed and none could be rendered for any of these. All were audited from source only,
except where noted as not audited at all.

- The licence gate in **dark appearance**. Only one gate capture arrived, `gate-idle-light.png`.
- Every gate state except idle: the trial-expired headline and body, "Checking…", each of the four
  verdict lines, the "I lost my key" email detour, the checkout-wait line, the clipboard offer, the
  revoked state's promoted Buy button, and the pass moment (field surge plus handoff).
- The live usage-statistics consent sheet (`UsageStatsConsentViewController`) as presented on the
  Setup window.
- The one-time consent alert a converting trial gets (AppDelegate.swift:2615).
- Both "Audiout is running from a temporary location" alerts (the Move to Applications offer and the
  move-it-yourself fallback).
- The two settings-store alerts: "Audiout couldn't save a settings change" and "Some of Audiout's
  saved settings couldn't be read".
- The companion approval alert ("Allow … to control audio on this Mac?").
- The "Diagnostics saved" and "Audiout couldn't save the diagnostics file" alerts.
- The four macOS permission prompts themselves, as macOS renders them.
- Increase Contrast and the Subtle accent-dial column, in either appearance, for every screen above.
- Reduce Motion variants, and the finale celebration in motion.
- The "please buy" unregistered note: it is a note in the Mixer popover
  (`setUnregisteredNoteActive`, AppDelegate.swift:2559), so it belongs to the popover auditor's
  slice, not this one. Flagging it here only so it is not assumed covered.
