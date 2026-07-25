# AudiouterOnboardingUI

## Purpose

The first-run permission flow: `OnboardingViewController` and its rows
(`PermissionRowView`, `PTPHelperRowView`) walk the user through granting
System Audio, Local Network, Remote Control, and Speaker Sync. Rows are pure
UI — they report taps out, they never read TCC/permission state themselves.

## Rules

- The four permission tile colours (warmed per-row hue, plus Speaker Sync's
  gold family) live ONLY in `Tokens.Color` — never hardcode an `NSColor`.
- The colour applies to the SF Symbol GLYPH only, via `IconTileView`'s
  `color` init param. The tile fill and rim stay `Tokens.Color.raised` /
  hairline regardless of row — do not colour the tile itself.
- Granting a permission always crossfades the glyph to `Tokens.Color.gold`,
  for all four rows alike — a deliberate exception to per-row colour, not a
  bug; don't "fix" a granted row to light its own resting hue instead.
- The four resting tints are dial-aware in `.subtle` only, and must never be
  routed through `accentDynamic` — that helper collapses distinct hues to
  one accent, erasing the point of giving each permission its own colour.
- The gold crossfade (`setLit`) already skips under Reduce Motion and when
  the row isn't on a visible window; keep both guards so snapshots stay
  deterministic.
- `PermissionRowContent.iconColor` has no default — every call site must
  pick a colour explicitly rather than inherit a stale one.
- `iconTile` on `PermissionRowView`/`PTPHelperRowView` is `private`; reach
  its `test_restingTint`/`test_litTint`/`test_fillColor` hooks only from
  within those files, not by widening visibility for outside tests.

## Map

| Type | What it is |
|---|---|
| `OnboardingViewController` | Orchestrator: builds/sequences the permission rows. |
| `PermissionRowView` | One permission row: icon tile, label, grant control. |
| `PTPHelperRowView` | Speaker Sync's row, driven by `PTPHelperStatus`. |
| `IconTileView` | Neutral tile + tinted glyph, shared resting/granted look. |
