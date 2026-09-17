# One copy pass over every user-visible string

Status: ready-for-agent
Closes: A4, A9, B1, B7, B8, B9, B13, C2, C3, C5, C6, C14, D4, D6, D7

The audit's single highest-impact change. Fifteen findings, one rule set
(`audiout-copy-review` skill + the repo copy rules), one pass.

- **B1** `AudioSettingsViewController.swift:308-318` — connect-volume hint judges the
  number ("a moderate, comfortable start") and joins with an em dash. Drop the
  adjectives, state what the number does.
- **B7** em dash as the sentence joint in five hints:
  `AudioSettingsViewController.swift:316, 419, 468, 758`,
  `AppearanceSettingsViewController.swift:565`.
- **C6** `scripts/make-app.sh:83-91` — all four macOS usage strings share one
  "only X — never Y" shape with an em dash. Write four sentences that differ.
- **C2** `OnboardingViewController.swift:714-847, 1562` — seven step buttons, four
  Title Case and three sentence case. Pick one (sentence case, per DESIGN.md).
- **C3** `OnboardingViewController.swift:798` — "Set Up Remote Control…" is the code
  case name; nothing else on that screen says "remote control".
- **C5** `OnboardingViewController.swift:735` vs `SetupCardView.swift:93-118` —
  "your Wi-Fi" and "your network" one line apart.
- **C14** `DemoPaneView.swift:1675` vs `OnboardingViewController.swift:1580` — drawn
  pane says "System Audio Recording Only", sentence says "Screen & System Audio
  Recording"; "▸" is not Apple's separator (use "›").
- **A4** `PopoverController.swift:3372, 3476` — "Connect a speaker" and "Pair a
  Bluetooth speaker…" fire the same action.
- **A9** `ConnectionState.swift:115, 119` — "Power-cycle it" beside "restart the speaker".
- **B8** `AppearanceSettingsViewController.swift:98, 563-566` — accent subtitle and
  Full-gold hint repeat the same nouns; "the brand gold" and "the routing dot" are
  internal words.
- **B9** straight and curly apostrophes mixed: `GeneralSettingsViewController.swift:512`,
  `AudioSettingsViewController.swift:317`, `GroupEditorViewController.swift:215`.
- **B13** `AboutView.swift:131, 223, 226` — "Third-Party Notices" Title Case;
  "Questions or problems? Email…" answers its own question.
- **D4** `BTAlignmentWizardView.swift:114-119` — copy ends "Try again." directly above
  a Try again button; the comment says those words were already removed once.
- **D6** `BTAlignmentWizardView.swift:157` — "Listen: the clicks should land as one."
  is a colon reveal above two answer buttons.
- **D7** `BTSyncDrawerView.swift:713-715` — negative offsets print an ASCII hyphen
  where every other readout uses a real minus (−).

Analytics event names are an external contract: do not rename any `Analytics.capture`
string while rewording the UI around it.
