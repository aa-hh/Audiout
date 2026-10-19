# Colour for Settings, direction D revised

Comp: `comp.html`, the job-1 comp with colour applied, same frames.

## Audit

- Gold: audio state, calls to action, selection, completion. In Settings today: only the theme tiles and their selection ring.
- Green: Speakers tab only, "a little heavy-handed". `failure`: real failures, "NEVER BODY TEXT" per its doc comment. `ring`: the Mixer note banner's info tint.
- Off limits: permission hues, wizard stage hues, `muted`, `equalizer`. No warning token exists; the amber band belongs to gold.
- The Mixer shows the one-speaker note, a refused key, trial states and the takeover's needs-approval in its `.info` tier (`ring`); only dead routing, capture failure and a timed-out takeover get `failure` (`PopoverController.resolvedSystemAirPlayNote`).

## Strategy

Cool neutral, like the chassis. Words on grey; colour only where the Mixer already uses it for the same fact. All text stays on existing label inks. Dosage: one gold button per pane at most, one steel-blue glyph only while something needs the user. No Settings hue.

## Placements (each NEEDS ALEC'S YES)

| Placement | Role | Hex dark / light (Increase Contrast) | Contrast dark / light |
|---|---|---|---|
| Buy Audiout as `ProminentButton` (trial, unregistered) | the one call to action | fill `#E8B84B`, ink `#171104`, pinned in both | ink 10.18 / 10.18; fill on panel 9.74 / 1.77 (light edge comes from the stock bezel shading, as in onboarding) |
| Sidebar row glyph, readout needs action: Needs Login Items approval, Unregistered, Trial ended, Key refunded / Payment reversed / Key revoked, Key not recognized, Not an Audiout key | attention, non-text | `ring` `#7FB4C4` (`#9FC7D3`) / `#2C6E86` (`#265E73`) | sidebar 6.48 (8.13) / 5.01 (6.29). Selected pill 4.42 (5.54) / 3.92 (4.93). Floor 3:1 |
| License page header glyph, same states | the same mark, so the pane matches its row | same | panel 7.89 (9.91) / 5.47 (6.87) |
| Theme tile ring (shipped, kept) | selection | `gold` `#E8B84B` (`#F2C75E`) / `#E8B84B` (`#8A6614`) | panel 9.74 (11.21) / **1.77** (5.04) |

Readout text stays `labelCool` (6.92 / 6.21 on the sidebar); the words carry the state. The light tile ring fails 3:1 as shipped; the bold chosen label is the non-colour cue, and a deeper ring would be a second gold, so it is flagged, not changed.

## Rejected

- **A Settings tab hue.** It would only decorate words and stock controls; nearby hue bands are fenced. If wanted anyway, `ring` is the one free candidate, and the attention mark would need another colour.
- **Failure red on the one-speaker limit and "Key refunded".** Contradicts the Mixer's info tier for the same states, and fails as text: 3.78 dark sidebar, 2.57 dark pill.
- **A warning tone on Needs Login Items approval.** No warning token; amber is gold's; red overstates it. The Mixer's needs-approval uses `ring`, so this does too.
- **`ring` on the readout text.** Fails 4.5:1 on the selected pill (4.42 / 3.92).
- **Gold on Enter license… or Change….** One gold button per pane.

## Decisions for Alec

1. Settings stays without a hue of its own.
2. Buy Audiout becomes a gold `ProminentButton`. The licence gate puts gold on Register and keeps Buy Audiout stock, so the two would differ.
3. The `ring` glyph on rows and headers that need the user, in the listed states.
4. Accept or fix the light tile ring at 1.77:1.
5. Not drawn: a `failure` glyph on "Some speakers didn't reconnect", the one real failure in Settings?
