# B — Groups (Scenes) window and Settings panes

## 1. Verdict

This slice reads as a person's decisions far more often than as a template: the
controls are stock AppKit, the custom drawing is named and measured in the
files that do it, and several strings (the delete confirmation, the licence
status line) are better than what a careful human usually writes. The tells
that remain are concentrated in two places: prose that a machine would
generate around a control (the Audio pane's live hint lines) and a small set
of undocumented visual defaults in the Groups window (the dashed "Add scene"
tile, the pane's own title-and-counter header, the icon picker's typed-symbol
path).

Highest-impact change: rewrite the Audio pane's live hint lines so they state
the value and the mechanism and nothing else. The current ones editorialise
about a number ("a moderate, comfortable start", "a very loud start that may
startle") and join their clauses with an em dash, which is the one thing on
these two surfaces a reader would point at and say a machine wrote it.

## 2. Findings

[P1] Settings › Audio, volume-when-connecting hint — AudioutCore/Sources/AudioutSettingsUI/AudioSettingsViewController.swift:308-318 — settings-audio-light.png, settings-audio-dark.png
  tell:  D copy (adjective table + em dash in a UI string)
  now:   A four-branch table turns the slider's number into a judgement:
         `case ..<21: "a quiet, gentle start"`, `..<51: "a moderate, comfortable
         start"`, `..<76: "a loud start"`, else `"a very loud start that may
         startle"`, assembled as `"Connects at 35% — a moderate, comfortable
         start. Each speaker's own slider takes over right after."`
  why:   Interpreting a number back to the user in soft adjectives is the
         default an assistant reaches for when asked to "explain the setting",
         and the em dash joint is the giveaway sentence shape. It also runs
         against PRODUCT.md's own localisation stance (bare numbers and units,
         never named presets) and against the "may startle" personification the
         house voice rules out. The value is already on screen in the readout
         well two inches away, so the adjective is the only new information and
         it is the app's opinion.
  fix:   One sentence at every value: "Connects at 35%. Each speaker's own
         slider takes over right after." (typographic apostrophe). If the top
         of the range needs a warning, make it one branch with a fact, not a
         mood: at 90% and above append "That is close to full volume."

[P1] Groups › icon picker — AudioutCore/Sources/AudioutWindowUI/IconPickerViewController.swift:146, 164, 192-195, 373-383 — mixer-6-icon-picker-light.png, mixer-6-icon-picker-dark.png
  tell:  C reinvented control / invented affordance for a standard task
  now:   The search field sits BELOW the grid it filters (`searchRow.topAnchor
         … equalTo: grid.bottomAnchor`), and the same field doubles as a
         free-text entry for any SF Symbol name: `updateSearchState()` enables
         the "Apply" button only when `DeviceIcon.isValid(trimmed)` says the
         typed string is an exact Apple symbol name, and shows a preview tile
         beside it.
  why:   Picking an icon is a solved task: show icons, click one. This adds a
         second, hidden path whose vocabulary is Apple's internal symbol names,
         exposed to the general-consumer user PRODUCT.md names as the design
         target, with an "Apply" button that lights up or stays dead for
         reasons nothing on screen explains. A search field placed under its
         own results is the arrangement you get when a layout is assembled
         rather than used. Nothing in DESIGN.md or the folder AGENTS.md records
         the typed-name path as a decision; the only note is grid density.
  fix:   Move the search field above the grid. Delete the exact-name preview,
         the preview tile and the Apply button; the grid already applies on
         click. Keep "Use default icon" where it is.

[P2] Groups overview, "Add scene" tile (grid cell and empty canvas) — AudioutCore/Sources/AudioutWindowUI/GroupsOverviewViewController.swift:1041, 1055-1062, 1090-1097; 71-73, 137-143, 156-160 — mixer-8-groups-overview-light.png, mixer-8-groups-overview-dark.png
  tell:  A/B dashed placeholder card
  now:   The last grid cell is a dashed rounded rect (`setLineDash([4, 3])`) at
         the row radius, holding a 28pt circle-ringed `plus` glyph
         (`cornerRadius = 14`, 1pt hairline border) over a centred caption "Add
         scene". The zero-scenes canvas stacks a centred headline, a centred
         sentence and the same dashed tile.
  why:   Dashed border plus circled plus plus centred caption is the stock
         "empty slot" card from every web component kit, and three template
         signals are stacked here where one control would do. It is also the
         third door to the same sheet on that screen (the sidebar's "+ Add
         scene" bar and Cmd-N already exist), and it is the only piece of
         drawn chrome in this folder that no AGENTS.md or DESIGN.md names.
  fix:   Draw the last cell in the same vocabulary as a scene card: `raised`
         fill, 1pt `containerEdge` edge, no dash, with a leading `plus` glyph
         and "Add scene" on one line instead of a ringed glyph over a caption.
         Use the same tile on the empty canvas.

[P2] Settings › Audio, "Apps that stay on this Mac" list — AudioutCore/Sources/AudioutSettingsUI/AudioSettingsViewController.swift:871-881, 903-921 — settings-audio-light.png, settings-audio-dark.png
  tell:  C native drift (iOS editing controls inside a Mac list)
  now:   Every row carries a trailing borderless `minus.circle.fill` button,
         and the last row inside the box is a borderless `plus.circle` button
         titled "Add app…".
  why:   The circled minus on each row is the iPhone's editing idiom; macOS
         puts a small plus and minus in a footer bar under the list (System
         Settings › Login Items) and never repeats a remove control per row.
         A Mac user reads a row-level minus as "this list came from the phone
         app", which is exactly the pause the product slop test is about. The
         same row-level `minus.circle.fill` is reused for the "Remembered
         iPhones" list (GeneralSettingsViewController.swift:676), so it is a
         pattern, not one screen.
  fix:   Put a plus and a minus in a small footer bar attached to the bottom of
         the bordered box, acting on the selected row, and drop the per-row
         button and the in-box "Add app…" row.

[P2] Groups window, footer caption on every pane — AudioutCore/Sources/AudioutWindowUI/MixerWindowController.swift:816-822 (and DeviceDetailViewController.swift:48-51) — mixer-3/4/5/7/8, light and dark
  tell:  A teaching line promoted to permanent chrome
  now:   `ContentPaneHostViewController` pins "Set up scenes here, then switch
         to the Mixer to play" under every swapped pane, "ALWAYS visible" by
         its own comment. The device page then deliberately carries no hint of
         its own because "the window's own footer caption owns the division of
         labour".
  why:   On the speaker page the sentence is about a different object entirely:
         the user is tuning Sonos Move's bass and treble and the window is
         still explaining scenes. A line that is true on one pane and irrelevant
         on the other two is an onboarding string that was promoted to chrome
         because the bottom of the window looked empty.
  fix:   Show it on the scenes overview only (where it teaches, and where the
         empty canvas already carries the longer version), and let the editor
         and the speaker page end at their own content.

[P2] Groups overview, pane header — AudioutCore/Sources/AudioutWindowUI/GroupsOverviewViewController.swift:64-65, 93-105, 231 — mixer-8-groups-overview-light.png, mixer-8-groups-overview-dark.png
  tell:  A page-header template (icon + title + counter)
  now:   The pane draws a `titleGlyph` (the same scenes symbol the sidebar
         plate and every card seat already draw), the heading "Scenes", and a
         right-aligned "3 scenes" count.
  why:   The screen is already named twice above and beside it (the header
         strip's Scenes tab, the selected sidebar plate), and the word appears
         six times in one frame counting the count, the footer caption and the
         two "Add scene" doors. An icon, a title and a right-aligned count is
         the dashboard-page header a generator emits when a content area needs
         "a header"; nothing here is disambiguating anything.
  fix:   Delete the glyph and the title row. If the count earns a place, put it
         alone on the first line above the grid, right-aligned, in the caption
         voice it already uses.

[P2] Settings, em dash as the standard sentence joint — AudioutCore/Sources/AudioutSettingsUI/AudioSettingsViewController.swift:316, 419, 468, 758; AppearanceSettingsViewController.swift:565 — settings-audio-light.png, settings-appearance-light.png
  tell:  D copy (banned punctuation in UI strings)
  now:   Five hint lines join value to consequence with an em dash: "Buffer:
         120 ms — fastest response…", "Never — after waking, this Mac stays
         silent…", "Never — Bluetooth speakers go idle…", "A quieter gold —
         softer meters…", plus the connect-volume line above.
  why:   The copy rules ban the em dash in UI strings outright, and the reason
         shows here: five strings across two panes share one punctuation
         reflex, so they read as one generated family rather than five written
         lines.
  fix:   A period or the colon the buffer line already uses: "Buffer: 120 ms.
         Fastest response, safe for Wi-Fi speakers." / "Never. After waking,
         this Mac stays silent until the speakers reconnect."

[P2] Settings › Appearance, Accent section copy — AudioutCore/Sources/AudioutSettingsUI/AppearanceSettingsViewController.swift:98, 563-566 — settings-appearance-light.png, settings-appearance-dark.png
  tell:  D copy (restatement plus internal vocabulary)
  now:   Subtitle: "How strongly meters, dots, and rings use the brand gold."
         Directly beneath, the Full gold hint: "Meters, dots, and rings glow in
         the full brand gold." The Subtle hint names "the routing dot".
  why:   Two consecutive lines carry the same four nouns and the same phrase,
         which is what a model produces when a section wants a description and
         each option wants one too. "The brand gold" and "the routing dot" are
         the design system's own words; a first-time Mac user has never been
         told the app has a routing dot, and PRODUCT.md's first principle says
         jargon may flavour chrome but never carry a decision. This is a
         decision.
  fix:   Keep one explanation and let the two radio labels do the rest. Delete
         both per-position hints; if one stays, drop the internals: "A quieter
         gold, with no glow."

[P3] Settings, straight apostrophes against the Groups window's typographic ones — AudioutCore/Sources/AudioutSettingsUI/GeneralSettingsViewController.swift:512 and AudioSettingsViewController.swift:317 vs GeneralSettingsViewController.swift:421; AudioutWindowUI/GroupEditorViewController.swift:215 vs :1286 — settings-general-light.png, settings-audio-light.png
  tell:  E typography left at the keyboard default
  now:   "Audiout starts on this Mac's speakers only." and "Each speaker's own
         slider…" use the ASCII apostrophe, while "Audiout hasn't been able to
         verify it yet." in the same file uses the typographic one. The Groups
         editor mixes both the same way (`savedAsYouGoActive` uses \u{2019};
         the delete alert's "doesn't" does not).
  why:   Mixed apostrophes within one file are the signature of strings typed
         at different times with no pass over them, and the straight one is the
         default that arrives when nobody chose.
  fix:   Use ’ in every user-visible string in both folders; the four already
         correct ones set the convention.

[P3] Groups, magenta identity glow behind every scene seat — AudioutCore/Sources/AudioutSharedUI/GroupIdentityGlowView.swift:24-28, 74-84 — mixer-8-groups-overview-light.png, mixer-8-groups-overview-dark.png
  tell:  B unprompted glow ("chosen, but reads as a tell")
  now:   A radial `partyRampDeep` core fading to clear sits behind each seat at
         22% alpha in dark and 10% in light, documented as "atmosphere, not an
         instrument" and deliberately under the graphic contrast floor.
  why:   A zero-offset coloured halo behind an icon is the decoration family
         this audit exists to catch, and DESIGN.md does pin it as the Mac's
         instance of "magenta is identity". Measured off the rendered frames it
         contributes 2 to 7 levels of RGB against the card fill (dark card
         (31,35,42) versus (38,37,48) at its strongest point; light (250,250,251)
         versus (248,248,249)), so what ships is a view, a gradient layer, two
         notification observers and a re-stamp path for something nobody can
         see.
  fix:   Decide one way. Either raise the core until the identity actually
         reads on both grounds and record the new measurement in the file, or
         delete the view and its mounts and let the seat carry identity alone.

[P3] Groups, zero-scenes canvas type — AudioutCore/Sources/AudioutWindowUI/GroupsOverviewViewController.swift:71-73, 137-143; AudioutSharedUI/Tokens.swift:1274-1283 — no screenshot (see section 6)
  tell:  C type off the platform scale
  now:   "Set up a scene" renders in `Tokens.Font.titleLarge` (15pt regular)
         tinted `label2`, over a subtitle in `subtitleLarge` (12pt regular)
         tinted `label3`, both centred.
  why:   Neither size is in DESIGN.md's hierarchy (13/16/11/10/20) nor in its
         ledger of sanctioned off-scale sizes, and the headline is lighter and
         greyer than the app's own heading voice. A greyed, centred, one-off
         headline is the generic empty state rather than this app's typography.
  fix:   `Tokens.Font.heading` in `Tokens.Color.label` for the headline,
         `caption` in `label2` for the line beneath it, and retire
         `titleLarge`/`subtitleLarge` here or ledger them in DESIGN.md with
         their reason.

[P3] Groups editor, "‹ Scenes" and "Done" as a pair — AudioutCore/Sources/AudioutWindowUI/GroupEditorViewController.swift:118, 217-223, 360-403 — mixer-3-edit-group-light.png, mixer-7-edit-active-group-dark.png
  tell:  C mixed navigation metaphors ("chosen, but reads as a tell")
  now:   The pane's top band puts a chevron-plus-label back button on the left
         and a "Done" button on the right. Every edit autosaves, so by the
         file's own comment the primary "only has to say how to leave"; it
         reads "Save" only while a rename is uncommitted.
  why:   That band is an iPhone navigation bar restated in AppKit, inside a
         window whose sidebar already owns navigation, and its right-hand
         button is a second door to the same place because a form is expected
         to have a primary. AGENTS.md does list both as sanctioned exits, which
         is why this is P3 rather than higher, but it records the behaviour and
         not the reason for two visible controls doing one thing.
  fix:   Keep "‹ Scenes" (plus Cmd-[ and Escape, which already work) as the way
         out, and show the button on the right only while it says "Save".

[P3] Settings › About, two copy defaults — AudioutCore/Sources/AudioutSettingsUI/AboutView.swift:131, 223, 226 — no screenshot (see section 6)
  tell:  D copy (Title Case label, self-answered question)
  now:   A section label reads "Third-Party Notices" (and is referenced in the
         licence subtitle the same way); the support line reads "Questions or
         problems? Email support@audiout.app."
  why:   Sentence case is the house rule for every label except the macOS menu
         items Apple title-cases, and a question the copy immediately answers
         itself is the rhetorical setup the prose rules name. Both are the
         phrasing that arrives by default in a support section.
  fix:   "Third-party notices" (both places) and "Email support@audiout.app
         with questions or problems."

## 3. Repeated patterns across the slice

**The live hint line.** Four controls in the Audio pane and one in Appearance
each carry a sentence beneath them that is rewritten on every change, under a
spec rule quoted in the code ("every consequential control self-explains with a
live hint", SettingsForm.swift:34-40). The mechanism is a real decision and two
of the lines earn their place by adding a fact the control cannot show (what
happens after a wake, what a silent stream buys). The other two paraphrase the
value that is already on screen and then add the app's opinion of it. The rule
is fine; the lines that had nothing to add should say nothing.

**Boxes, and how many kinds.** `GroupedSectionView` ships four styles and the
device page uses three of them in one column: the Equalizer in a `.well` at the
26pt panel radius sitting directly above "Scenes" and "About" as `.panel` boxes
at the 16pt row radius. Both radii are on the pinned ladder, so neither is
wrong on its own, but stacked 40pt apart they read as two different design
languages in one scroll. Worth one deliberate look at whether a fact list and
an instrument need different corners on the same page.

**Dashed strokes standing for "not a real thing".** The Add-scene tile and the
"+N" member-overflow chip (GroupsOverviewViewController.swift:999) both use
dash to mean placeholder. On the chip it says something (these members are not
drawn); on the tile it is decoration around a button that is as real as any
other.

**Typography defaults.** Straight apostrophes, em dashes as the sentence joint,
one Title Case header, and two off-scale font sizes in the empty state. None of
these is visible on its own; together they are the layer nobody did a pass
over, and that layer is the cheapest signal that a surface was assembled rather
than written.

## 4. Positives

- The delete confirmation (GroupEditorViewController.swift:1280-1293) changes
  its sentence depending on whether the scene is playing, because the old
  sentence was "a plain lie in that case", and it gives Return to Cancel on a
  destructive sheet. That is a person catching their own copy in the act.
- The licence sheet's remove alert (LicenseSheetViewController.swift:206-216)
  names both buttons for what they do ("Remove" / "Keep license") and states
  the real consequence instead of asking "Are you sure?".
- The Equalizer box is a `.well` rather than a `.card` because `.card`'s
  `raised` fill measures identical to the light ground, so a card there would
  be an outline around nothing (DeviceDetailViewController.swift:27-33). The
  decision came from a measurement, not a habit.
- The icon well's edit badge is permanently visible because the earlier
  hover-only scrim was undiscoverable, and the two conflicting affordances that
  replaced it were cut after a live review (DeviceIconWellView.swift:11-21).
- The theme tiles draw a miniature Mac window with traffic lights, in absolute
  sRGB mirrors of the palette so the "Light" tile stays light while the app is
  dark (AppearanceSettingsViewController.swift:443-470). It borrows System
  Settings' own idiom instead of inventing a swatch.
- The create-scene sheet is a plain AppKit sheet: stock checkboxes, a real
  placeholder, a live count, "Add scene" as the primary and disabled until a
  speaker is picked (GroupCreationSheetController.swift:145, 207-214, 366).
  Nothing about it was decorated.

## 5. Unverified impressions (screenshot only, no code anchor)

- In light mode the Equalizer `.well` recess and the `.panel` lists below it
  sit close enough in value that the recess reads as a slightly grey card
  rather than a sunk one. DESIGN.md records the intended figure (1.154:1 on the
  light ground) so this is an impression about whether that figure is enough,
  not a defect I can anchor.
- On the device page the About list is cut mid-row by the footer strip with no
  other scroll cue in the frame. The pane does scroll by design, and a cut row
  is a legitimate cue, so this is only a note that the cut lands under a
  caption about something else.

## 6. Screens and states in this slice I could not see

- **The zero-scenes canvas.** `mixer-1-default-light/dark.png` rendered as an
  empty frame with only the header strip: the surface resolves the Groups
  content lazily on the first `.groups` select
  (window-snapshot/main.swift:552-585), so the first capture ran before the
  content mounted. Audited from source instead (finding above).
- **Settings › About pane** (AboutView.swift) — no snapshot; audited from
  source, two copy findings above.
- **Enter License sheet** (LicenseSheetViewController.swift) — no snapshot;
  read in full, nothing to report: plain headline, stock field, gold Register
  as the one prominent button, honest status lines.
- **Settings sidebar** (SettingsSidebarViewController.swift) — no snapshot;
  read in full, stock source list in the Groups sidebar's geometry, nothing to
  report.
- **Main Audio detail page** (MainOutDetailViewController.swift) — no
  snapshot; read for copy and structure, nothing to report.
- **The group editor's delete confirmation** — no snapshot; read in source and
  listed under positives.
- **General pane rows absent from the snapshot**: the "Allow control from
  iPhone" switch, the QR invitation tile under it, "Remembered iPhones", the
  licence check-in disclosure, and "Check for Updates…". They exist in
  GeneralSettingsViewController and mount conditionally; only the rows the
  headless default produced were rendered.
- **The Audio pane's Advanced fold** (buffer popup, its hint, the apply
  spinner) — collapsed by default, so the snapshot shows only the disclosure
  header.
- **Hover, focus, pressed and disabled states** anywhere in the slice, and the
  Increase Contrast and Subtle accent columns. The snapshots are one resting
  state per screen.
