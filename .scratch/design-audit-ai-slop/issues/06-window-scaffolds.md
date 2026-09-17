# Groups window and Settings: template scaffolds and one broken picker

Status: ready-for-agent
Closes: B2, B3, B4, B5, B6, B10, B11, B12

- **B2 (P1)** `IconPickerViewController.swift:150, 192, 370-382` — the search field
  sits under the grid it filters, and a typed-SF-Symbol-name path is hidden behind an
  Apply button. Field above the grid; decide whether the typed path is a feature or goes.
- **B10** `GroupIdentityGlowView.swift:24-28, 74-84` — the magenta identity glow
  measures 2 to 7 RGB levels against the card; nobody can see it. **Ruling:** delete
  the view, its gradient layer, its two notification observers and its re-stamp path.
  The seat carries identity alone.
- **B12** `GroupEditorViewController.swift:118, 217-223, 360-403` — "‹ Scenes" and
  "Done" are two doors to one place; edits autosave. **Ruling (owner had no
  preference):** keep "‹ Scenes" plus Cmd-[ and Escape as the way out, and show the
  right-hand button only while it reads "Save".
- **B3** `GroupsOverviewViewController.swift:1041-1097, 137-160` — "Add scene" is a
  dashed tile with a ringed plus over a caption, the stock empty-slot card.
- **B4** `AudioSettingsViewController.swift:877, 913`,
  `GeneralSettingsViewController.swift:676` — per-row `minus.circle.fill` and an
  in-box "Add app…" row: the iPhone editing idiom in an AppKit list.
- **B5** `MixerWindowController.swift:822` — "Set up scenes here, then switch to the
  Mixer to play" is pinned under every pane, the speaker page included.
- **B6** `GroupsOverviewViewController.swift:64-105` — pane header of icon plus
  "Scenes" plus "3 scenes" on a screen already named twice.
- **B11** `GroupsOverviewViewController.swift:71-73, 137-143`, `Tokens.swift:1274-1283`
  — zero-scenes headline 15 pt grey over a 12 pt subtitle, both off the scale. Use
  `Tokens.Font.heading` in `label` and `caption` in `label2`.
