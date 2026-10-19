# Harden: Speakers tab, direction M

Made with impeccable `harden`, 2026-10-04. Starting brief: CRITIQUE.md problems 1 and 7, open questions 3, 8 and 10, and its "harden" follow-up. Owner rulings applied: Unavailable stays the fifth count; the sidebar's reachability mark is being redesigned elsewhere, so nothing here touches the dot's shape or colour, only which state a row is in.

Code citations are at `claude/speakers-nav` HEAD 050ba9a0. The four files the brief cites have not changed since 95f5fa60, so BRIEF.md's line numbers still hold. Widths are measured in the 13 pt / 11 pt system font with the same method that gives BRIEF.md's 139.9 pt for "MacBook Pro Speakers"; button widths are `NSButton` `.rounded` intrinsic widths.

Names in `code font` that don't exist yet (`startedAt`, `knownKinds`, `lostIDs`, `areLostSpeakersKnown`, `networkQuietWindow`, `pageDidAppear()`) are proposed code names for the builder.

## Amendments

### 1. When each number is known (replaces BRIEF.md "When each number is known", lines 132-144)

`SpeakerSearch` (`SpeakersPageViewController.swift:43-92`) gains per-kind state next to its existing tracker.

- **`startedAt`** is the earlier of two moments: the first `libraryDidChange()` whose live-id set is non-empty (the moment it already arms its ceiling, `:79-82`), or the first time the Speakers page appears on screen (new `pageDidAppear()`, called from the page's `viewDidAppear`). The second exists for the 0-speaker case (amendment 10).
- Each kind has its own `DiscoverySettleTracker`, `start()`ed at `startedAt` and fed, on every `libraryDidChange()`, the ids of that kind's records that have a live device (today's filter at `:77`, split by kind):

| Tile | Records fed | Quiet window | Known when |
|---|---|---|---|
| This Mac | none | none | a record with `isLocalDevice` and a live device exists |
| Bluetooth | kind `bluetooth` | 0.5 s (`SpeakerSearch.quietWindow`, `:48`) | its tracker settles |
| AirPlay | kind `homePod`, `appleTV`, `airportExpress`, `sonos`, `generic` | **2.0 s** (new `networkQuietWindow`) | its tracker settles |
| Cast | kind `cast` | **2.0 s** | its tracker settles |

- At `startedAt` + 10 s (`SpeakerSearch.ceiling`, `:51`) every kind not yet known becomes known with its current count.
- A change in availability (speaker seen, then out of reach) does not re-arm a tracker; it changes the shown number in place.
- `SpeakerSearch` exposes `knownKinds` and calls the host back when it grows; the page swaps a placeholder for its number when that kind joins `knownKinds`.
- **Why AirPlay and Cast wait 2.0 s and start at once.** An AirPlay speaker only appears after the Mac's test connection to it opens (`NativeDiscovery.swift:984-995`), and Bonjour waits at least 1 s before asking a second time (RFC 6762 section 5.2), so a speaker that missed the first question arrives a second or more after the rest. Today's 0.5 s window, armed on first arrival, is what lets "0 AirPlay · 15 Unavailable" look final (CRITIQUE problem 1). Starting the tracker at `startedAt` lets a home with no Cast speaker settle to 0 at 2.0 s instead of waiting for the ceiling.
- **The owner's fleet, arrival times illustrative:** This Mac at 0 s; the Bluetooth list at 0.1 s, so Bluetooth 0 at 0.6 s; Cast at 0.2, 0.5, 0.9 s, so Cast 3 at 2.9 s; AirPlay at 0.3, 0.4, 0.6, 1.1 s, so AirPlay 4 at 3.1 s; Unavailable 12 and "20 speakers" at 3.1 s; "6 speakers can't be found" at 10 s (amendment 4).
- **BRIEF.md edits:** replace the table at lines 136-142 with the one above; replace the `SpeakerSearch` bullet in Builder notes (line 200) with this amendment and delete the "Cheaper fallback" sub-bullet (line 201); mark open question 8 settled by this rule.

### 2. The analytics event stays exactly where it fires

