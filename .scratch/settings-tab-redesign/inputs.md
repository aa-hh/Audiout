# Settings tab redesign — shared inputs for the four direction agents

Written 2026-10-06 by the orchestrating session. Every direction agent reads this first.

## The ask (Alec, verbatim)

> i want to reshape the settings tab to better match the mixer and speakers tabs. run 4 divergent design each using /impeccable shape. make sure they load impeccable context to retrieve the design system and components we have already in place and use that as a base. from there they can use their own creativity to make the screen feel distinct yet still a clear part of the same app.

## What exists today

The one surface (713 pt wide popover, pinnable) has four screens behind icon-only header tabs: Mixer, Scenes, Speakers, Settings. Settings is a sidebar-plus-pane split (`SettingsRootViewController`): a 210 pt source-list sidebar with a "Settings" group header over three rows (General, Appearance, Audio), and a pane host on `WarmPanelView` that scrolls a top-aligned pane. The panes are built with `SettingsForm` (`AudioutSettingsUI/SettingsForm.swift`): label + hint + stock control rows, 20 pt horizontal / 18 pt vertical padding, no cards, no page header, hairline rules between groups.

Fresh renders of the shipped screens (current code, light and dark) are in
`/private/tmp/claude-501/-Users-alechenderson-Projects-AirPlay-Controller--claude-worktrees-settings-tab-redesign-0dd6a3/56fca726-cb34-461a-b551-4973e32df05d/scratchpad/shots/`:
- `settings/settings-{general,appearance,audio}-{dark,light}.png` — the three panes as shipped, pane only (the headless render leaves out the iPhone companion rows and Check for Updates; read the code for those).
- `speakers/mixer-speakers-{dark,light}.png` — the Speakers tab inside the full surface, header strip included. This is the geometry reference for the sidebar split.
- `speakers/mixer-mixer-{dark,light}.png` — the Mixer inside the full surface. This is the reference for card headers, row grammar and gold.
- `speakers/mixer-scene-cards-*.png`, `mixer-scene-editor-*.png` — the Scenes tab, for the card field and editor page.
- `mixer/popover-*.png` — more Mixer states.
Look at them before anything else; the checked-in goldens under `dev/notes/*-snapshots/` are stale and must not be regenerated.

### Content the redesign must carry (nothing dropped, nothing invented)

**General** (`GeneralSettingsViewController.swift`)
- Launch at login (switch) — plus a conditional "macOS needs you to allow Audiout in Login Items." hint with an Open Login Items… button.
- Reconnect last speakers when Audiout starts (switch) with a live hint line.
- Use Audiout's Touch Bar controls (switch, only on Macs with a Touch Bar).
- Allow control from iPhone on this network (switch) + the companion rows: the list of phones that asked (name, Allowed / Denied), and the invitation row with "Open <address>" to the Audiout Remote page plus its QR tile. Read the file for the exact rows and the states (no phones yet, phones listed, remote off).
- Share anonymous usage statistics (switch) with a hint.
- License row: Enter License… / Buy Audiout buttons, a status hint that reads differently per state (unregistered, trial with days left, registered, refused with reason, offline/unverified), a Check again small button, and a check-in disclosure hint.
- Footer buttons: Run setup again…, About Audiout…, Check for Updates….

**Appearance** (`AppearanceSettingsViewController.swift`)
- Theme: three custom-drawn tiles (Light, Dark, Match System) with a gold selection ring; the tiles use absolute sRGB mirrors of the palette.
- Accent: two radio buttons (Full gold, Subtle) with a hint.

**Audio** (`AudioSettingsViewController.swift`)
- Apps that stay on this Mac: an editable list of excluded apps (Add app… from running apps or Choose from Finder…, remove).
- Volume when connecting a speaker: slider with a readout well and hint.
- Restore Mac audio if speakers don't reconnect: pop-up with hint; shows "Reconnecting speakers…" while it works.
- Keep Bluetooth speakers streaming during pauses: pop-up with hint.
- Advanced (disclosure, collapsed by default): Audio buffer pop-up of bare millisecond values with hint; only rendered when the backend supports it.

**About** (`AboutView.swift`) and the **licence sheet** (`LicenseSheetViewController.swift`) open from General; they are out of scope unless your direction changes how they are reached.

## Hard constraints (from DESIGN.md, PRODUCT.md, folder AGENTS.md and owner rulings)

