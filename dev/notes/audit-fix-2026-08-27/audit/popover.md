# Impeccable audit — the menu-bar popover (Mixer surface)

**Surface:** `AudioutCore/Sources/AudioutPopoverUI/` + the shared row components it hosts in `AudioutCore/Sources/AudioutSharedUI/`
**Evidence:** source read against the 22 checked-in renders in `dev/notes/popover-snapshots/` (light + dark, 11 states)
**Lens:** a general Mac user with two AirPlay speakers, zero audio vocabulary, sound playing loudly in another room
**Date:** 2026-08-26 · read-only audit, nothing built, nothing run

---

## Scores

| # | Dimension | Score | One-line verdict |
|---|---|---|---|
| 1 | Accessibility | **2** / 4 | Best-in-class VoiceOver composition sitting on a palette that misses the contrast floor almost everywhere text is quiet |
| 2 | Performance | **3** / 4 | Genuinely disciplined (hidden-means-idle, self-stopping meters, diff-gated rebuilds); undermined by a 3 s dead first click and three known-and-marked defects |
| 3 | Appearance & Theming | **3** / 4 | Exemplary token governance with authored contrast rationales — and two state banners that never re-theme, plus two system aliases used below their own documented floor |
| 4 | Platform Conformance (macOS) | **3** / 4 | Stock AppKit end to end; the primary control is an invisible checkbox with no cursor affordance, and Quit is one stray click in the toolbar |
| 5 | States & Honesty | **2** / 4 | Extraordinary state coverage and plain-speech failures — with no empty state, no searching state, and two opaque badges (`AP1`, `+5`) on decision-bearing rows |
| | **Total** | **13 / 20** | |

**Counts:** P0 **1** · P1 **9** · P2 **9** · P3 **5** — 24 findings.

---

## Verdict

This is a surface built by someone who has thought harder about state than almost any Mac app ships with. Every failure has a plain-English cause and a suggested action, disabled controls are honestly disabled, the FEED column refuses to collapse a multi-source truth into one reason, the removal undo is only offered when the click actually silenced a room, and the VoiceOver label for a device row is composed from the same facts the pixels are. The Reduce Motion story is complete rather than decorative. The token file carries a measured contrast rationale per colour. None of that is common.

What it does not yet have is a **first ten seconds**. A new user with two AirPlay speakers clicks the menu-bar icon and — on the first open of the process — gets *nothing on screen for up to three seconds* while discovery settles (`AppSurfaceController.revealCeiling = 3.0`), with every further click swallowed by the pending-reveal guard, then a 0.7 s branded hold and a 0.25 s fade before a control can be touched. When the panel does arrive, if discovery found nothing the Output Devices card contains one grey line reading "Connect a Bluetooth device…" — the word *AirPlay* appears nowhere, there is no "looking for speakers", and that grey line is in fact a button styled to look exactly like disabled placeholder text. And when speakers *are* listed, the control that adds one to the mix is an `NSButtonCell` that draws nothing, over a 13 pt dot, with no cursor change on hover (`DeviceRowView` is the one row type in the panel with no `resetCursorRects`, while `MainOutRowView` and `AppRowView` both have one).

So the app is honest about everything except the two questions a first-time user actually asks — *is it working?* and *how do I pick a speaker?* Those are the P0/P1 block. Underneath them sits one systemic theming problem: `Tokens.Color.secondaryLabel` and `.tertiaryLabel` are bare aliases for the system colours, and the token file itself records that `NSColor.secondaryLabelColor` measures **3.95:1** in light — under the 4.5:1 floor PRODUCT.md commits to. An authored compliant replacement (`Tokens.Color.inkSecondary`, 7.1:1) already exists and is used *only* by onboarding. Every card header, every column title, every unselected device name, the dormancy note, and the diagnosis panel's suggestion line are drawn in the non-compliant alias; the subsection labels that tell a user which speakers are AirPlay and which are Bluetooth are 11 pt `tertiaryLabelColor` at roughly 2.2:1.

Fix the first-open dead time, give the device card a real empty/searching state, make the membership control visible, and move the quiet text onto the compliant token, and this surface is ready. Nothing here requires re-architecture.

---

## P0 — blocks task / ship

### P0-1 · The first menu-bar click does nothing for up to 3 seconds, and every click during that window is swallowed
**Location:** `AudioutCore/Sources/AudioutPopoverUI/AppSurfaceController.swift:191` (`revealCeiling = 3.0`), `:270` (`guard !isRevealPending else { return }`), `:281–309`; `AudioutCore/Sources/AudioutPopoverUI/SurfaceSplashView.swift:35,41,43` (hold 0.7 s, ceiling 2.7 s, fade 0.25 s)

On the first surface open of a process, `show(anchorRect:)` does **not** front the window. It mounts the screen off-screen, arms a `DiscoverySettleTracker`, and returns. A cold open has an empty fleet, and the tracker is deliberately *not* `start()`ed in that case (`:294–301`), so nothing settles until the first real device arrives — or until the 3.0 s backstop timer fires. Only then does the window appear, carrying a 0.7 s branded hold plus a 0.25 s cross-fade before content is usable.