- `speaker:library_counted` still fires once, from `SpeakerSearch.finish()` (`:86-91`), triggered by the same two things as today: the overall tracker (0.5 s with no change in any live id, `:69-70`, `:83`) or the ceiling (`:79-82`). Same name, same nine properties from `SpeakerLibraryCounts.analyticsProperties` (`:31-35`), same moment.
- The three kind trackers are separate instances. They never call `finish()` and are never fed into the overall tracker.
- The ceiling closure at `:81` keeps calling `finish()` first, then marks the remaining kinds known.
- `SpeakerLibraryCounts` keeps today's `found`, `away`, `lost` and `unknown` meanings, because the event reports them. The page's five numbers come from a new struct beside it (BRIEF.md line 199 already says this; keep it).
- `isDone` and `onDone` keep meaning "the analytics moment". The page stops reading them: `AppDelegate.swift:1100` and `:2419` rewire to the new `knownKinds` callback and to amendment 4's `lostIDs`.
- Known limit, unchanged on purpose: on a slow network the event can still fire before AirPlay answers. Fixing that moves when it fires (BRIEF.md open question 8), so it is out of this pass.

### 3. Unavailable, the total and the finish announcement

- The Unavailable tile, the header total and the one VoiceOver announcement "Finished looking for speakers." (BRIEF.md line 188) wait until all four kinds are in `knownKinds`. Nothing else about them changes.
- After that, every number stays live with the 180 ms fade and no placeholder ever returns (BRIEF.md line 144, unchanged).

### 4. One can't-be-found set, held for 10 s, read by every door

- The host computes `lostIDs`: records with `!isLocalDevice && liveDevice == nil`, **empty until `areLostSpeakersKnown`**, which turns true at `startedAt` + 10 s. Then leave out:
  - (a) Bluetooth records while Bluetooth access is not `.granted` (BRIEF.md open question 7, kept);
  - (b) records whose kind is `nil` or `isDiscoveredOverLocalNetwork` (`Device.swift:48-55`) while Local Network access is known to be off (amendment 7), or while no AirPlay or Cast record has had a live device this launch (amendment 6).
- **Why the full 10 s, not the 2-3 s the numbers take.** Forget is the page's only destructive offer, and "can't be found" claims the Mac never saw the speaker this launch. 10 s is the ceiling the code already treats as "discovery is over" (`:49-51`), and it spans Bonjour's repeat questions at about 1, 3 and 7 s (RFC 6762 section 5.2: each wait at least doubles).
- **All three readers switch to `lostIDs`**, pushed by the host on every change the way `setBluetoothAccess` is (`SpeakersPageViewController.swift:222-225`):
  - the page's row: replaces `:247-248`;
  - the sidebar's `isLost` (`SidebarViewController.swift:457-459`), which drives the spoken ", can't be found" (`:1314`), the "Can't be found" tooltip and the menu's Forget (`:388-391`, `:412-417`);
  - the speaker page's `isLost` (`DeviceDetailViewController.swift:594-596`), which drives the "Can't be found" caption and glyph (`:646-654`) and its Forget button (`:612`).
- Until the set fills, a remembered speaker not yet seen shows its ordinary status: the sidebar says ", unavailable" (", not connected" for Bluetooth, CLARIFY.md 2); its page shows kind and status from `SpeakerPresentationRecord.status` (`SpeakerLibraryController.swift:109-122`), for example "Sonos · Unavailable", "Bluetooth · Not connected", or "Missing speaker"; no Forget anywhere.
- The row appearing at 10 s pushes the Bluetooth and Pair rows down 44 pt under a pointer that may be on its way to Pair. Accepted: the sheet it opens keeps Cancel on Return (`MixerWindowController.swift:582-583`) and names the speakers (CLARIFY.md 1).
- BRIEF.md edits: rewrite "Can't-be-found set" (line 130) to this rule; close open questions 3 and 10 with it; the "Row states" table (lines 58-65) reads "once `lostIDs` holds it" where it says "once the first search has settled".

### 5. Right-click Forget waits for the same set

- While `lostIDs` is empty, a shown speaker's menu ends at **Speaker settings…** with no separator after it; with several selected, no **Forget N speakers…** item appears. Nothing else in the menu moves (`SidebarViewController.swift:367-418`).
- `requestForget` (`MixerWindowController.swift:530`) intersects the ids it is handed with the current `lostIDs` before building the sheet, so a menu built before a speaker came back never names that speaker. If nothing is left, no sheet.
- A speaker that comes back while the sheet is open is already skipped at confirm: `forget` re-filters to `liveDevice == nil` (`SpeakerLibraryController.swift:253`). The sheet's names can be one out of date; no change needed.

