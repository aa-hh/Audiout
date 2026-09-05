# Warm Signal — screens follow-up (onboarding / groups / settings)

**Status: LOCKED by the owner 2026-07-22, sequenced AFTER the v4.1 popover build.** Captured from
the screen review so it isn't lost. These surfaces are file-disjoint from the popover spine.

## Onboarding / Setup
- **Bring back per-permission coloured icons** (the warm pass over-corrected them to neutral).
  Each permission (System Audio / Local Network / Remote Control / Speaker Sync) gets its own
  **distinct colour again — but WARM-HARMONIZED**: toned to sit on the warm canvas like Speaker
  Sync's gold, NOT the raw bright iOS systemBlue/Indigo/Purple. Colour + personality return while
  staying cohesive with the palette. Granted/enabled state still lights per the existing rule.
- Everything else on onboarding stays (copy, Speaker Sync naming, permission mechanics).
- (Separately still outstanding from earlier: the feature-intro reference page + contextual
  first-use hints — a distinct follow-up, not this batch.)

### Resolved — implementation record (2026-07-25)

Implemented in `AudioutCore/Sources/AudioutSharedUI/Tokens.swift` as four new
`Tokens.Color` cases, one per permission row, colour on the SF Symbol glyph only
(tile fill/rim stay `Tokens.Color.raised` + hairline, untouched):

- `permissionSystemAudio` — warmed off the retired `.systemBlue`, a "warm slate" (~210°)
- `permissionLocalNetwork` — warmed off the retired `.systemIndigo`, a "dusty plum" (~274-276°)
- `permissionRemoteControl` — warmed off the retired `.systemPurple`, a "muted mauve" (~321-324°)
- `permissionSpeakerSync` — moved into the gold family instead of a warmed teal, a deepened
  "brass" (~21-23°, strictly below the gold/amber reserved band's 28° floor)

Granting still crossfades the glyph to `Tokens.Color.gold` for all four rows, unchanged.

**Full 32-hex table** (dark / darkHighContrast / light / lightHighContrast, each token's Full and
Subtle column):

| Token | Column | dark | darkHighContrast | light | lightHighContrast |
|---|---|---|---|---|---|
| `permissionSystemAudio` | Full | `#75828F` | `#9FAEBD` | `#788B9E` | `#4B5B6B` |
| `permissionSystemAudio` | Subtle | `#6C7680` | `#8C98A3` | `#737D86` | `#4B535B` |
| `permissionLocalNetwork` | Full | `#816D8F` | `#A78FB8` | `#887199` | `#584366` |
| `permissionLocalNetwork` | Subtle | `#776882` | `#9988A6` | `#7A6E82` | `#4F4557` |
| `permissionRemoteControl` | Full | `#8C6D81` | `#BA95AC` | `#9E7890` | `#6B495F` |
| `permissionRemoteControl` | Subtle | `#806977` | `#A3899A` | `#86737F` | `#5B4A55` |
| `permissionSpeakerSync` | Full | `#916B54` | `#BD8D71` | `#8F634A` | `#613D29` |
| `permissionSpeakerSync` | Subtle | `#876A59` | `#A88672` | `#796356` | `#524036` |

(Every hex above was checked one-by-one against `Tokens.swift` and matches exactly.)

**Measured contrast** (WCAG 2.x relative luminance, >=3:1 required against BOTH
`Tokens.Color.panel` and `Tokens.Color.raised`, own theme, own column):

- `permissionSystemAudio`: Full dark `#75828F` 4.45:1 / 4.16:1; Full light `#788B9E` 3.31:1 / 3.51:1;
  Subtle dark `#6C7680` 3.78:1 / 3.53:1; Subtle light `#737D86` 3.96:1 / 4.19:1
- `permissionLocalNetwork`: Full dark `#816D8F` 3.76:1 / 3.51:1; Full light `#887199` 4.07:1 / 4.31:1;
  Subtle dark `#776882` 3.40:1 / 3.18:1; Subtle light `#7A6E82` 4.52:1 / 4.79:1
- `permissionRemoteControl`: Full dark `#8C6D81` 3.84:1 / 3.59:1; Full light `#9E7890` 3.57:1 / 3.79:1;
  Subtle dark `#806977` 3.50:1 / 3.27:1; Subtle light `#86737F` 4.15:1 / 4.40:1
- `permissionSpeakerSync`: Full dark `#916B54` 3.69:1 / 3.45:1; Full light `#8F634A` 4.89:1 / 5.18:1;
  Subtle dark `#876A59` 3.52:1 / 3.29:1; Subtle light `#796356` 5.31:1 / 5.63:1

All 32 authored hexes (including the HighContrast variants, not tabulated above) clear >=3:1
against both surfaces in every dial column/appearance combination.

**Reserved-band clearance**: every hue stays clear of the gold/amber window `[28°,68°)` (landing
in it would misread an ungranted row as already "granted") and the failure-red window
`[0°,12°) ∪ [350°,360°)`. Own-theme Full-column hues: `permissionSystemAudio` ~210°,
`permissionLocalNetwork` ~274-276°, `permissionRemoteControl` ~321-324°,
`permissionSpeakerSync` ~21-23° (deliberately just below the gold band's 28° floor, the same
terracotta corridor `AppTetherColor.steer` uses elsewhere). All four stay >=45° apart from each
other and from both reserved bands in every authored hex.

**Accent-dial rule** (resolved by a dedicated `permissionDynamic` function, a sibling of
`accentDynamic` — not a caller of it, since routing four distinct identity hues through
`accentDynamic`'s `.systemAccent` branch would collapse them all onto the same
`controlAccentColor`-derived value):
- **Subtle** dial position: resolves the authored Subtle column — the dial genuinely mutes
  these four.
- **Full gold** dial position: resolves the authored Full column.
- **Follow system** dial position: also resolves the authored Full column, i.e. these four stay
  at their full-gold-family authored hues and do NOT remap to the live system accent — unlike
  `gold`/`ember`/`glow`, which do.

This supersedes `dev/notes/warm-signal-v3.md` §5.8's "unify a warm-neutral resting state" clause
(per-permission colour is back, not a shared neutral) and extends §1.3 (the accent dial now has
four more dial-aware tokens, Subtle column only, alongside gold/ember/glow).

## Groups window — DONE
See: `fd77c79` (window-snapshot tool bug fix), `ffe966c` (sidebar Liquid Glass + warm tint),
`9b97984` (MembershipRowView.Surface split + BusRailOverlayView rail), `1aaf9ac` (MembershipWellView
well/hairlines), `06ee4b6` (elastic sections, 560×505 window, inline rename field), `d3d86c2`
(review-follow-up: device-pane insets, section padding, title-text centering, gold rail terminus).
Docs in `AudioutWindowUI/AGENTS.md` and `AudioutSharedUI/AGENTS.md`. Rules locked: text colors
frozen (contrast via surfaces only); row height 28pt (no slack for matching popover's 42pt); header
parity between the group editor and device-detail panes is enforced by test.

## Settings — DONE
See: `9760490` (General/Appearance/Audio tabs in a standalone window; panel sizing decoupled per
surface, closing the narrow-tall Groups bug) and `ad948ea` (two live-only sizing fixes found in
on-screen testing).
