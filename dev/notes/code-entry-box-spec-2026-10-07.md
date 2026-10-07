# Code entry box spec (2026-10-07)

What Apple and Google ship for one-character code boxes, and what the Mac AirPlay code sheet adopted.

## Apple: macOS AirPlay code prompt

Read from `/System/Library/CoreServices/AirPlayUIAgent.app/Contents/Resources/Base.lproj/AirPlayUIAgentPINUI.nib` (and `AirPlayUIAgentSixDigitPINUI.nib`) with `strings`; values are the archived frames.

- Four (or six) separate secure fields, each 28×28 pt, on a 34 pt pitch: 6 pt gap.
- Font: the Title2 text style.
- Each box carries `layer.borderWidth` and `layer.cornerRadius` runtime attributes: a drawn edge and rounded corners, not the stock bezel.
- The text frame inside each box is `{{1, 4}, {26, 21}}`: a 21 pt line set 3.5 pt from top and bottom, so the digit sits centred vertically.

## Google: Material 3 text field

Sources: Flutter's generated Material 3 tokens (`dev/tools/gen_defaults/data/text_field_outlined.json`, flutter.googlesource.com) and the Compose `OutlinedTextField` reference (developer.android.com).

- Outlined field: 1 dp outline at rest, 2 dp when focused.
- Container shape: corner extra-small (4 dp).
- Minimum height 56 dp.
- Outline colour is the `outline` role, chosen to hold 3:1 against the surface; focus uses `primary`, error uses `error`.

## Accessibility floor

WCAG 2.2 success criterion 1.4.11 (non-text contrast): the visual boundary that identifies an input needs 3:1 against adjacent colours.

## Adopted for Audiout

Mapped onto DESIGN.md tokens; no new colours.

| Property | Before | After |
|---|---|---|
| Size | 52×48 pt | 52×48 pt (kept; 24 pt digit needs it, between Apple's 28 pt and Material's 56 dp) |
| Gap | 8 pt | 8 pt (kept) |
| Fill | stock bezel background | `well` (#050507 dark / #E9EAEC light) |
| Edge | stock bezel, under 3:1 on the sheet | 1 pt `rim` (#6B767D dark / #66717A light; IC #818B90 / #586269): 4.38:1 on `well` dark, 4.15:1 light, 5.85:1 / 5.18:1 under Increase Contrast |
| Radius | stock square bezel | `Tokens.Layout.Radius.control` (10 pt) |
| Focus | system focus ring | system focus ring, masked to the rounded shape (gold stays off focus, per DESIGN.md) |
| Error | result line in `failure` red | unchanged |
| Digit | 24 pt medium monospaced, top-aligned | same font, centred horizontally and vertically (digit, caret, field editor) |