### 6. When no network speaker has answered at all

- Rule: while no record of kind AirPlay or Cast has had a live device this launch, records of those kinds, and records with no kind, stay out of `lostIDs`. They count in Unavailable; the sidebar says ", unavailable".
- Why: a network where nothing answers is far more likely Wi-Fi off, Local Network access off but not yet detected, or a network that blocks devices from seeing each other, than every speaker gone at once. The popover already reasons this way: a browsed Cast receiver "means the network is visibly working" (`PopoverController.swift:2087-2103`). Without this rule the page offers "Forget 16 speakers…" for a Mac whose Wi-Fi is off (CRITIQUE problem 7).
- Flag, not built: in this state the page shows a large Unavailable count with no reason unless amendment 7's signal is known. The popover's own line, "No AirPlay speakers found on your Wi-Fi network." (`PopoverController.swift:2141`), could become a row here later.

### 7. Local Network access row

- **Title:** Local Network access is off
- **Tooltip and VoiceOver hint:** Allow Local Network access in System Settings to see AirPlay and Cast speakers.
  (Same shape as the Bluetooth row's "Allow Bluetooth access in System Settings to see paired speakers that are not connected.", `SpeakerLibraryController.swift:77`.)
- **Button:** Open Privacy Settings… → `NSWorkspace.shared.open(SystemSettingsPane.localNetwork.url)` (`SetupModel.swift:126`, `:149-150`, the "Privacy_LocalNetwork" anchor).
- **Glyph:** `ListRowView.glyph("wifi")`, the symbol setup's Local Network card uses (`OnboardingViewController.swift:721`), in the rows' ordinary glyph ink. Not `Tokens.Color.permissionLocalNetwork`: the permission hues are fenced to onboarding.
- **Shown when** the host's existing signal reads denied: `permissionAuditModel?.localNetworkStatus == .denied`, the same read the popover's AirPlay section uses (`AppDelegate.swift:1385-1391`). Never on `.unknown` or `.requested`, so the row never appears on a guess. Never on macOS 14, where the model reports granted (`SetupModel.swift:562-566`).
- **Updates:** the host pushes it (new setter beside `setBluetoothAccess`) when the page is built and after each permission audit finishes (`AppDelegate.swift:2050-2053`). The audit runs on every app activation (`:1599-1608`), so coming back from System Settings clears the row. A denial found there also reopens setup with its permission-lost banner (`:2056-2058`, `SetupModel.swift:1192-1193`); the row is what the page says if the user closes setup.
- **Position:** strip, can't-be-found row, **Local Network access is off**, Bluetooth access is off, Pair. Both access rows sit together; Local Network goes first because it explains more of the Unavailable count.
- **Effect on the numbers:** none special. AirPlay and Cast settle to 0 by amendment 1, which is what the Mac sees. Network records stay out of `lostIDs` (amendment 4b). After the user allows it, speakers arrive and numbers change in place, with no placeholder.
- **Fit:** 166.1 pt title + 168.5 pt button + `ListRowView` insets and gaps (`ListRowView.swift:14-20`) = 404.6 pt in the 415 pt card.
- **Analytics:** a new button is a new user action (CLAUDE.md, "New user-facing features get instrumented"). Fire `speaker:privacy_settings_opened` with `["access": "local_network"]` at the host's handler, after the open call. Add the row to `docs/analytics-events.md` in audiout-shared before sending it. The Bluetooth row's button sends nothing today; giving it `["access": "bluetooth"]` is a one-line follow-up, not part of this pass.
- **Mockup:** add a fifth state panel, "Local Network access off": 6 speakers, 0 · 1 · 0 · 1 · 4, rows: Local Network access is off [Open Privacy Settings…], Pair. Note under it: "No Forget: the Mac can't look for network speakers."

### 8. Bluetooth access off

- The Bluetooth tile counts connected speakers only. macOS still lists those through Core Audio without access; paired speakers that aren't connected disappear from the list (`BTDeviceEnumerator.swift:108-121`).
- A remembered Bluetooth speaker macOS no longer lists counts in Unavailable, never joins `lostIDs` (amendment 4a), speaks ", not connected" in the sidebar (CLARIFY.md 2), and its page reads "Bluetooth · Not connected" (`SpeakerLibraryController.swift:120`).
- The "Bluetooth access is off" row is unchanged; its button follows the status (`SpeakerLibraryController.swift:70-89`): denied, **Open Privacy Settings…**; not asked yet, **Allow Bluetooth…**, and no button while the prompt is up; unsupported, no button.
- Access granted mid-session: the enumerator re-lists paired speakers (`BTDeviceEnumerator.swift:203-206`). Numbers change in place; a paired speaker the library didn't know raises the total by one. No placeholder.
- Mockup panel 4: keep; change its note to "Paired speakers macOS won't list without access count as unavailable, say "not connected", and stay out of Forget. The 2 that can't be found are network speakers."

### 9. A speaker that appears, or leaves, after the numbers are known

- **New speaker** (never in the library): the total and its kind go up by one (Unavailable instead, if it isn't reachable); a sidebar row appears in alphabetical order under the first subsection, because a new speaker's Mixer setting is When available. Each changed number takes the 180 ms fade and posts `.valueChanged` on its tile; nothing is announced; no placeholder.
- **A can't-be-found speaker answers:** it leaves `lostIDs`. The row's count drops by one and the row goes at zero; Unavailable drops and its kind rises; the sidebar ring becomes filled and the "Can't be found" tooltip goes; if its page is open, the caption and Forget give way to the live page in place.
- **A seen speaker goes away** (switched off): it keeps its live device (`OutputBackend.swift:28-30`), counts as Unavailable, and is never "can't be found" this launch.
- **A laptop opened on another network:** every home speaker goes unseen, so after 10 s the page offers to forget all of them. The statement is true; the sheet naming them (CLARIFY.md 1) is the guard. If that network has no AirPlay or Cast speaker at all, amendment 6 keeps them out.

### 10. 0 speakers

- When: the library holds no live device, no saved details and no scene member (`SpeakerLibraryController.swift:291`). This Mac is added the moment the backend starts (`NativeBackend.swift:2066`), so 0 happens only before that, or when Core Audio never reports the Mac's own output.
- Page: header caption **No speakers** (VoiceOver the same). Placeholders until known; `pageDidAppear()` sets `startedAt`, so even if nothing ever arrives all five numbers settle 10 s after the page appears instead of shimmering for ever. Then 0 · 0 · 0 · 0 · 0, every zero in `label3`. Rows: the access rows if true, Pair. No can't-be-found row.
- This Mac at 0: label "This Mac"; VoiceOver **This Mac, unavailable**.
- Sidebar: System Audio, Main Audio plate, Speakers, Overview plate, then the first subsection header with nothing under it. Keep the header: it is a drop target and is never removed (`SidebarViewController.swift:531`). No second subsection.

### 11. About 60 speakers

- Counts: "60" is 20.7 pt at 16 pt semibold, the placeholder's 20 pt; "100" is 28.2 pt, inside the 55 pt a count has (77.4 − 16 glyph − 6 gap).
- Header: "60 speakers".
- Row: "41 speakers can't be found" (163.3 pt) and **Forget 41 speakers…** (150.0 pt) need 383.3 pt of the 415 pt card. If a title ever runs long, it truncates and the button keeps its size (`ListRowView.swift:60-62`, `:104`).
- Busy networks: speakers coming and going keep a kind's tracker from going quiet; the 10 s ceiling then decides (amendment 1). That is the ceiling's job.
- Sidebar: one stock scroll view; the two plates scroll with the list, as Finder's sidebar items do. The second subsection keeps its folded state (`:541`).
- Forget sheet: two names at most (CLARIFY.md 1).
- Cost does not grow with the fleet: at most six placeholders share one moving highlight, and the page rebuilds a handful of rows per change.

### 12. The two long Sonos names

- Measured at 13 pt: "Move 2 (SONOS Bedroom)" 161.7 pt, "Sonos Move (SONOS Kitchen)" 182.6 pt, in a name column of about 128 pt (BRIEF.md line 29). Both are cut today.
- **Truncate speaker names in the middle** (`lineBreakMode = .byTruncatingMiddle` on the speaker row's name field only; headers and captions keep tail truncation). Results at 128 pt:
  - tail (today): "Move 2 (SONOS B…", "Sonos Move (SON…"
  - middle: "Move 2 (…Bedroom)", "Sonos Mov…Kitchen)"
  The room is what tells two Sonos speakers apart, and it sits at the end of the name. "MacBook Pro Speakers" becomes "MacBook …Speakers".
- Set `outlineView.allowsExpansionToolTips = true` (it is set nowhere today, `SidebarViewController.swift:170-185`) so hovering a cut name shows it whole.
- A row that also carries a state tooltip (CLARIFY.md 2) puts the full name on the tooltip's first line, so the name is never hidden behind it.
- VoiceOver already speaks the full name (`spokenName`, `:1312`). The overview never shows names.
- Mockup: in the owner's fleet both rows are rings with the Bluetooth glyph. Draw them middle-truncated, and draw one hover tooltip: "Move 2 (SONOS Bedroom)" over "Not connected".

### 13. A long translation of "Unavailable"

The app ships in English today; this keeps the strip from breaking when it doesn't. Measured at 11 pt against the 64.4 pt label slot (77.4 tile − 1 rule − 12 gap):

| Language | Word | Width |
|---|---|---|
| English | Unavailable | 60.3 |
| French | Indisponible / Non disponible | 63.5 / 78.5 |
| German | Nicht verfügbar | 82.2 |
| Italian | Non disponibile | 81.3 |
| Dutch | Niet beschikbaar | 88.5 |
| Russian (one word) | Недоступно | 65.9 |

- Rule: the Unavailable tile is as wide as its content needs, at least 77.4 pt: 13 pt plus the wider of its label and its glyph-and-count. The four kind tiles share what is left equally, each at least 62 pt ("Dieser Mac" is 58.8 pt). That allows a label of up to 126 pt on one line: German makes the tile 95.2 pt and each kind tile 73.0 pt; Dutch 101.5 and 71.4.
- Past 126 pt the label truncates at the tail; the tile's VoiceOver value is a full sentence anyway.
- No wrapping: a two-line label would make that tile taller than the other four, and a single long word such as the Russian one cannot wrap.
- Build: the strip is a `.fillEqually` stack today (`SpeakersPageViewController.swift:340-345`). Make it `.fill`, pin the four kind tiles equal in width with a 62 pt floor, give the Unavailable tile a 77.4 pt floor and high hugging. The "Available" caption spans whatever the four kind tiles take.
- Mockup: add a small zoom of the strip with "Nicht verfügbar", tile widths labelled.

### 14. Mockup changes (for the agent applying passes)

- "How the numbers fill in" panel: redraw with amendment 1's illustrative times (Bluetooth 0.6 s, Cast 2.9 s, AirPlay 3.1 s, Unavailable and total 3.1 s, can't-be-found row 10 s).
- Panel 1, "Mid-search, 1.5 s after launch": This Mac 1 and Bluetooth 0 known; AirPlay, Cast, Unavailable and the total still loading. Note: "AirPlay waits until no new AirPlay speaker has appeared for 2 s."
- Add the Local Network panel (amendment 7) and a "No speakers" panel (amendment 10).
- Panel 4 note per amendment 8; long names and tooltip per amendment 12; the German strip zoom per amendment 13.

### 15. Tests that buy their place

Each names the defect it turns red on.
- `SpeakerSearch`: with only This Mac and Bluetooth arriving, AirPlay is not in `knownKinds` at 1.9 s and is at 2.0 s. Catches the AirPlay number settling on the overall 0.5 s window again.
- `SpeakerSearch`: `speaker:library_counted` fires once, at the overall 0.5 s settle, with unchanged properties, while AirPlay is still unknown. Catches the event being moved onto the page's rule.
- `lostIDs`: empty at 9.9 s, filled at 10 s; and with no AirPlay or Cast record ever live, network records stay out at any time. Catches Forget offered for slow or unreachable speakers.
- Sidebar menu: with `lostIDs` empty, a never-seen speaker's menu has no Forget item. Catches the right-click door bypassing the hold.

### 16. New strings for COPY.md

| Where | String |
|---|---|
| Overview, header caption at 0 | No speakers |
| Overview, This Mac at 0, VoiceOver | This Mac, unavailable |
| Row title | Local Network access is off |
| Row tooltip and hint | Allow Local Network access in System Settings to see AirPlay and Cast speakers. |
| Row button | Open Privacy Settings… (shipped string, reused) |

## For the owner

1. Forget and "can't be found" wait 10 s after launch even when the numbers settle sooner. Default: yes, because it is the only destructive offer.
2. Speaker names in the sidebar truncate in the middle so the room stays visible. Default: yes, sidebar only.
3. The once-per-launch counts event can still fire before AirPlay answers on a slow network. Default: leave it, so its history stays comparable.