Worst realistic case: **~3.95 s from click to a touchable control, with roughly 3 s of it showing no window at all.** During that time `clickAction(setupIsOpen:)` returns `.show` (the panel is not visible), `perform` calls `show`, and `show`'s first line returns early — so a second, third, fourth click on the menu-bar icon is silently discarded. The code comment at `:302` names the risk exactly ("the user is trapped waiting on a click that seemed to do nothing") and then sets the backstop three seconds out.

**Impact:** The single most damaging first impression a menu-bar app can make — the app looks broken on the click that matters most. It also directly contradicts Product Principle 4 ("kill-switch controls stay one gesture away"): a user whose speaker is blasting cannot reach mute for up to four seconds. Worse, the user learns on day one that the icon is unreliable, and that lesson does not unlearn.

**Recommendation:** Front the window immediately, always. Keep the settle tracker, but use it to decide when to *cross-fade the splash away*, not when to show the window — the splash is already an opaque cover, so it can absorb the resize it was invented to hide. If a resize under an opaque cover genuinely still reads through (the note at `AGENTS.md` line 31 says AppKit applies `preferredContentSize` a runloop late), front the window at the floored session size with the splash over it and only re-measure at settle. Failing that, cut `revealCeiling` to ~600 ms and make a click during `isRevealPending` cancel the wait and reveal at once rather than returning early.

---

## P1 — fix before release

### P1-1 · There is no empty state and no searching state; the only thing an empty device card says is "Bluetooth"
**Location:** `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:1333–1339`, `:2617–2644`

`rebuild()`'s comment is explicit: *"with an empty fleet the card still builds, and the always-rendered Bluetooth subsection's own Connect affordance is the card's empty-state message — no separate placeholder row (a 'Looking for devices…' line above an actionable Connect button said two contradictory things at once; removed 2026-08-08)."* Every other device-type subsection is hidden when empty (`rendersHeader(_:)`), so an empty fleet renders literally: `OUTPUT DEVICES` → `Bluetooth Devices` → `Connect a Bluetooth device…` → `+`.

The word **AirPlay** does not appear. The user installed this app to send audio to AirPlay speakers, and the empty state points them at Bluetooth.

Three genuinely different situations collapse into that one identical rendering: still discovering, discovered nothing, and cannot discover (Local Network permission denied — the popover has no surface for it; `PopoverController.swift` mentions permission exactly once, at `:1153`, and only for the PTP helper). The user cannot tell which they are in.

**Impact:** The most common first-run state is a dead end that misdirects. A user whose router isolates clients, or who declined the Local Network prompt, has no path forward and no reason to suspect a permission.
**Recommendation:** Restore a distinct card state with three honest variants: *"Looking for speakers…"* (with a quiet indeterminate indicator) while discovery is unsettled; *"No AirPlay speakers found on this network."* with a one-line hint plus a "Check network access" link once settled empty; and a permission variant if Local Network is known-denied. The removed line contradicted the Connect button because both were rendered at once — render one *or* the other, not both. Keep the Bluetooth Connect row as a subsection affordance, not as the card's answer.

### P1-2 · The primary control of the app — "add this speaker to the mix" — is invisible and has no cursor affordance
**Location:** `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift:3121–3149` (`InvisibleSwitchCell`), `:1594–1613` (checkbox constrained over the rail gutter), `:2008–2023` (`nameClicked`); absence of `resetCursorRects` in `DeviceRowView` vs. `MainOutRowView.swift:796–799` and `AppRowView.swift:973–977`

Membership is a real `NSButton` — focusable, VoiceOver-operable, with a correctly traced circular focus ring (genuinely good, see Positives). But it draws **nothing**; its only visible skin is a 13 pt dot in the left gutter that reads as a decoration on a wire. There is no checkbox glyph, no switch, no label, no tooltip, and — uniquely among the panel's three row types — **no pointing-hand cursor** over either the dot or the clickable name. `MainOutRowView` and `AppRowView` both install cursor rects; `DeviceRowView` does not.

Clicking the device *name* also toggles membership (`nameClicked`, `:2008`), which helps discoverability but is itself unsignalled and is a live-audio hazard: a click on a name a user thought was inert starts audio in another room at that device's stored volume. (Removal is protected by the excellent undo offer; **addition is not.**)

**Impact:** The user's core task — pick which speakers play — has no affordance a Mac user recognises. The visual language (dot on a wire) is a mixing-desk metaphor the design target explicitly does not have vocabulary for.
**Recommendation:** Give `DeviceRowView` a `resetCursorRects` marking the gutter hit rect and the name rect `.pointingHand` — this is a three-line change that matches the two sibling row types and removes most of the doubt on its own. Add a tooltip on the gutter ("Add <name> to the mix" / "Remove <name> from the mix"). If discoverability still tests badly, the smallest honest escalation is a hover-revealed check glyph inside the unselected dot, not a second control.

