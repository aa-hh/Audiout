# The four places the UI states something untrue

Status: ready-for-agent
Closes: C1, C4, C9, D1

PRODUCT.md principle 2 forbids each of these. Not taste calls.

- **D1** `AlignmentStageView.swift:770, 1080-1087` — the wizard intro stage draws a
  steel-blue reference light with no reference speaker chosen, light mode only.
- **C4** `AppDelegate.swift:2615-2624` — the trial-to-paid consent alert shows the
  short card text, not the full disclosure PRODUCT.md names, and its buttons drift
  from the card's. Use `UsageStatsConsentCard.bodyText` and the card's button names.
- **C9** `DemoPaneView.swift:2650` — the rehearsed Share button draws light-mode gold
  #A67C1E; the real button pins #E8B84B. The file's comment claims it wears the real
  button's gold.
- **C1** `SetupCardView.swift:528` — the browsed row washes with the user's macOS
  accent colour at 0.16 beside the gold live row (pink on a pink Mac). Two selection
  washes in one list, one of them not ours.
