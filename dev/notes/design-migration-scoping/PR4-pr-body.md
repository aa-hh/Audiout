# Design migration PR 4: the popover — banners, card chrome, Main Out row, splash, canvas

## Goal

Move the popover's own chrome onto PR 1's tokens, so the surface around the rows says the same thing the rows now say. The two note banners and the connection diagnosis card become one family (the tier's tint at 12 % on the control radius, no border); the card divider becomes `containerEdge` and a card title reads `goldText` while anything in that section is sounding; the Main Out row gets the readout font and inks PR 3 gave the device rows, plus the magenta chevron and identity glow that mark "Main Out is pointed at a saved group"; the splash sets "Audiout" in the wordmark face; `WarmCanvasView` loses its dead gradient; `GroupRowView` (no production consumer since 2026-07-16) is deleted. Sections, toolbar, status item, HUD and every geometry constant stay as they are.

## Decisions

- **D1 "Live" for a card title is computed by `PopoverController` from its own model**, never read back from a row's `test_` hook. System Audio = the Main Out row's own `armed || restingArmed`; Output Devices = any device row with live app feeds, or a connected, unmuted member of the active target under an unmuted master; App Routing = any route that is not excluded, not `.noRedirect`, and whose app is running. A test pins each predicate to the rows' rendered state (`test_routeArmed`, `test_isFaderEngaged`) so the two cannot drift silently.
- **D2 The title is retinted by re-setting its attributed string** — `makeLegendLabel` builds it with a `.foregroundColor` attribute, which beats `textColor`. Idle is `label2`.
- **D3 `warning` alias stays; `info` retires.** `info`'s last consumers were the note banner and its tests, both re-pointed here. `warning` is still read by Settings, whose PR owns that file. The severity cases keep their names `.info`/`.warning` — they are tiers, not colours; only what each returns changes.
- **D4 Banner recipe (iOS "Status Banners"):** fill = tint at 12 % (`failure` for the silence banner and the note banner's `.warning` tier, `ring` for `.info`), no border, radius `Radius.control`. A banner is an inset control-sized rect, not a row or a panel. `Layout.bannerCornerRadius` (11) loses both consumers and is deleted.
- **D5 The diagnosis card's radius 7 → `Radius.control`**, so the three inset cards share one corner.
- **D6 The destination pop-up goes borderless; the chevron carries the tint.** `contentTintColor` cannot reach a bordered pop-up's arrow (the bezel draws it), and a bezel that came and went with the target would jump. Borderless, the tint reaches title AND arrow — so the display-only cell item now always carries an attributed title in `Tokens.Color.label`, keeping the magenta off the words (iOS: never magenta on text). The tint is `partyRampDeep` on a group target, `label2` otherwise. `partyRampDeep`, not `party`: `party` measures 1.93:1 on the light ground, under the 3.0 graphic floor.
- **D7 The seat glow is one shared view, `GroupIdentityGlowView` (`AudioutSharedUI`)** — the Mac mirror of iOS `GroupIdentityGlow`: a radial `CAGradientLayer` backing layer, `partyRampDeep` at 22 % (dark) / 10 % (light) clearing to nothing at the edge. Because the gradient IS the backing layer, its unit-coordinate falloff scales with the mounted size, so PR 5 can mount it at 60 and 80 without a second recipe. Non-interactive, invisible to VoiceOver.
- **D8 Main Out readout:** `Tokens.Font.readout` with `goldText` while the fader's own gold predicate holds (connected ∧ unmuted), else `emberText` — so the number and the fill on the same row always agree.
- **D9 Splash wordmark 31 pt** — iOS sets 32 pt against a 100 pt mark; the Mac mark is 96 pt, so 96 × 0.32 = 30.72 → 31.
- **D10 `WarmCanvasView`'s gradient branch is deleted** (dead since PR 1 aliased `canvasHi == canvas`): flat `canvas`, dark-only grain, flatten branch untouched.
- **D11 The divider class is renamed `CardDividerView`** and stamps `containerEdge`: it crosses bare canvas and is the section's own boundary. The old name would lie about the token.
- **D12 `GroupRowView` is deleted** with its test file; `PopoverIconTests` loses its three group-row tests and `expectedGroupIcon`.

## Requests to PR 3, done here

PR 3 merged without deleting `PopoverColumnGrid.readoutTrailing`, whose sole consumer was `GroupRowView.swift:218`. Per the work order's fallback clause, PR 4 deletes it and drops the `GroupRowView` clauses from that file's doc comments. `sliderTrailing` stays (four consumers).

## Interim visible effects this PR finalises and introduces

Finalised: `warning→failure` on both banners' problem tier (Settings' two notes stay on the alias — its own PR) · `info→ring` on the note tier, alias deleted · `canvasHi→canvas`, gradient code gone, alias deleted.

Introduced: card dividers in `containerEdge` · card titles gold while their section sounds · Main Out readout in `Font.readout`, gold/ember · a borderless destination picker whose arrow is `label2`, or magenta on a group target · a magenta identity glow behind the Main Out icon on a group target · banners at 12 % with no border and a 10 pt corner, sharing the diagnosis card's corner · the splash wordmark at 31 pt in Clash Display (system bold until a dev build assembles the `.app`).

## Snapshots

`dev/notes/popover-snapshots/*.png` regenerated (22 files, no new files). `window-snapshots`, `onboarding-snapshots`, `settings-snapshots`, `wizard-snapshots` untouched.

## Known deviation

`AudioutSharedUI/AGENTS.md` lands at **304 words**, over the repo's 300-word cap. The work order budgeted a 10-word Map entry against four named rewrites, but PR 3 had already spent that slack: all four rewrites applied leave the file at 304 (299 → 309 → 304). No fifth trim was invented.

## Owed checks (dev build)

- The wordmark renders in Clash Display at 31 pt against the 96 pt mark.
- The borderless picker: does the Main Out row still read as a control without its bezel?
- The magenta glow behind the bare Main Out glyph (the Mac row has no opaque seat) — too much core, or right?
- Gold card titles when only a live app feed arms a row.
- Banners at 12 % with no border on the light ground (1.20 / 1.18:1 — edge-less by design).
