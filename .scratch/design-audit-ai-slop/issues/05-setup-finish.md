# Setup window: the finish layer

Status: ready-for-agent
Closes: C7, C8, C10, C11, C12, C13, C15

- **C12** `DemoPaneView.swift:2195, 2196, 2142` — the finale's glow disc rests
  permanently at 0.40 dark / 0.70 light behind the mark. **Ruling:** drop the resting
  aura; the glow passes with the one-shot and leaves, the rings carry the moment.
  `Tokens.Color.glow`'s doc (Tokens.swift:726-729) then stays true as written.
- **C13** `DemoPaneView.swift:1820-1838` — the usage-counts step draws a miniature of
  Audiout's own Share card above the real buttons. **Ruling:** delete the caption
  "You'll see this from Audiout" entirely; the rehearsal and its greeked body stay.
- **C7** `SetupRibbonView.swift:106, 422`, `UsageStatsConsentCard.swift:81, 89` — four
  labels at 14.5, 11.5, 15 and 12.5 pt, none on DESIGN.md's scale or in its ledger.
- **C8** `SetupCardView.swift:197, 291` — a 3 pt red edge bar on top of a red fill and
  a red triangle. One red signal is enough.
- **C10** `SetupCheckRowView.swift:131`, `OnboardingViewController.swift:1428` —
  "Making sure everything's ready…" truncates in the spine while the hero pane is blank.
- **C11** `AppDelegate.swift:3969-3973` — the diagnostics alert says "Try a different
  folder…" and offers a lone OK. Add "Try again" (re-runs the save panel) and "Cancel".
- **C15** `LicenseGateViewController.swift:222, 406-411` — underlined grey links; the
  centred key field parks the caret mid-placeholder.