### P1-3 · `Tokens.Color.secondaryLabel` is used for ~49 sites and the token file records it as 3.95:1 in light — under the committed floor
**Location:** `AudioutCore/Sources/AudioutSharedUI/Tokens.swift:86` (`public static var secondaryLabel: NSColor { .secondaryLabelColor }`), the rationale at `:405–412`, and the compliant unused replacement at `:413–415` (`inkSecondary`)

The token file states it plainly: *"`NSColor.secondaryLabelColor` alias measures 3.95:1 vs `panel` in light, under floor for body text."* `inkSecondary` was authored to fix exactly that (7.1:1 light / 7.3:1 dark) — and a grep for it across `AudioutSharedUI` and `AudioutPopoverUI` returns **zero hits**. It is used only by onboarding.

Meanwhile `Tokens.Color.secondaryLabel` carries, in this surface alone: every card header line and column title (`PopoverPanelViewController.swift:1125`), every unselected device name (`DeviceRowView.swift:2039`), the dormancy card note, the diagnosis panel's suggestion body (`ConnectionDiagnosisView.swift:127`), the Bluetooth Connect row's title (`PopoverController.swift:2632`), and the FEED pills' neutral text.

Note that `AudioutPopoverUI/AGENTS.md` line 27 already reasons about this — the dormancy note was moved *off* `tertiaryLabel* because "it lands under 4.5:1 in light" — and landed on a token that is also under 4.5:1 in light.

**Impact:** In light (Circuit) mode, the majority of the panel's text is below the contrast floor PRODUCT.md commits to. On a bright kitchen counter this is the difference between reading a speaker name and guessing at it.
**Recommendation:** Repoint `Tokens.Color.secondaryLabel` at the `inkSecondary` values, or (safer, if some non-text consumers depend on the system alias) sweep the ~49 text call sites onto `inkSecondary`. Add the same regression pin `PopoverPanelHeaderTests` already uses for the dormancy note.

### P1-4 · Subsection grouping labels are 11 pt tertiary — roughly 2.2:1 in light — and they are the labels that name the protocol
**Location:** `AudioutCore/Sources/AudioutPopoverUI/PopoverPanelViewController.swift:1160–1161` (`font = Tokens.Font.captionMedium` = 11 pt; `textColor = Tokens.Color.tertiaryLabel` = `NSColor.tertiaryLabelColor`), chevron tint at `:1180`

"This Mac", "AirPlay Devices", "Bluetooth Devices" render at 11 pt in the system tertiary label colour — approximately 25–26 % black on the Circuit light panel, i.e. **~2.2:1**, under both the 4.5:1 text floor and the 3:1 non-text floor. This is visible in `popover-light.png`: the three grouping labels are markedly fainter than everything around them. The collapsible chevron beside them is tinted the same way, so an *interactive* control's glyph is also under 3:1.

These are not decorative. They are the only thing telling a user that "Move 2" is an AirPlay speaker and "Sonos Move" is not — which decides whether per-app routing will work on it (AP1/BT rows are excluded).

**Impact:** The panel's structural map is the least legible text on it, in the appearance most users will run during the day.
**Recommendation:** Move subsection labels and their chevrons to `inkSecondary` (or the compliant secondary of P1-3). The intended *hierarchy* — "a step under the column headers" — survives fine on weight and case; it does not need to be bought with contrast.

### P1-5 · `AP1` and `+5` are opaque badges on decision-bearing rows, with no tooltip, no legend, and no way to expand them
**Location:** `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift:1060` (`ap1FeedTag = "AP1"`), `:1221–1232` (the `+N` overflow pill), `FeedPillView.swift:65` (`hitTest` returns `nil`); rendered in `dev/notes/popover-snapshots/popover-feed-composite-light.png` / `-dark.png`

Two strings in the FEED column carry meaning a first-time user cannot recover:

- **`AP1`** marks an AirPlay-1-only receiver. That fact *changes what the app can do* — AP1 devices are excluded from per-app routing (PRODUCT.md, Capabilities). It is therefore decision-bearing, and PRODUCT.md's voice rule says decision-bearing strings read in plain speech. "AP1" is protocol jargon rendered in SF Mono uppercase.
- **`+5`** is the overflow suffix. In the checked-in snapshot, "Overflow Speaker" has five redirected apps and **no** other feed segment, so the entire column reads `+5` — a pill containing nothing but a number, meaning "five things you can't see are sending audio here". `FeedPillView.hitTest` returns `nil`, so there is no click, and there is no tooltip anywhere on the feed stack (the only tooltips in `DeviceRowView` are on the blocked checkbox and the sync chip).

VoiceOver is strictly better informed than the screen here: `feedAccessibilityClause` (`DeviceRowView.swift:2985–2999`) speaks the full uncapped list ("feeding Music, Safari, …"). The sighted user gets `+5`.

**Impact:** A user cannot answer "why is this speaker playing?" — the one question the FEED column exists to answer — for the exact rows where the answer is most complicated.
**Recommendation:** Replace `AP1` with something a household reads (an "Older AirPlay" pill, or fold it into the row's sublabel with the consequence stated: "Older AirPlay — can't route single apps"). Give the whole feed stack a tooltip carrying the same string `feedAccessibilityClause` composes — one line, and it makes `+5` and `AP1` both self-explaining without adding a control. (The "no interactive reveal" lock is about *clicks*; a tooltip is not a reveal.)

### P1-6 · The diagnosis panel's dismiss ✕ is a 9.5 pt tertiary glyph — the exact mistake the wizard already fixed
**Location:** `AudioutCore/Sources/AudioutPopoverUI/ConnectionDiagnosisView.swift:191–208` (`pointSize: 9.5`, `contentTintColor = Tokens.Color.tertiaryLabel`, no size constraint)

The button hugs a 9.5 pt symbol with no explicit hit-target constraint, tinted tertiary over a red-washed card. `AudioutPopoverUI/AGENTS.md` line 46 records the identical lesson being learned elsewhere: *"The question screen carries a stock **Stop** button (the 9.5 pt ✕ was the only way out and nobody found it)."* The same 9.5 pt ✕ is still the only way out of the diagnosis panel — visible in both connection snapshots as a barely-there mark in the top-right corner.

There is also no Escape key equivalent on the dismiss and no default button on "Try Again", so the panel cannot be dismissed or actioned from the keyboard.

**Impact:** A panel that auto-expands on failure and cannot be closed is a panel that eats the user's list. Under-3:1 glyph, under-24 pt target, keyboard-unreachable.
**Recommendation:** Apply the wizard's own fix — bump to the standard small close-button size with a ≥ 24 pt hit rect, tint at `secondaryLabel` or better, and give it `keyEquivalent = "\u{1b}"`. Make "Try Again" the default button (`keyEquivalent = "\r"`).

### P1-7 · The two state banners never re-theme: `updateLayer()` is overridden without `wantsUpdateLayer`
**Location:** `AudioutCore/Sources/AudioutPopoverUI/SilenceFallbackBannerView.swift:66–70`; `AudioutCore/Sources/AudioutPopoverUI/SystemAirPlayNoteBannerView.swift:174–178`

Both banners stamp `layer.backgroundColor` / `layer.borderColor` from a dynamic warm token at init, then rely on `updateLayer()` to re-stamp on an appearance change. `NSView.updateLayer()` is only invoked when `wantsUpdateLayer` returns `true`; neither class overrides it, and neither overrides `viewDidChangeEffectiveAppearance` either. **The re-stamp never runs.**

The initial stamp is also unguarded: unlike `ConnectionDiagnosisView.applyBackgroundTint` (`:230–239`), `LevelMeterView.updateLayerColors` (`:164–180`) and `FeedPillView.updateAppearance` (`:83–87`), it is not wrapped in `performAsCurrentDrawingAppearance`, so the token resolves against whatever drawing appearance happens to be current at construction.

Every other layer-colour view in the surface gets this right — these two are the only exceptions, and they are the two highest-stakes surfaces in the panel: *"Speakers unreachable — playing on this Mac"* and the routing-blocked warning.

**Impact:** Switch light↔dark (or toggle Increase Contrast) with a banner up and its fill/border stay at the old appearance's values — a dark-mode orange wash on a light panel, or an invisible one. The banner is the app's alarm; a mis-tinted alarm reads as a rendering bug and undermines trust in the warning itself. **Needs live check** to confirm the visual severity, but the code path is unambiguous.
**Recommendation:** Add `override var wantsUpdateLayer: Bool { true }` to both (matching `LevelMeterView`/`RouteArmedDotView`), *or* switch both to `viewDidChangeEffectiveAppearance` (matching `FeedPillView`/`ConnectionDiagnosisView`). Wrap the stamp in `effectiveAppearance.performAsCurrentDrawingAppearance`. The existing `test_backgroundColor` hooks make this trivially assertable.

### P1-8 · The "Speakers unreachable" banner is a dead end — a warning with no action
**Location:** `AudioutCore/Sources/AudioutPopoverUI/SilenceFallbackBannerView.swift` (whole class — no action parameter exists), contrasted with `SystemAirPlayNoteBannerView.Action` at `:24–28`

The sibling banner class supports a trailing call-to-action and uses it for three states ("Use Audiout", "Open Login Items…", "Buy…"). The silence-fallback banner has no such affordance at all: the user is told the speakers are unreachable and audio has fallen back to the Mac, and offered nothing — no retry, no "show me which one", no link. The label is also `isSelectable = false`, so the text cannot even be copied.

This is the one state where the product's core promise has audibly failed, in the room the user is standing in.

**Impact:** The highest-anxiety moment in the app terminates in a sentence. A user must work out for themselves that the fix is to find the failed row and click Try Again — which the banner does not point to.
**Recommendation:** Give it the same `Action` shape the note banner already has: "Try again" (re-kick every unreachable member via the existing `retryOutput` path). If a scroll-to/flash is cheap, the `DeviceRowView.flashLayer` A4 attention pulse already exists and is exactly the right primitive for "show me which one".

### P1-9 · A full rebuild can run mid-slider-drag and detach the row under the cursor
**Location:** `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:882` (`STABILITY(D4)` marker) and the rebuild at `:897–899`; the fragile drag flag at `AudioutSharedUI/DeviceRowView.swift:1970–1979`

Marked, understood, still open. `update(devices:)` calls `rebuild()` whenever routes, the device set, valid targets or Main-Out membership change — which can land in the middle of a volume drag. The row's protection is `isDraggingSlider`, set in `volumeChanged` and cleared only when `NSApp.currentEvent?.type == .leftMouseUp` happens to coincide with a change callback (`:1977`). The marker at `:1970` names the consequence: *"Esc/cancelled drags leave it stuck and the row ignores model updates."*

**Impact:** Two failure modes on the app's highest-stakes control. Either the row is torn out from under a live drag (the fader stops responding mid-gesture, on a speaker that is playing), or a stuck flag leaves the row permanently ignoring the model — showing a volume that is not the real one, which breaks "the UI never lies".
**Recommendation:** Two independent fixes. (a) Gate the rebuild: if any row reports a live drag, defer the rebuild to the next update (the drag ends within a second). (b) Clear the flag from a real gesture end — `NSSlider`'s tracking end or a `.leftMouseUp` local monitor scoped to the drag — never from a coincidence of two unrelated conditions.

---

## P2 — next pass

### P2-1 · Every device row installs an app-wide `.mouseMoved` monitor that can never fire
**Location:** `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift:2741–2752`, tracking areas at `:2593–2620`; `AppRowView.swift:794` carries the same marker

Each row (and each app row) installs `NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved])`, churned on every rebuild — the `STABILITY(D4)` marker at `:2743` flags the multiplicity. But nothing in the codebase sets `acceptsMouseMovedEvents = true` on any window (grep: zero hits), and the row's tracking areas use only `.mouseEnteredAndExited`, never `.mouseMoved`. macOS does not generate mouse-moved events for an app under those conditions.

So the cost is small (N dead closures) — but the *purpose* is unmet. The monitor exists as the documented "root-cause fix for a hover that sticks" (`:2707–2711`): the case where the pointer leaves the row into an untracked dead zone with no matching `mouseExited`. That case is currently uncovered.

**Impact:** A stale hover wash can persist on a row the pointer has left. On this panel a wash means "the pointer is here", so a stuck one is a small lie — and it sits one alpha step below the selection wash (`rowHoverWashAlpha` < `rowSelectionWashAlpha`), so it can read as a half-selected row. **Needs live check** to confirm the hover actually sticks.
**Recommendation:** Either set `acceptsMouseMovedEvents = true` on the shell window and keep *one* shared monitor on the panel (not one per row), or drop the monitors entirely and add `.mouseMoved` to the existing tracking area so exits are caught by AppKit's own machinery. Do not keep N inert monitors churned per rebuild.

### P2-2 · `draw(_:)` mutates a subview's `textColor`
**Location:** `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift:2789` (`nameLabel.textColor = rowTextColor` inside `draw(_:)`, immediately before `super.draw`)

Setting a property on a child view during the parent's draw pass invalidates that child mid-display. AppKit tolerates it, but it is an anti-pattern: it can schedule an extra display pass per row per draw, and it makes the label's colour depend on draw ordering rather than on `apply`.

**Impact:** Avoidable redraw churn on a panel with a dozen rows; a subtle correctness hazard if the label is ever drawn before the row.
**Recommendation:** Move the assignment into `apply(...)` and the hover/selection setters — every input it reads (`isInMenu`, `device.isAvailable`, `isSelectedInSet`) already changes there.

### P2-3 · Icon-only tabs: the app's top-level navigation is three unlabelled glyphs
**Location:** `AudioutCore/Sources/AudioutPopoverUI/SurfaceToolbar.swift:88` (`displayMode = .iconOnly`), rationale at `:14–22`

The reason is legitimate and well-evidenced — on macOS 26/27 every label-showing display mode builds the group's picker without its interactive expanded view and all three segments go dead. The tab names survive only as tooltips, subitem labels (VoiceOver / overflow menu) and ⌘1/⌘2/⌘3.

But the user cost is real and unmitigated: a first-time user sees three anonymous symbols and must hover each one to learn what the app contains. Groups and Settings — where saved speaker sets and the licence key live — are effectively undiscoverable without hovering.

**Impact:** The two screens a new user most needs to find are behind unlabelled icons.
**Recommendation:** Keep `.iconOnly` (the workaround is forced), but recover the names elsewhere: the secondary-click menu-bar menu already lists Settings and Groups — make sure it is discoverable, and consider a one-time first-run coach line under the toolbar naming the three screens. Re-test label modes on each macOS update and revert the moment the picker is fixed.

### P2-4 · Quit is a one-click toolbar item with a power glyph, adjacent to Pin, with no confirmation
**Location:** `AudioutCore/Sources/AudioutPopoverUI/SurfaceToolbar.swift:297–306`, layout at `:200–201`

`Quit` sits immediately beside `Pin` in the trailing toolbar group, bearing the `power` SF Symbol. One stray click stops audio in every room instantly, with no confirmation and no undo.

The glyph choice compounds it: in a panel full of speakers, `power` reads as "turn the speaker off", not "quit the application".

**Impact:** A destructive, irreversible action (in the live-audio sense) placed one pixel-miss away from a harmless one. Quit is already reachable via ⌘Q and the secondary-click menu-bar menu.
**Recommendation:** Remove Quit from the toolbar, or move it away from Pin with a separator. If it stays, use a glyph that reads as *app* quit and confirm when audio is actively streaming ("Stop audio in 3 rooms and quit?").

### P2-5 · The Bluetooth Connect row is a button styled as disabled placeholder text
**Location:** `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:2617–2643`

Borderless, `.accessoryBar`, title drawn in `Tokens.Color.secondaryLabel` (see P1-3 — 3.95:1 in light), no underline, no bezel, no disclosure chevron, no cursor rect. In `popover-light.png` it is indistinguishable from the "no apps routed" placeholder line rendered by `makePlaceholderRow`.

The rationale for not tinting it gold is correct and should be kept (gold means "in the mix"). The problem is that "not gold" was implemented as "not anything".

**Impact:** The Bluetooth path — and, per P1-1, the entire empty state of the device card — looks like dead text. Users will not click it.
**Recommendation:** Keep it neutral but make it an affordance: `Tokens.Color.linkText`-style treatment or a leading `plus.circle` / trailing `chevron.right` SF Symbol, plus a `resetCursorRects` pointing hand. It already carries a proper focus ring as a real `NSButton` — only the resting appearance needs to say "click me".

### P2-6 · The FEED column mixes routing facts and error states in one visual slot
**Location:** `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift:1070–1080` (precedence ladder: `.failed` → single "Couldn't connect" pill; unavailable → "Unavailable"; else one pill per feed value)

Under the header "FEED", the same column shows *what is feeding this speaker* ("System", "Music") on some rows and *why this speaker is broken* ("Didn't respond", "Unavailable") on others. Visible side by side in `popover-connection-light.png` and `popover-feed-composite-light.png`.

The precedence is deliberate and defensible (an error genuinely does override the feed), but the column *title* now lies about half its rows, and the two meanings share a pill shape.

**Impact:** A user scanning the column cannot tell at a glance whether they are reading a route or a fault. "Didn't respond" under a header called FEED parses as a routing state on first read.
**Recommendation:** Either drop the error out of the FEED column into the row's sublabel slot (which already carries "MUTED"), or give the error pill a distinct shape (leading `exclamationmark.triangle` glyph) so the two classes never rely on colour alone to separate. The failure-red text already helps; a shape difference makes it colour-blind-safe.

### P2-7 · Dead code: the entire local-mix "blocked" machinery is unreachable, and its snapshot fixture silently renders nothing
**Location:** `AudioutCore/Sources/AudioutCore/GroupController.swift:262–269` (the reason string, documented as retired) and `:413` (`canSelectLocalSpeaker` returns `true` unconditionally); `AudioutPopoverUI/PopoverController.swift:2215–2220` (no longer passes `blocked:`) vs. the still-live consumers at `PopoverController.swift:3765–3773` and `DeviceRowView.swift:138–143, 504–550, 772–773, 2008–2012, 2121–2124, 2658–2660, 2920–2924, 2968`

`GroupController` says it plainly: *"nothing in this type ever emits it as a refusal any more (T-GROUPCTL / Q5)… The popover wiring is retired separately in T-UI-ALLOW."* The popover half of that retirement happened for the *producer* (`:2215` no longer computes `blocked`) but not for the *consumers*: `isToggleBlocked`, `blockReasonText`, `.blocked` node style, the body-click refusal branch, the refusal note, the accessibility help, and `deviceRowDidRequestBlockedExplanation` all remain, permanently false.

The consequence for evidence: `popover-snapshot/main.swift:876–954` documents at length that the `local-mix-blocked` scenario mounts a refusal note under the Mac's row through the real body-click path. **`popover-local-mix-blocked-light.png` and `-dark.png` contain no such note** — the scenario now renders an ordinary panel with one hovered row, and its own doc comment describes a state the code can no longer produce.

**Impact:** No user-facing bug (the block is correctly gone), but two checked-in PNGs assert a behaviour that does not exist, and ~60 lines of unreachable branching sit in the most-edited row class. A future reader trusts the snapshot.
**Recommendation:** Finish T-UI-ALLOW: delete the blocked path from `DeviceRowView` and `PopoverController`, drop `localMixRefusalReason`, and either retire the snapshot scenario or repoint it at a state that still exists (the hover fixture it also carries is worth keeping).

### P2-8 · Banner containers claim `.staticText` while hosting a button
**Location:** `AudioutCore/Sources/AudioutPopoverUI/SystemAirPlayNoteBannerView.swift:154–155`; `SilenceFallbackBannerView.swift:57–58`

Both set `setAccessibilityRole(.staticText)` and `setAccessibilityLabel(...)` on the container view. `SystemAirPlayNoteBannerView` can contain an `NSButton` ("Use Audiout", "Open Login Items…", "Buy…") — an actionable control inside a container declaring itself static text.

**Impact:** Depending on how AppKit resolves the container's element-ness, VoiceOver may present the banner as a leaf and never reach the remedy button — which would leave the routing-blocked warning unactionable for a VoiceOver user. **Needs live check** with VoiceOver; the role/child mismatch is unambiguous in the code but AppKit's default `isAccessibilityElement` for a plain `NSView` is not.
**Recommendation:** Use `.group` for the container (the pattern `ConnectionDiagnosisView.configureAccessibility` already uses correctly at `:275–277`) so the button stays reachable, and keep the composed label on the group.

### P2-9 · Per-row `CADisplayLink`s: one animation clock per visible meter
**Location:** `AudioutCore/Sources/AudioutSharedUI/LevelMeterView.swift:97, 281–293`

Each meter owns its own display link. The class doc argues correctly that self-stopping at rest is why this is cheaper than `NSLevelIndicator` — and it is genuinely well done (zero CPU at rest, `restEpsilon` guard, no spin-up on a zero target). But with music playing to eight speakers plus the master strip, that is nine independent links running at up to 120 Hz on ProMotion, each doing its own `CATransaction` begin/commit.

`reduceMotion` is also re-read from `NSWorkspace` on every `setLevel` call (`:263–265`), i.e. once per level event per row.

**Impact:** Measurable but not severe main-thread work while the panel is open and audio is playing — exactly when the app must not stutter. Not a correctness problem.
**Recommendation:** If profiling shows it: one shared display link on the panel driving every mounted meter's `tick()`, stopping when all are at rest. Cache the Reduce Motion flag off `accessibilityDisplayOptionsDidChangeNotification` (the observer is already installed at `:126`).

---

## P3 — polish

### P3-1 · "Copy Details" is a permanently visible disabled button
**Location:** `AudioutCore/Sources/AudioutPopoverUI/ConnectionDiagnosisView.swift:101` (`copyDetailsButton.isEnabled = failure.detail != nil`)
Honestly disabled, which is right — but in both connection snapshots it renders as a greyed button beside "Try Again", which reads as "this app is broken" rather than "there is nothing to copy". Hide it when `failure.detail == nil`; a button that can never enable for this failure is not information.

### P3-2 · Card note and error copy are 11 pt
**Location:** `ConnectionDiagnosisView.swift:118, 124` (headline `boldSystemFont(ofSize: 11)`, suggestion `systemFont(ofSize: 11)`)
The panel that explains a failure uses the smallest type in the surface. Combined with P1-3's contrast, the app's most important explanatory sentence is also its least legible. Move the suggestion body to `NSFont.systemFontSize` (13 pt) — the banner classes already do (`:107`).

### P3-3 · "APP EXCEPTIONS" / "REDIRECT" vocabulary
**Location:** rendered in every snapshot; card title built in `PopoverController.rebuild()`
PRODUCT.md's terminology list says "per-app routing". The card says "APP EXCEPTIONS" with a "REDIRECT" column, and each row's default value is "Follows main output". Three different vocabularies for one concept, on a card whose entire purpose a new user must infer. As chrome the console flavour is allowed — but "exception" and "redirect" are the words a user must reason with to use the feature. Consider "APPS" / "SENDS TO", keeping "Follows main output" as the default value.

### P3-4 · The centred toolbar item has an empty `label`
**Location:** `SurfaceToolbar.swift:283` (`item.label = ""`)
Harmless today (the item is never customisable and never overflows), but it means the brand lockup has no name in any system-generated list. Give it `"Audiout"`.

### P3-5 · Slider track click jumps to the clicked value
**Location:** `AudioutSharedUI/WarmFaderCell.swift:46` — a pure drawing subclass of `NSSliderCell`; stock tracking behaviour applies
This is correct macOS behaviour and conformance says leave it. Worth recording only because the risk profile differs here: a mis-click near the right end of a 150 pt track sets a speaker in another room to 100 %. The Main Audio ceiling limits the blast, and the behaviour matches Control Center, so no change is recommended — but if user reports appear, the mitigation is a short confirm-on-large-jump, never a bespoke slider.

---

## Patterns / systemic issues

1. **A compliant token exists and the surface does not use it.** P1-3 and P1-4 are one problem: `Tokens.Color.secondaryLabel` / `.tertiaryLabel` are bare system aliases, the token file documents both as under floor, `inkSecondary` was authored as the fix, and it is confined to onboarding. Everything quiet in the popover is drawn with the non-compliant pair. This is a single sweep, not fifty fixes — and the `warmDynamic` governance around it is strong enough that the sweep will hold.

2. **Two views opted out of the house appearance idiom, and they are the two alarms.** Every layer-colour view in this surface re-resolves its `CGColor` on appearance change — via `viewDidChangeEffectiveAppearance` (`FeedPillView`, `ConnectionDiagnosisView`, `MembershipBusView`, `WarmCanvasView`, …) or `wantsUpdateLayer: true` (`LevelMeterView`, `HaloRingView`, `RouteArmedDotView`). The two banner classes do neither, and their `updateLayer()` overrides are unreachable. A lint rule — "an `updateLayer()` override requires a `wantsUpdateLayer` override" — would catch this class of bug permanently.

3. **The chrome is finished; the entrance is not.** Every *steady* state in this panel is designed to an unusually high standard. Every *transitional* state a first-time user meets — first click, first open, empty fleet, no permission — is either absent or actively misleading (P0-1, P1-1). The polish budget has been spent from the inside out and has not yet reached the door.

4. **A visual language that assumes vocabulary the design target does not have.** Dots on a wire for membership, a rail that cuts at a terminus, `AP1`, `+5`, `FEED`, `REDIRECT`, an invisible checkbox. Individually each is defended in the AGENTS file, and each defence is sound *within the mixing-desk metaphor*. PRODUCT.md names the tension explicitly — "mixer power, household words" — and this surface currently sits on the mixer side of it. The fix is almost never to remove the metaphor; it is to add the one cursor change, tooltip, or plain-language pill that lets a novice decode it.

5. **Known defects are marked but unfixed.** Six `STABILITY(D4)` markers survive across the surface (`PopoverController.swift:882`, `GroupRowView.swift:286,354`, `DeviceRowView.swift:1970,2743`, `AppRowView.swift:683,794`). Two of them (P1-9, P2-1) touch the volume control and the hover state. Marking is good practice; a release is the moment to close them.

6. **Snapshot evidence can drift silently.** P2-7 shows a checked-in PNG whose generator documents a state the code can no longer produce, with no failure signal — the scenario just renders something else. Snapshot scenarios that depend on a behaviour should assert that behaviour occurred before capturing (the harness already does this style of check elsewhere).

---

## Positive findings — do not break these

1. **VoiceOver composition is exemplary.** `DeviceRowView.configureAccessibility` (`:2880–2975`) composes the row label from the same facts the pixels draw, keeps the checkbox label *stable* across toggles while state rides the `value` (correct AX semantics), gates the FEED clause so no fact is spoken twice, speaks the energize pending beat as "connecting", and speaks a measured alignment rather than the nudge underneath it. The sync chip is exposed as a disclosure control with `accessibilityExpanded`. This is better than most shipping Mac apps.

2. **The focus ring traces the node, not the invisible box.** `InvisibleSwitchCell.drawFocusRingMask` / `focusRingMaskBounds` (`DeviceRowView.swift:3136–3148`) draws a circle around the drawn dot. A custom-skinned control that keeps a *correct* focus ring is rare and is exactly why the invisible cell is defensible at all.

3. **Reduce Motion is honoured everywhere it means something, including the ornament.** The splash is skipped entirely (`SurfaceSplashView`); folds resolve instantly (`FoldAnimator`); the energize beat is not seeded — *and the VoiceOver announcement still posts*, because an announcement is not motion. The meter snaps instead of easing. The reduce-motion snapshots prove the states still read.

4. **Failure copy is plain speech with a cause and a remedy.** "The speaker is visible on the network but isn't answering AirPlay requests — it may be stuck or held by another app. Power-cycle it, then try again." The takeover strings (`PopoverController.swift:1150–1161`) never say PTP or "ports 319/320". This is the voice rule being met.

5. **The live-removal undo is offered only when the click actually silenced a room**, with the facts read *before* the edit and the offer keyed on the controller rather than the row so a rebuild cannot destroy it (`AGENTS.md` line 39; `PopoverController.swift:1935`). Precisely the right instinct for a high-stakes surface.

6. **Meters cost nothing at rest.** `LevelMeterView`'s self-stopping display link, the zero-target-while-at-rest short circuit, and the surface-hide `resetLevel()` sweep mean a closed panel pays nothing and a silent room pays nothing.

7. **Hidden means idle, and it is defended.** `isEffectivelyShown` gates `update(devices:)`, both level pushes, and the note slot; `test_rebuildCount` exists specifically to pin that a closed panel does not rebuild per backend event. The rebuild-vs-refresh decision in `update(devices:)` (`:867–911`) compares against *what should render*, not the whole fleet.

8. **Engaged chrome is one neutral tone; hue is never how state varies.** Mute, hover, selection and the sync chip all draw `Tokens.Color.engagedChrome` at different alphas, with the system accent and gold both explicitly ruled out and the reasons recorded. The one deliberate exception (the A4 attention flash) is justified. This is what keeps the panel from becoming a colour puzzle.

9. **Failure red never appears in a meter.** House rule 8, enforced in `LevelMeterView` (`ember → gold → caution`, never `failure`) with a test hook reading the actual gradient. A loud party can never impersonate a fault.

10. **Muted state is conveyed by shape *and* text, not colour.** `popover-dormant-group-light.png` shows the engaged pill around the speaker glyph plus a "MUTED" sublabel plus a 0 % readout — three channels. Colour-blind-safe by construction.

11. **`ConnectionDiagnosisView` owns no pasteboard and no open/close state.** The host writes the clipboard and mounts/unmounts the panel; the view is a pure renderer with a correct `.group` accessibility container. Clean seam.

12. **Contrast is authored, not eyeballed.** `Tokens.swift` carries a measured WCAG rationale per custom colour, including Increase Contrast variants and the floors each one is held to. That the two system *aliases* slipped through (P1-3) is a gap in coverage, not in discipline — and the discipline is what makes the fix a one-line repoint.