1. **Stock AppKit.** Custom drawing is a short named list; a direction may propose at most one new custom-drawn piece and must say why no stock control does the job.
2. **Surface geometry is fixed.** 713 pt wide. If a sidebar stays it is 210 pt and never collapses (it is the only way to change section). Height flows from content with a ceiling; the pane scrolls.
3. **Header strip is untouchable.** Icon-only tabs, Pin, no brand lockup. Settings is one of the tabs; the strip is not part of this redesign.
4. **Colour.** Gold = audio state, calls to action, selection, completion. Green (`speakersAccent`) = the Speakers tab's accent, ruled 2026-10-04 and then called "a little heavy-handed", so sparing. **Settings has no accent of its own today and giving it one is an open decision Alec has to make.** You may propose one hue role for Settings with a one-line rationale, marked `NEEDS ALEC'S YES`; you may equally argue Settings stays neutral. Permission hues (six identity colours) are fenced to onboarding and may not appear here. Never `systemGreen`, never a second gold.
5. **Voice.** Console flavour on chrome only (section nameplates, fixed labels). Anything the user decides on reads in plain household speech. Sentence case everywhere, never transformed.
6. **Both appearances, Increase Contrast, Reduce Motion, VoiceOver parity.** Light is one flat `#FAFAFB` ground where separation is edge weight, not fill; dark is the canvas → panel → raised ladder.
7. **Shared components are the base.** Reuse before inventing: `PageHeaderView` (48 pt icon well + heading + caption), `GroupedSectionView` (`.card` / `.well` / `.bare`), `ListRowView` (glyph, title, caption, trailing accessory, 44 pt min), `CardMessageRow`, `TextLinkButton`, `TintedNoteBackgroundView`, `RuleView`, `FoldingClipView`, `noteLabel`, the Speakers sidebar plates, the Mixer card header. Read their sections in DESIGN.md (Components) and the source in `AudioutCore/Sources/AudioutWindowUI/` and `AudioutSharedUI/`.
8. **No new terms.** Call things what the code and DESIGN.md call them. If your direction needs a name for a new piece, say "I'll call this X" once and keep it to the brief.
9. **No code.** `shape` ends at a brief. You produce a brief and a visual comp, nothing in Swift.

## Divergence

Each agent gets one structural seed below so the four do not converge. The seed is a starting constraint, not the design: take it and push it as far as the constraints allow. Name your direction by its mechanism, not a slogan.

- **A — Speakers twin.** Keep the sidebar split and make Settings read as the Speakers tab's sibling: sidebar plates, `PageHeaderView` per section, `GroupedSectionView` cards of `ListRowView` rows. The question is what Settings does with that grammar that Speakers does not.
- **B — Mixer grammar, no sidebar.** Drop the sidebar. One scrolling page of cards with Mixer-style card headers, every setting a row with its control on the trailing column. The question is how three sections and a licence state live on one page without a nav.
- **C — Rear panel of the desk.** The hardware voice: Settings as the back of the mixing console, grouped by signal path (what comes in, what goes out, who can reach the desk, the licence plate). Nameplates on chrome, plain speech on controls. Two columns across the 713 pt if it earns them. The question is how far console flavour can go before it stops being native.
- **D — Status spine.** The sidebar (or its replacement) carries live state, not just names: each section row shows its one-line readout (licensed, remote on, 2 apps kept local), and the pane is where you change it. Borrows the shape of onboarding's status spine without its hues. The question is whether Settings can tell you what is set before you click anything.

## Deliverables (per agent, under `.scratch/settings-tab-redesign/direction-<letter>/`)

1. `brief.md` — the shape brief (shape.md Phase 3), assumptions marked plainly since nobody can answer the discovery interview. Include: which shared components each region reuses, which existing component changes (and the change), any new piece and its justification, every open decision Alec must make, and the states covered (licence states, remote off/on/no phones, Advanced open/closed, Touch Bar absent).
2. `comp.html` — one self-contained HTML file, no external requests, that draws the whole 713 pt surface (header strip included, drawn faithfully from the Speakers render) showing Settings in your direction, **dark and light side by side**, at 1x CSS pixels. Use the DESIGN.md hex values and the SF system font stack. Show General as the primary view; add Appearance and Audio as further frames below if the layout differs per section, and one frame for the licence-trial state. Static is fine; no JS needed. This is what Alec picks from, so it must be truthful to AppKit: stock switch, pop-up, slider, button and source-list looks, nothing a web page can do that AppKit cannot.
The orchestrating session screenshots every comp afterwards; do not open a browser yourself.

Report back with: the direction's one-line thesis, the open decisions list, the files written, and anything in the constraints you could not honour and why.
