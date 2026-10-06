# Clarify: Speakers tab, direction M

Made with impeccable `clarify`, 2026-10-04. Starting brief: CRITIQUE.md problems 2, 5 and 8, its minor note on the Overview title, and its "clarify" follow-up. Owner rulings applied: Unavailable stays the fifth count; the sidebar's reachability mark is redesigned elsewhere, so only the words attached to it change here.

Code citations are at `claude/speakers-nav` HEAD 050ba9a0 (the cited files are unchanged since 95f5fa60). Widths are 11 pt system font, measured the way BRIEF.md measures. `lostIDs` is the can't-be-found set defined in HARDEN.md amendment 4.

## Amendments

### 1. The Forget sheet names the speakers, and says what happens if one comes back

Today the sheet for several speakers names nobody: "Forget 6 speakers?" / "They will be removed from 2 scenes." (`MixerWindowController.swift:571-577`).

**Which names, in what order**
- The speakers being forgotten (after HARDEN.md amendment 5 trims them to `lostIDs`), in the sidebar's order: display name compared with `localizedStandardCompare`, then id (`SidebarViewController.swift:516-521`).
- A speaker with no saved details ("Missing speaker", `metadataIsKnown == false`, `SpeakerLibraryController.swift:302-304`) is never named; it only counts toward "more".
- Every speaker named and 3 or fewer: name them all. Otherwise name the first two named speakers, then "and N more". This never produces "and 1 more" unless the last one has no name.
- Names in curly quotes joined by ", ", the pattern the refusal sheet already uses for scene names (`MixerWindowController.swift:564`).

**Strings.** Titles and buttons unchanged: `Forget “Name”?` / `Forget N speakers?`; **Forget** (destructive, not on Return) and **Cancel** (on Return), `:578-583`.

| Case | Informative text |
|---|---|
| One speaker, in scenes | It will be removed from 2 scenes. If it turns up again, it comes back to the speaker list, but not to those scenes. |
| One speaker, no scene | It isn’t in any scene. If it turns up again, it comes back to the speaker list. |
| Several, in scenes | “Onkyo TX-8220”, “teevee” and 4 more will be removed from 2 scenes. If one turns up again, it comes back to the speaker list, but not to those scenes. |
| Several, no scene | “Onkyo TX-8220”, “teevee” and 4 more aren’t in any scene. If one turns up again, it comes back to the speaker list. |
| Several, 3 or fewer, all named | “ION Speaker”, “isaac” and “teevee” will be removed from 1 scene. If one turns up again, … (same ending) |
| Several, none named | They will be removed from 2 scenes. If one turns up again, … (same ending) |

"1 scene" / "N scenes" as today (`:575-576`). The example names are the critique's two, in sidebar order: the sort ignores case, so "Onkyo" comes before "teevee". For the mockup, use the first two lost names in the mockup's own sidebar order.

**Why the second sentence is true.**
- `forget` removes the speaker from every scene (`SpeakerLibraryController.swift:258`) and deletes its saved details and Mixer setting (`:262-266`).
- The speaker list is every live device plus every saved one (`:291`), so a forgotten speaker that answers again is listed again, with the default Mixer setting, When available, and in no scene.
- Forget does not touch the stored equalizer (`DeviceEQStore` has no removal, and the Forget path writes only the library file and scenes). The copy makes no claim about tone either way.

**Other notes.**
- The refusal sheet ("Can’t forget 6 speakers" / "Delete “Kitchen” first: it has no other speaker.", `:561-569`) stays: what the user must do there is about the scene, and it names the scene.
- Build each row of the table as one whole sentence with the list and counts as values, not joined fragments, so a translation can reorder it.
- NSAlert wraps its informative text, so the long Sonos names wrap rather than cut; two names keep the sheet to about three lines.
- Mockup: draw the sheet for the owner's six beside the window.

### 2. Bluetooth: "Not connected" for the speaker, "Unavailable" for the count

