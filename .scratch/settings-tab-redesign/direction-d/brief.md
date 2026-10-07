# Direction D: status spine, shape brief

Settings sidebar rows carry what is set. Each row is the Speakers sidebar's two-line row: the section's name, and under it a readout (the line that states what is set in that section, in words). The pane on the right is where you change it. To give every row one honest readout, General's three stateful topics split out: **General**, **Audiout Remote**, **Appearance**, **Audio**, **License**.

Comp: `comp.html` in this folder: five frame pairs (dark left, light right), then sidebar crops of other readout states.

## Assumptions (nobody could answer the discovery interview)

The shape interview was not run. No human or question tool was reachable from this agent, so every point below is my reading, marked for Alec to correct.

- Settings is visited rarely and briefly: to check something ("is the iPhone remote on?", "how many days of trial left?") more often than to change it. If people mostly come to change one known switch, the spine pays off less.
- The readouts most worth seeing without a click: whether this copy is licensed and how limited, whether the iPhone remote is on and for how many phones, which apps never reach speakers, and the theme. Launch at login is the one General fact worth the space.
- Adding sidebar sections is allowed: `AudioutSettingsUI/AGENTS.md` says "a new section becomes another row".
- Impeccable's surface-scope concept roll and decision page were not run. The orchestrator already split four directions, and no one could pick a card. I list the structures I weighed below instead.

## 1. Job and audience

A general Mac user with more than one speaker, opening the popover's Settings tab, usually mid-task with sound playing elsewhere. Operate mode. They want to know a state or flip one switch, then get back to the Mixer.

## 2. Outcome and proof

- Success: the answer to "what is set?" is on screen before any click, for the five things a household asks about.
- Proof is the product's own data, read from the same source the pane draws: `AppSettings`, `LicenseGate.limitsToOneSpeaker`, `TrialClock.state`, the companion approvals list, `LoginItemManaging`.
- The product truth this serves is PRODUCT.md principle 2: "The UI never lies." A readout is never cached, guessed, or rounded into a nicer state.

## 3. Selected direction

Visual authority: DESIGN.md, unchanged. Composition only.

Structures weighed, best first:

1. **Five-row spine, one readout per row (chosen).** General splits into General, Audiout Remote and License, so each readout states one fact in under 27 characters, the 154 pt text column at 11 pt.
2. Three rows with joined readouts ("Registered · Remote on · Opens at login"). Rejected: it truncates at 154 pt, and which facts make the cut is arbitrary.
3. Three rows with up to three readout lines each. Rejected: rows reach 68 pt and the sidebar turns into the page.
4. One sidebar row per setting (about twelve). Rejected: every pane holds one control, and every change costs a second click.
5. One-word values in onboarding's trailing status slot ("On", "Off"). Rejected: a bare "On" means nothing without the setting's name beside it.
6. Replace the sidebar with a page of readouts and a Change button per line. Rejected: this is Direction B's territory, and the sidebar is the only section switch.

Sequence:

1. The eye lands on the selected row (name plus readout).
2. It reads down the spine: five facts.
3. It crosses to the pane, where the control behind each fact sits.

The focal moment is the License row in a limited state, the one readout that can run to a second line ("One speaker at a time").

Implementation consequence: the sidebar becomes a live view of settings. Every readout recomputes from its source whenever that source changes, from the pane, the phone, or the licence check.

## 4. Scope and boundaries

- Fidelity: production-ready layout for the Settings screen inside the 713 pt surface; static comp.
- Breadth: sidebar plus all five panes. About and the licence sheet are unchanged. They open from the same buttons.
- Untouched: the header strip, the 210 pt never-collapsing sidebar, the theme tiles' drawing, `RemoteInviteView`, every string the panes already show (moved, never rewritten), stock controls.
- Anti-goals:
  - No hue on a readout without Alec's yes.
  - No icon badges or counts drawn as pills.
  - No animation on readout changes.
  - No page header that repeats what the spine row already says.

## 5. States and readout strings

The readout is one line of `caption` in `labelCool`, ending in "…" when too long, with the full text as its tooltip. A **second line** appears only for a closed list of two facts, each away from its default and each changing what you hear: the licence's one-speaker limit, and an audio buffer other than 1000 ms. The row grows by 14 pt for it.

