# Wizard and EQ scope: the instrument surfaces

Status: ready-for-agent
Closes: D2, D3, D5, D9, D11

- **D9** `EQResponseCurveView.swift:372-386` — the ten band gridlines are gold at 14%,
  so on a flat EQ gold marks everything except the signal. **Ruling:** draw the grid in
  `scopeFlatLine` at the same alpha; gold arrives only with a shaped trace. Update
  DESIGN.md's Scope Instrument Rule, which currently names a gold gridline.
- **D11** `BTAlignmentWizardView.swift:8-11`, `AlignmentStageView.swift:95-96` — on
  unsettled, unreachable, "Mac is late" and target lost the stage goes dormant and
  holds an empty 132 pt panel. **Ruling:** let the dormant stage collapse its own
  height on those four screens. The chassis stays fixed everywhere else so the stage
  never jumps under the user.
- **D2** `BTAlignmentWizardView.swift:370-377, 476-484` — about 100 pt of empty plate
  between the question and its answers, from centring content in the intro-height sheet.
- **D3** `BTAlignmentNoteView.swift:42-47, 189-193` — a gold inline phrase reads as a
  link while the whole sentence is the button.
- **D5** `AlignmentPlateCell.swift:490-499` — one 10 pt radius makes a circle on the
  22 pt chip and a capsule on the 44×20 one.