**Where it is counted: in Unavailable, the fifth count** (owner's ruling stands).
- He asked for "the bluetooth ones you have connected", so the Bluetooth number means connected to this Mac (BRIEF.md counting rule, line 125).
- The Mac cannot tell a paired speaker that is switched off from one that is on but not connected. macOS lists both with `isConnected == false` (`BTDeviceEnumerator.swift:108-111`), and a connect attempt to a switched-off speaker runs about 15.4 s before failing (`BTConnectionManager.swift:21-26`). It can't be counted as available.
- The app's counts already use "unavailable" for it: a scene card's "2 unavailable" counts every member with `!isAvailable` (`GroupsOverviewViewController.swift:258-261`, `:637`), paired-but-not-connected Bluetooth included.
- It is never in `lostIDs` while macOS lists it: it has a live device.

**The words.** "Unavailable" is the count's word; "Not connected" is the speaker's own state, as the speaker page (`SpeakerLibraryController.swift:19`, `:120`) and the scene editor rows (`MembershipRowView.swift:330`) already say.

| State | Sidebar, spoken suffix | Sidebar tooltip, line 2 | Speaker page caption | Overview |
|---|---|---|---|---|
| Reachable, or Bluetooth connected | none | no tooltip | e.g. "Sonos · Ready", "Bluetooth Speaker · Connected" | its kind's number |
| Bluetooth, listed but not connected | , not connected | Not connected | Bluetooth Speaker · Not connected | Unavailable |
| Bluetooth, not listed because Bluetooth access is off | , not connected | Not connected | Bluetooth Speaker · Not connected | Unavailable |
| Network or unknown kind, out of reach or not seen yet | , unavailable | Unavailable | e.g. "Sonos · Unavailable"; no saved details: "Missing speaker" | Unavailable |
| In `lostIDs` | , can’t be found | Can’t be found | "<Kind> · Can’t be found", glyph, Forget (`DeviceDetailViewController.swift:646-654`) | Unavailable, and the can't-be-found row |

Kind names on the speaker page are `kindText(for:)`'s (`DeviceDetailViewController.swift:775-786`).

**Sidebar changes**
- Spoken suffix (`SidebarViewController.swift:1313-1318`): a ring on a Bluetooth record not in `lostIDs` says ", not connected" instead of ", unavailable".
- **Every ring row gets a tooltip**: line 1, the speaker's full name; line 2, the state word from the table. A speaker with no saved details adds its id as line 3 (today's whole tooltip, `:1191`).
- Why every ring row: a ring alone cannot say which of the three states a row is in, and CRITIQUE heuristic 6 found the 6 can't-be-found speakers impossible to pick out among 12 rings. The tooltip says what VoiceOver already hears. The full name on line 1 also covers HARDEN.md amendment 12.

**Overview change**
- Unavailable tile tooltip and VoiceOver hint (BRIEF.md line 189): "Speakers your Mac can’t reach right now." becomes **Speakers your Mac can’t reach right now, and Bluetooth speakers that aren’t connected.**
- Not the critique's "Speakers that are switched off, out of reach, or not connected.": a reachable AirPlay speaker that isn't connected counts as Available ("Ready"), so "not connected" has to stay tied to Bluetooth.
- The tile's VoiceOver value stays "12 speakers unavailable"; the Bluetooth tile's help stays "Bluetooth speakers connected to this Mac right now."

**Flag, outside this tab:** the Mixer row says "Unavailable" for a not-connected Bluetooth speaker (`DeviceRowView.swift:1176-1177`), while the scene editor and the speaker page say "Not connected". Worth one line in a later Mixer pass.

### 3. "Shown while playing" becomes "Shown while in use", checked against the code

**The actual condition.** The caption shows when a speaker in the second subsection is visible in the Mixer (`SidebarViewController.swift:461-464`). For a hidden speaker that means `isInUse` (`SpeakerLibraryController.swift:124-131`), which is true when the speaker (`:44-55`, `:199-218`, `:292-297`) is any of:
- one of Main Audio's speakers (the selected speakers, or the members of the scene Main Audio uses), whether or not anything plays;
- where an app is routed, directly or through a scene, whether or not that app is playing;
- receiving an app's audio now;
- being reconnected after a drop;
- connected, connecting or reconnecting.

"Playing" is false for a selected speaker in silence, a speaker whose routed app is closed, and a speaker still connecting. "In use" is true for all of them and is the setting's own name, **Hide when not in use** (`SpeakerLibraryStore.swift:14`), which the speaker page's pop-up and the popover's speaker menu show (`PopoverController.swift:3317`).