| Row (SF Symbol) | State | Readout line 1 | Line 2 |
|---|---|---|---|
| General (`gearshape`) | launch at login on | Opens at login | |
| | on, macOS wants approval (`needsApproval`) | Needs Login Items approval | |
| | off | Doesn't open at login | |
| Audiout Remote (`iphone`) | build offers no companion | row absent | |
| | switch off (phones may still be remembered) | Off | |
| | on, no phones remembered | On · no iPhones yet | |
| | on, phones remembered, none allowed | On · no iPhones allowed | |
| | on, 1 allowed | On · 1 iPhone allowed | |
| | on, N allowed | On · N iPhones allowed | |
| | forced by a launch option | as above, from the forced value | |
| Appearance (`paintpalette`) | theme × accent | Match system / Light / Dark, then " · Full gold" or " · Subtle" | |
| Audio (`speaker.wave.2`) | no excluded apps | No apps stay on this Mac | |
| | 1 | 1 app stays on this Mac | |
| | N | N apps stay on this Mac | |
| | buffer ≠ 1000 ms (backend supports it) | as above | Buffer 1500 ms / Buffer 2250 ms |
| License (`key`) | build with no licence server | row absent | |
| | no key | Unregistered | One speaker at a time |
| | trial running (`TrialClock` `.active`) | Trial · N days left (1 day: "Trial · 1 day left"), the popover pill's own string, `PopoverController.trialPillText` | |
| | trial ended | Trial ended | One speaker at a time |
| | key saved, no verdict yet | Key not verified yet | |
| | `.active` | Registered | |
| | `.revoked` refund / chargeback / other | Key refunded / Payment reversed / Key revoked | One speaker at a time |
| | `.unknown` | Key not recognized | |
| | `.invalid` | Not an Audiout key | |

"One speaker at a time" shows exactly when `LicenseGate.limitsToOneSpeaker` is true, the same test the Mixer's standing note uses, so the two can never disagree.

Other states the panes cover:

- **Touch Bar absent:** the row is gone; General's readout is unaffected.
- **Login Items approval:** a `ListRowView` under Launch at login holding the shipped sentence "macOS needs you to allow Audiout in Login Items." and Open Login Items….
- **Remote:**
  - Off: the invitation row is unmounted.
  - On: the invitation shows. The QR tile hides once a phone is remembered; the text and Open audiout.app/remote stay.
  - Forced: the override note is shown.
  - Remembered iPhones: the list shows whenever it has entries, switch on or off.
- **Advanced:**
  - Closed by default; `FoldingClipView`; absent when the backend has no buffer.
  - While applying, "Reconnecting speakers…" appears under the buffer row.
  - After applying: "Speakers reconnected", or "Some speakers didn't reconnect. Reconnect them from the Mixer."
- **Licence pane:**
  - Check again appears only for "key saved, no verdict".
  - The check-in sentence appears only with a key.
  - Buy Audiout hides once registered.
- **Check for Updates…:** hidden in builds without the updater.

## 6. Interaction and layout

**Sidebar**

- Stock `.sourceList` outline: the "Settings" group title, then five rows.
- Row geometry is the Speakers sidebar's two-line row: 22 pt glyph at 16 pt, name at 46 pt in `body`, readout 2 pt below in `caption` / `labelCool`.
- Row heights: 40 pt, or 54 pt with a second line.
- Selected row: the stock pill; the name and readout take the pill's text colour, as Speakers does.
- No plates, chevrons or trailing marks.
- At five rows the sidebar never scrolls.

**Pane**

- Starts 38 pt below the strip, level with the first spine row, so each pane's first box lines up with the readouts.
- Content sits on the Speakers page's 14 pt lane.
- Rows are `ListRowView`s stacked on `GroupedSectionView` `.card` boxes at the `row` radius (16 pt), the speaker page's radius.
- Each row: the title in `body`, the shipped hint as the caption, and the stock control trailing.
- A section title already in the code ("Apps that stay on this Mac", "Remembered iPhones", "Theme", "Accent") sits above its box in `body` / `label2`, the scene editor's "Speakers" voice.
- Appearance keeps its tiles and radios unboxed: a box is earned by a different instrument, and these are their own.

**Panes, top to bottom**

