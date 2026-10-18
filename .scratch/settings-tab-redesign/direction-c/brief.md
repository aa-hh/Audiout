# Direction C: rear panel of the desk

Thesis: Settings stops being three pages behind a sidebar and becomes the back of the box, one page where every setting sits in a labelled group, laid out in the order sound travels.

Comp: `comp.html` in this folder (frame 1 is the primary view, frames 2 to 8 are the states that differ).

## Assumptions

Nobody could answer the discovery interview, and this agent has no structured question tool, so these stand in for answers. Each is a guess Alec can overturn.

- People open Settings rarely and for one thing: launch at login, the theme, the licence, the iPhone. Seeing everything at once beats remembering which of three pages holds it.
- The four directions replace impeccable's concept-seed roll: the world is settled (DESIGN.md), only composition is open, and the orchestrator dealt this composition.
- "Match the Mixer and Speakers tabs" means sharing their pieces (the Mixer's unboxed groups, the Speakers page's "Available" label and rule, the speaker page's `.well`), not copying one tab's layout.
- Removing the sidebar is allowed. Direction B also drops it; constraint 2 only binds a sidebar that stays.

## 1. Job and audience

A household Mac user with two or more speakers, already past setup, who wants to change one behaviour or check whether their copy is paid for. They are not mid-playback panic; volume and mute stay on the Mixer. Secondary: the hi-fi listener who goes looking for the buffer.

## 2. Outcome and proof

Success is finding any setting without choosing a page first. Proof inside the product: the six groups carry every row in inputs.md's inventory, verbatim, and nothing else. The one product-specific truth the page shows that a generic settings screen cannot is the signal path: what enters the desk (apps kept local), what leaves it (how speakers connect, wake and idle), then who else can drive it.

## 3. Selected direction

**Structure.** No sidebar. One scrolling page under the header strip: two 335 pt columns on a 14 pt margin and 15 pt gutter, then one full-width section across the bottom.

| Left column: the signal | Right column: the desk's own controls |
|---|---|
| **Source**: Apps that stay on this Mac | **Power**: Launch at login, Reconnect last speakers when Audiout starts |
| **Output**: Volume when connecting a speaker, Restore Mac audio if speakers don't reconnect, Keep Bluetooth speakers streaming during pauses, Advanced (Audio buffer) | **Control**: Allow control from iPhone, the Audiout Remote invitation and QR tile, Remembered iPhones, Use Audiout's Touch Bar controls |
| | **Appearance**: Theme tiles, Accent |

Across the bottom, I'll call this section **the plate**: nameplate "Audiout", holding the licence status and its buttons on the left, the two things that phone home on the right (Share anonymous usage statistics, and the licence check-in sentence), and Run setup again…, About Audiout…, Check for Updates… along its foot.

**Why two columns earn their place.** At full width a hint line runs about 120 characters, well past a readable measure; at 335 pt it runs about 55 to 60. Each group is two to four rows, so none needs the width. Side by side, the whole tab fits in roughly 890 pt in the primary state, so a sidebar has nothing left to do.

**How far console flavour goes.** Flavour lives in the form, never in new words:

- Each group opens with a nameplate: the "Available" arrangement from the Speakers page (`captionEmphasized` in `label2`, 8 pt, then a 1 pt `hairline` rule to the column edge). Nameplate words are the app's own: "Source" and "Output" are the Mixer's column legends; "Power", "Control" and "Appearance" are household words found on the back of any amplifier; "Audiout" is the model name a serial plate carries.
- The layout follows the signal: sound enters top left and leaves below it.
- Numbers sit in the existing readout well, beside a full-width slider, the Mixer's slider-then-readout order.
- The plate is the one recessed box, `.well`, like the Equalizer on the speaker page.

Where it stops being native, refused on purpose: uppercase or letter-spaced nameplates (One Case), monospaced labels, screws, brushed metal or any texture, fake sockets or lamps as state, a custom knob instead of the stock slider, anything from the alignment wizard's stage (fenced by the Instrument Ground Rule), a hue per group, and console words in row titles ("latency", "bus", "buffer size"). Every row title, hint, button and state keeps today's household wording.

**Focal moment.** The plate. It is the only filled box on the page, so the licence state reads first when it matters (trial, unregistered, refused) and sits quiet when it does not.

**Hue: Settings stays neutral** (recommendation; Alec decides). The back of a box has no lamps: Mixer is gold, Speakers is green, Settings changes no sound and gets no hue. Gold appears once, on the selected theme tile's ring, which is its selection job.

## 4. Scope and boundaries

- Fidelity: direction comp plus brief. No Swift.
- Untouched: the header strip, every row's wording and behaviour, the About window, the licence sheet (still opened by Enter license… / Change…), the theme tiles' drawing.
- Anti-goals: a settings page that reads as a hardware skin; any state carried by colour alone; anything that grows the 713 pt width.

## 5. States and ranges

Drawn in the comp:

| State | Where | Frame |
|---|---|---|
| Registered; iPhone control on, no phone yet (QR shown); Advanced folded; no Touch Bar | whole tab | 1 |
| Trial, 9 days left | plate | 2 |
| Unregistered (no key, no check-in sentence, statistics on by default) | plate | 3 |
| Key saved, never verified (Check again on the status line) | plate | 4 |
| Key refused, with the server's reason | plate | 5 |
| iPhone control off (invitation gone) | Control | 6 left |
| Phones remembered (QR gone, address and button kept; Allowed / Denied; remove), Touch Bar present | Control | 6 right |
| Login Items approval needed | Power | 7 left |
| A launch option forces iPhone control (switch disabled, note) | Control | 7 right |
| Advanced open, buffer just changed, "Reconnecting speakers…" | Output | 8 |

Not drawn, behaviour stated:

- Touch Bar absent (most Macs): the row is absent; Control is then the iPhone rows alone.
- A build with no companion: no iPhone rows. With no Touch Bar either, Control disappears and the right column is Power over Appearance.
- A build from source (no licence server): the plate keeps usage statistics and the three foot buttons and loses the status, its buttons and the check-in sentence. This is why the nameplate says "Audiout", not "License".
- Check for Updates… hidden where the build has no updater, as today.
- Restore Mac audio row absent when the app injects no wake-restore option (why the headless render lacks it).
- Advanced absent when the backend cannot change the buffer.
- Ranges: 0 to about 6 excluded apps and 0 to about 4 remembered phones before the right or left column scrolls past the surface ceiling. Height in the primary state is about 890 pt, taller than the Mixer's 711; on a 13-inch MacBook Air the plate's foot may reach the screen clamp and scroll.

## 6. Interaction and layout

- **Row anatomy, one rule for every row:** title and its control share the first line (the control centred on the title's first line); the hint runs the group's full width beneath, in `caption` / `label2`, wrapping freely. 9 pt above and below, 44 pt minimum, `hairline` divider between rows: `ListRowView`'s rhythm.
- **Lists** (apps kept local, remembered iPhones): a `.card` of `ListRowView` rows at the `row` radius, 14 pt lane, app icon or no glyph, trailing remove button; "Add app…" is a click-through row with `plus.circle` in `label2` (never green, which belongs to the Speakers tab).
- **The plate:** `.well`, `radiusOverride` = `row` (16 pt), so the page carries one corner. Inside, a vertical 1 pt `containerEdge` rule on the page's gutter splits licence from small print; a `containerEdge` rule above the foot. The status sentence is `body` / `label`, the plate's headline.
- **Motion:** only Advanced folds, on `FoldAnimator` through `FoldingClipView`; under Reduce Motion it lands at once. Nothing else moves.
- **Reading and keyboard order:** left column top to bottom, then the right column, then the plate. Each column is one vertical stack, so VoiceOver and Tab follow it. Every nameplate is a VoiceOver heading (Titles Are Headings); each group is an accessibility group named by its nameplate.
- **Opening:** the page always opens scrolled to the top.

## 7. Constraints, components and open decisions

**Reused as they are:** `RuleView` (nameplate rule, plate rules, vertical rule as the Speakers counts strip already uses one), `GroupedSectionView` `.bare` (its first user: every group but the plate), `.card` (the two lists), `.well` (the plate), `ListRowView` (list rows), `SettingsForm.readoutWell`, `FoldingClipView`, `RemoteInviteView` at 72 pt, the theme tiles, stock `NSSwitch`, `NSPopUpButton`, `NSSlider`, radio and rounded buttons, `WarmPanelView` as the ground.

**Changed:**

1. `SettingsRootViewController`: the split view goes. One scroll view holds a two-column stack and the plate. The three pane controllers become builders of their groups (General gives Power, Control and the plate; Audio gives Source and Output; Appearance gives Appearance) and keep their state logic.
2. `GroupedSectionView`, `ListRowView` and `FlippedView` move from `AudioutWindowUI` to `AudioutSharedUI`. They are `internal` today, and `AudioutSettingsUI` depends only on `AudioutCore` and `AudioutSharedUI` (`Package.swift`).
3. `SettingsForm.row`: the hint moves from under the title to the full row width, and padding becomes 9 pt with a 44 pt minimum.

**New custom-drawn piece:** none. The allowance goes unspent.

**Rules this breaks, which Alec must approve:**

- DESIGN.md Layout ("Settings is a sidebar-plus-pane split, never tabs") and `AudioutSettingsUI/AGENTS.md` ("Sections are sidebar rows"). New rule: a new setting joins a group; a new group takes a slot in a column.
- Analytics: `settings:pane_selected` stops firing, since there are no panes. The event's dashboard loses its stream.
- Tests built on the split go: `selectSection(at:)`, `test_sidebarSplitItem`, the pane-host tests.

**Open decisions for Alec:**

1. Drop the sidebar for one two-column page? (The direction rests on this.)
2. Settings hue: neutral, as recommended, or a hue role. This direction argues neutral.
3. Nameplate words: Source, Output, Power, Control, Appearance, Audiout. Yes, or other words.
4. Usage statistics on the plate beside the check-in sentence, grouped as "what this copy sends home", instead of among the switches.
5. The trial line. Reading `GeneralSettingsViewController.refreshLicenseStatus` with `AppSettings.licenseUnregistered`, a verified trial key appears to show "Registered. Thank you for supporting Audiout.", "Change…" and no Buy Audiout; an unverified one shows "Your key is saved…". Both misstate a trial. The comp shows the Mixer pill's own words ("Trial · 9 days left") with Enter license… and Buy Audiout. That is a behaviour fix whichever direction wins and needs Alec's yes on the wording.
6. Accept a tab about 180 pt taller than the Mixer, scrolling on 13-inch screens, in exchange for no navigation.

**Noted while copying the renders:**

- The shipped header strip carries a centred "Audiout" brand lockup (`mixer-speakers-*.png`, and DESIGN.md calls it decorative), while inputs.md says "no brand lockup". The comp copies the render.
- inputs.md places "Reconnecting speakers…" under the Restore Mac audio pop-up; the code shows it after an Audio buffer change (`AudioSettingsViewController`, apply status). The comp puts it under the buffer.
- Stock switches, radios and the slider are drawn grey, as in the renders. The surface panel is activating (`ControlPanelWindowController`), so live they take the Mac's accent colour. That holds for every direction.