| Where | Now in M | Becomes | Width |
|---|---|---|---|
| Caption on a hidden speaker in use (`SidebarViewController.swift:98`) | Shown while playing | **Shown while in use** | 99.5 pt in about 128 pt |
| Its VoiceOver suffix (`:1319`) | , shown in the Mixer while playing | **, shown in the Mixer while in use** | |
| Second subsection header (`:95`) | Hidden unless playing | **Hidden unless in use** | 108.6 pt in about 166 pt |
| Speaker page, Show in Mixer caption (`DeviceDetailViewController.swift:700`) | Shown only while it plays. | **Shown only while it’s in use.** | |

- The header has the same condition and the same flaw: a hidden speaker selected in silence sits under "Hidden unless playing" while the Mixer shows it. With both changed, the header states the setting and the caption says when it is happening. The first words still differ (Shown in Mixer / Hidden unless in use), which is why COPY.md kept them apart.
- The owner said "hidden unless playing" in his brief, so the header change is his call. Default: change it.
- Strike COPY.md's optional rename of "Hide when not in use" to "Only while playing" (COPY.md line 91, BRIEF.md open question 11): it would make the setting promise something the code doesn't do.
- BRIEF.md and COPY.md lines to update: BRIEF 25, 31, 64, resolved conflict 3 (line 210); COPY 16-18, 60-61, 72-73, 77, 83. The window harness check at `window-harness/main.swift:98-99` follows the header.
- Mockup: the captioned row (Fancyy) and the second header.

### 4. The Overview plate opens a page titled "Overview"

- Change the page title from "Speakers" to **Overview** (`SpeakersPageViewController.swift:119`).
- Why: this code titles a page with the words its sidebar row carries. The Main Audio page says so outright (`MainOutDetailViewController.swift:39-40`), and a speaker's page takes its row's name (`DeviceDetailViewController.swift:603`). System Settings and Music behave the same way. Clicking "Overview" and landing on "Speakers" reads as landing somewhere else.
- Context stays: the tab is Speakers, the section title above the plate is Speakers, the icon well keeps `hifispeaker.2` with the VoiceOver label "Speakers" (`:143-144`), and the caption under the title is the total, "20 speakers". "Speakers" appears three times on screen instead of four (CRITIQUE heuristic 8).
- The plate's VoiceOver label stays **Speakers overview** (BRIEF.md row 5): heard alone, "Overview" says too little.
- Rejected: "Speakers overview" as the title. It breaks the row-equals-title rule and puts the fourth "Speakers" back.
- COPY.md line 14 changes from "Speakers / Unchanged" to "Overview", with the reason above. The suites COPY.md already lists cover the title assertions.
- Mockup: the window's page title.

### 5. The Main Audio plate gets no state line

Decision: no visible second line.
- The owner's ask, "they see what it is … have its own title and be highlighted in the same way that speakers is", is about knowing what the row is. A "System Audio" section with Main Audio on its own plate does that (CRITIQUE: "Met").
- The page behind the plate has nothing to summarise: "there is no status, no volume, no membership to show" (`MainOutDetailViewController.swift:11-14`). Its one control is the Main Audio equalizer.
- A line such as "Playing" or "Kitchen + 2" would be the only playback readout in a tab that only configures, where the sidebar shows presence and never routing (`AudioutWindowUI/AGENTS.md`, Purpose and Rules). The Mixer tab, one click away, already shows it.
- A second line makes this plate 44 pt beside the 36 pt Overview plate (`PlateRowView.rowHeight`), and the two plates stop matching.
- If the owner wants one anyway: the single word "Playing", in gold, only while audio is reaching a speaker; no line otherwise. It names no speakers, so it never has to describe routing.

### 6. Strings added or changed by this pass, for COPY.md

| Where | String |
|---|---|
| Forget sheet bodies | the six rows in amendment 1 |
| Sidebar, Bluetooth ring, spoken | , not connected |
| Sidebar, ring rows, tooltip | full name, then Unavailable / Not connected / Can’t be found |
| Overview, Unavailable help | Speakers your Mac can’t reach right now, and Bluetooth speakers that aren’t connected. |
| Sidebar caption | Shown while in use |
| Sidebar caption, spoken | , shown in the Mixer while in use |
| Second subsection header | Hidden unless in use |
| Speaker page, Show in Mixer caption | Shown only while it’s in use. |
| Overview page title | Overview |

## For the owner

1. Second header "Hidden unless in use" instead of your "hidden unless playing", because a hidden speaker that is selected but silent also shows in the Mixer. Default: change it.
2. No state line on the Main Audio plate. Default: none; fallback is "Playing" in gold while audio reaches a speaker.
