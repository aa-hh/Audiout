# The record catches up with the pixels

Status: ready-for-agent
Closes: D8, D10

No user sees any of this; the next agent builds on it.

- **D10** `WarmCanvasView.swift:19-28`, `AlignmentWizardViewController.swift:155-274` —
  the dark-only canvas grain (measured: 72 distinct colours, per-channel σ≈3 in a flat
  300×50 region) and `RoomSpillView`'s two washes (green left, steel blue right, 0.10
  alpha, dark only) are on screen and nowhere in DESIGN.md; both cite
  `dev/notes/warm-signal-v3.md`, which root AGENTS.md demotes to "the historical spec,
  not the authority". **Ruling:** record both in DESIGN.md under Elevation and Depth —
  alphas, dark-only scope, and which accessibility switches drop them (Reduce
  Transparency, Increase Contrast, Reduce Motion).
- **D8** `EQResponseCurveView.swift:84-93` — a 6 pt corner and nine bare constants with
  no reason recorded, in a file where every constant above them carries one. Take
  `Radius.control` (10), or keep 6 and say why in one line as the Equalizer door's own
  6 is justified in DESIGN.md.

Also fold in while here: `Tokens.Color.glow`'s consumer list stays as written once the
finale's resting aura is dropped (see 05), and DESIGN.md's Scope Instrument Rule needs
the gold gridline removed (see 07).