- **General:** one card with Launch at login, Reconnect last speakers…, Use Audiout's Touch Bar controls and Share anonymous usage statistics. Under it: Run setup again…, About Audiout…, Check for Updates….
- **Audiout Remote:**
  - A card holding the Allow control from iPhone on this network row, then the invitation row (the existing view, mounted as the card's second row).
  - "Remembered iPhones" over a card of rows: phone name, caption Allowed or Denied, and a trailing remove button.
- **Appearance:** "Theme", its note, the three tiles; a `RuleView`; "Accent", its note, two radios and the hint.
- **Audio:**
  - "Apps that stay on this Mac" and its note, over a card of app rows plus a click-through Add app… row (`plus.circle` in `label2`, never green).
  - A card with Volume when connecting a speaker, Restore Mac audio if speakers don't reconnect, and Keep Bluetooth speakers streaming during pauses.
  - The Advanced disclosure and its card with Audio buffer.
- **License:** one card row with the title "License", the status sentence as its caption, and Enter license… and Buy Audiout trailing. Check again appears inside the row when offered. The check-in disclosure follows under the card in the shipped hint label (`caption` / `label2`, wrapping in full; at 3 lines it is too long for `noteLabel`'s two).

**Feedback**

- A readout updates in the same turn as the control that changed it, with no animation, in every motion setting.
- Height changes go through `noteHeightOfRows` with a zero-duration context, so the second line appears in place.
- Trial days recompute each time Settings is shown.

**VoiceOver**

- The readout label is not its own element (the Speakers caption rule).
- The row's spoken label is the name, a comma, then the readout lines, with " · " read as a comma: "License, Trial, 9 days left" or "Audio, 2 apps stay on this Mac, Buffer 1500 ms".
- Changes are not announced: the pane control that caused them already spoke. The new readout is heard on the next visit to the row.
- The selection still speaks as the outline's own.

**Increase Contrast**

- The readout resolves `labelCool`'s contrast pair live and calls `redrawOnAccessibilityDisplayChange()`, as the Speakers status label does.

## 7. Components, constraints and open decisions

**Reused unchanged:**

- the source-list outline
- `GroupedSectionView` `.card`
- `ListRowView`
- `RuleView`
- `noteLabel`
- `FoldingClipView`
- `RemoteInviteView`
- the theme tiles
- stock `NSSwitch`, `NSPopUpButton`, `NSSlider`, `NSButton` and radio buttons

**Changed:**

1. **`SettingsSidebarViewController`:**
   - Cells become the two-line name-plus-readout cell, with the geometry of the Speakers sidebar's `IconLabelCellView`.
   - Heights come from `heightOfRowByItem`.
   - The "Settings" title ink moves from `label2` to `labelCool`, to match the Speakers sidebar titles.
   - Sections go from three to five.
2. **`GeneralSettingsViewController` splits into three controllers** (General, Audiout Remote, License). Every row and string moves; none is dropped. `settings:pane_selected` gains two `pane` values, "Audiout Remote" and "License". Those must be added to `docs/analytics-events.md` in audiout-shared first; the event name is unchanged.
3. **`ListRowView` and `GroupedSectionView` move to `AudioutSharedUI`.** They are internal to `AudioutWindowUI`, and `AudioutSettingsUI` depends only on `AudioutCore` and `AudioutSharedUI` (`Package.swift` line 296). Every direction that reuses them hits this.
4. **`ListRowView` gains one option:** the caption runs full width under a wide accessory. The connect-volume slider plus readout well is 196 pt, which would squeeze the 105-character hint to three lines. The shipped `SettingsForm.row` already lays it out this way.
5. Panes stop using `SettingsForm` rows; the licence sheet still uses `SettingsForm`.

**New custom-drawn pieces:** none. The readout is a stock label in an existing cell shape.

**Open decisions for Alec:**

1. **Hue role for Settings: I argue neutral.** Readouts are words; gold means audio and calls to action, green means a reachable speaker, and a Settings hue would only decorate. One alternative is declined in the comp but is yours to take: draw "One speaker at a time" in `failure` ink. NEEDS ALEC'S YES if wanted.
2. **Split General into General, Audiout Remote and License** (five rows instead of three).
3. **No `PageHeaderView` on panes.** The selected spine row already shows the name and state; a header would repeat both 300 pt to the right. Direction A likely keeps it; pick per taste.
4. **Which fact each readout shows.** General shows launch at login (usage sharing was the other candidate). Audio shows the excluded-app count, plus the buffer only when changed.
5. **License pane copy in a trial (new copy, NEEDS ALEC'S YES).** The shipped pane has no line for a running trial. `licenseStatusLine` has no trial branch, so a trial key reads "Registered. Thank you for supporting Audiout." once verified, or "Your key is saved…" before. Proposed: "Audiout plays on every speaker until your trial ends on 15 October." (date from `TrialState.active.expiresAt`).
6. **Enter license… during a trial.** The shipped button reads "Change…" whenever a key is stored, and a trial stores its key in `licenseKey`. The comp shows Enter license…, which needs the button to test for a trial.
7. **Section order:** General, Audiout Remote, Appearance, Audio, License. License sits last so the list never reorders by state.

**Constraint notes:**

- The comp copies the header strip from the Speakers render, which shows the "Audiout" wordmark centred (`SurfaceBrandView`, `label2`). inputs.md says "no brand lockup". The wordmark is drawn because the render and the code have it; drop it if the constraint meant removal.
- The comp shows switches and the selection pill in their non-key grey, as the renders do. Live, with the panel key, both take the Mac's accent colour.
- The wordmark falls back to bold system type, as the code does outside the `.app`.
- Shipped behaviour drawn as is: once a phone is remembered the QR tile hides, but the invitation still reads "Scan with your iPhone's camera, or open audiout.app/remote." A copy fix is owed whichever direction wins.
