# Design migration PR 4: the popover — banners, card chrome, Main Out row, splash, canvas

## Goal

Move the popover's own chrome onto PR 1's tokens, so the surface around the rows says the same thing the rows now say. The two note banners and the connection diagnosis card become one family (the tier's tint at 12 % on the control radius, no border); the card divider becomes `containerEdge` and a card title reads `goldText` while anything in that section is sounding; the Main Out row gets the readout font and inks PR 3 gave the device rows, plus the magenta chevron and identity glow that mark "Main Out is pointed at a saved group"; the splash sets "Audiout" in the wordmark face; `WarmCanvasView` loses its dead gradient; `GroupRowView` (no production consumer since 2026-07-16) is deleted. Sections, toolbar, status item, HUD and every geometry constant stay as they are.

## Decisions

- **D1 "Live" for a card title is computed by `PopoverController` from its own model**, never read back from a row's `test_` hook. System Audio = the Main Out row's own `armed || restingArmed`; Output Devices = any device row with live app feeds, or a connected, unmuted member of the active target under an unmuted master; App Routing = any route that is not excluded, not `.noRedirect`, and whose app is running. A test pins each predicate to the rows' rendered state (`test_routeArmed`, `test_isFaderEngaged`) so the two cannot drift silently.
- **D2 The title is retinted by re-setting its attributed string** — `makeLegendLabel` builds it with a `.foregroundColor` attribute, which beats `textColor`. Idle is `label2`.
- **D3 `warning` alias stays; `info` retires.** `info`'s last consumers were the note banner and its tests, both re-pointed here. `warning` is still read by Settings, whose PR owns that file. The severity cases keep their names `.info`/`.warning` — they are tiers, not colours; only what each returns changes.
- **D4 Banner recipe (iOS "Status Banners"):** fill = tint at 12 % (`failure` for the silence banner and the note banner's `.warning` tier, `ring` for `.info`), no border, radius `Radius.control`. A banner is an inset control-sized rect, not a row or a panel. `Layout.bannerCornerRadius` (11) loses both consumers and is deleted.
- **D5 The diagnosis card's radius 7 → `Radius.control`**, so the three inset cards share one corner.
- **D6 The destination pop-up stays bordered and its arrow keeps the stock tint.** The first cut of this PR went borderless so `contentTintColor` could reach the arrow (a bordered pop-up's bezel draws it), and tinted it magenta on a group target. Review caught two problems and it was reverted: a borderless `NSButton` silently discards `drawFocusRingMask`, so keyboard focus on this control becomes invisible — the trap this repo already documents at `AlignmentPlateButton.swift:38`, on a popover that does take key focus — and without the bezel the title and arrow sat ~75 pt apart with bare ground between them, so it stopped reading as one control. The group's magenta is carried on this row by the identity glow and the `→ <group>` title. What survives: the display-only cell item with an attributed title in `Tokens.Color.label`, now also carrying a tail-truncating paragraph style, because an `attributedTitle` makes the cell ignore its own `lineBreakMode` and a long group name would otherwise clip mid-word.
- **D7 The seat glow is one shared view, `GroupIdentityGlowView` (`AudioutSharedUI`)** — the Mac mirror of iOS `GroupIdentityGlow`: a radial `CAGradientLayer` backing layer, `partyRampDeep` at 22 % (dark) / 10 % (light) clearing to nothing at the edge. Because the gradient IS the backing layer, its unit-coordinate falloff scales with the mounted size, so PR 5 can mount it at 60 and 80 without a second recipe. It carries the folder's live accessibility-display observer, since Increase Contrast is not part of the effective appearance. Non-interactive, invisible to VoiceOver.
- **D8 Main Out readout:** `Tokens.Font.readout` with `goldText` while the fader's own gold predicate holds (connected ∧ unmuted), else `emberText` — so the number and the fill on the same row always agree.
- **D9 Splash wordmark 31 pt** — iOS sets 32 pt against a 100 pt mark; the Mac mark is 96 pt, so 96 × 0.32 = 30.72 → 31.
- **D10 `WarmCanvasView`'s gradient branch is deleted** (dead since PR 1 aliased `canvasHi == canvas`): flat `canvas`, dark-only grain, flatten branch untouched.
- **D11 The divider class is renamed `CardDividerView`** and stamps `containerEdge`: it crosses bare canvas and is the section's own boundary. The old name would lie about the token.
- **D12 `GroupRowView` is deleted** with its test file; `PopoverIconTests` loses its three group-row tests and `expectedGroupIcon`.

## Requests to PR 3, done here

PR 3 merged without deleting `PopoverColumnGrid.readoutTrailing`, whose sole consumer was `GroupRowView.swift:218`. Per the work order's fallback clause, PR 4 deletes it and drops the `GroupRowView` clauses from that file's doc comments. `sliderTrailing` stays (four consumers).

## Interim visible effects this PR finalises and introduces

Finalised: `warning→failure` on both banners' problem tier (Settings' two notes stay on the alias — its own PR) · `info→ring` on the note tier, alias deleted · `canvasHi→canvas`, gradient code gone, alias deleted.

Introduced: card dividers in `containerEdge` · card titles gold while their section sounds · Main Out readout in `Font.readout`, gold/ember · a magenta identity glow behind the Main Out icon on a group target · banners at 12 % with no border and a 10 pt corner, sharing the diagnosis card's corner · the splash wordmark at 31 pt in Clash Display (system bold until a dev build assembles the `.app`).

## Snapshots

`dev/notes/popover-snapshots/*.png` regenerated (22 files, no new files). `window-snapshots`, `onboarding-snapshots`, `settings-snapshots`, `wizard-snapshots` untouched.

## Known exception

The App Routing title reads the stored `route.destination`; the row reads its own popup entry. If a routed speaker leaves discovery entirely the row falls back to the standalone entry (unarmed fader) while the stored destination is still a `.device`, so the title can stay gold over a silent row. Title tint only, accepted.

## Owed checks (dev build)

- The wordmark renders in Clash Display at 31 pt against the 96 pt mark.
- The magenta glow behind the bare Main Out glyph (the Mac row has no opaque seat) — too much core, or right?
- Gold card titles when only a live app feed arms a row.
- Banners with no border: on the light ground they measure 1.20 / 1.18:1, and on the dark canvas 1.106 (`failure`) / 1.230 (`ring`) — the weakest cells of the four, edge-less by design, worth one look.
- A fresh install opens with "System Audio" gold above a Main Out row whose fader, dot and readout are all cool. That is correct — local-only playback is genuinely sounding, and the dot means "a remote route is armed" — but the pairing should get an eye.
