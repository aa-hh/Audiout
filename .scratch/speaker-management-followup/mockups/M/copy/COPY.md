# Direction M: sidebar and Speakers page copy

Settled 2026-10-04 against `claude/speakers-nav` at 95f5fa60. Checked against CONTEXT.md, PRODUCT.md, DESIGN.md, the audiout-copy-review term table and the strings the Swift sources ship today. File paths below are under `AudioutCore/Sources/` unless they start at the worktree root.

## Final strings

| Where | String | Why |
|---|---|---|
| Sidebar, top section header | System Audio | The popover's card pairs this same header with the Main Audio row (`AudioutPopoverUI/PopoverController.swift:2436`), and macOS names the permission users granted "System Audio Recording". |
| Sidebar, top section plate | Main Audio | The locked term for the master output. Only its styling changes, to a plate like the Speakers one. |
| Sidebar, second section header | Speakers | True of every row under it, This Mac included. "External speakers" is not (see below). |
| Sidebar, second section plate | Overview | The owner's own word for this page. It promises a summary, and the page is one: it lists no speakers. |
| Plate, VoiceOver label | Speakers overview | Replaces "Speakers, manage speakers" and makes sense heard without the header. |
| Speakers page title | Speakers | Unchanged. It matches the header the plate sits under. |
| First subsection header | Shown in Mixer | The setting is called Show in Mixer; this is its past tense. Holds When available and Always speakers, and This Mac. |
| Second subsection header | Hidden unless playing | Unchanged. Shown and Hidden differ in the first word, so the two headers tell apart at a glance. |
| Caption, hidden speaker in use | Shown while playing | The other half of the header above it, with the same verb. Only the playing row carries it, so it reads as happening now. |
| Same caption, VoiceOver suffix | , shown in the Mixer while playing | Spoken sentences keep "the", as every sentence in the app that names the Mixer does. |
| Right-click, shown speaker | Hide from Mixer | Unchanged. Sets Hide when not in use. |
| Right-click, hidden speaker | Show in Mixer | Unchanged. Sets When available. |
| Right-click, checkmark item | Show even when unavailable | Same verb as the other two. Ticked is Always, unticked is When available. "even" stops it reading as "show only when unavailable". |
| Right-click, several selected | Hide N speakers from Mixer / Show N speakers in Mixer | Unchanged. |
| Overview, first counts row label | Available | Pairs with the setting value When available and with Unavailable below it. |
| Overview, kind labels | AirPlay, Bluetooth, Cast, This Mac | Unchanged. Unknown leaves this row: a speaker with no known kind has never been seen this launch, so it is never available and counts under Unavailable. |
| Overview, second counts row | Unavailable | The Mixer row's status, the scene cards' "2 unavailable" and the Always setting ("Keep in Mixer when unavailable") already use this word for both groups the owner means: speakers seen earlier but out of reach now, and speakers not seen at all this launch. The sidebar's spoken dot state says "unavailable" for the first and "can't be found" for the second, the same split the Forget row below keeps. |
| Unavailable, tooltip | Speakers your Mac can't reach right now. | Covers both groups without claiming when each was last seen. |
| VoiceOver, a count still loading | AirPlay, still looking | "Looking" is the app's verb for the search ("Looking for speakers…"). Same pattern for Bluetooth, Cast and Unavailable. |
| VoiceOver, a count arrived | 4 AirPlay speakers available / 1 Cast speaker available | Replaces "4 AirPlay". The screen leans on the row label; a spoken tile can't. |
| VoiceOver, This Mac | This Mac, available | Known at once, so it never reads as still looking. |
| VoiceOver, Unavailable arrived | 8 speakers unavailable / 1 speaker unavailable | |
| VoiceOver, zero (only if a zero tile stays on screen) | No Cast speakers available | |
| Row, Bluetooth access | Bluetooth access is off | Unchanged, with its button and tooltip. |
| Row, lost speakers | N speakers can't be found / 1 speaker can't be found, button Forget N speakers… | Unchanged. The speaker page's caption and the sidebar's spoken state use the same words for the same speakers. |
| Row, pair | Pair Bluetooth speaker… | Unchanged, tooltip "Opens Bluetooth settings to pair a new speaker." |

The labels assume one counting rule. Available counts reachable speakers by kind, plus This Mac. Unavailable counts every other speaker the sidebar lists. The two rows then add up to the sidebar's row count, which is the "8 found, 8 away" complaint fixed. The can't-be-found row is part of the Unavailable number, not extra to it.

No announcement per number. Five announcements inside ten seconds would talk over whatever the user is doing, so the labels update in place. If the design keeps a moment when the last number lands, its one announcement is "Finished looking for speakers."

These go with the done-looking caption, which the owner dropped: "Looking for speakers on your network…", "N found so far", "All N speakers found", "1 speaker found", "Done looking", "N found", "N away". If the page keeps its caption slot, show the popover's "Looking for speakers…" while searching and nothing after.

## Why not "External speakers"

- This Mac sits first in the group under it, and its row carries Core Audio's name for the Mac's current output, such as "MacBook Pro Speakers". Those are built into the Mac.
- macOS uses "external" for the opposite thing. A wired output plugged into the Mac shows in Sound settings as "External Headphones", and when that is the Mac's output the This Mac row takes that name, under a header meant for network and Bluetooth speakers.
- No shipped string says "external", so nothing in the app sets the word up.

## Alternates (pick first)

1. Top section
   - **System Audio / Main Audio** (pick).
   - The Main Audio plate alone, no header. Fewest words, but the owner asked for a title.
   - "Sound from your Mac" over Main Audio. Plainer for a first-time user, but it drifts from the popover's System Audio card.
2. Second section
   - **Speakers / Overview** (pick).
   - Speakers / All speakers. Says the numbers cover everything, but an "All …" row in Apple's sidebars (All Inboxes, All Photos) opens a list, and this page has none.
   - Your speakers / Speakers, plate unchanged. Fewest changes, but the sidebar lists every speaker the Mac sees on the Wi-Fi network, a neighbour's included, so "your" claims too much.
3. Subsections, caption, menu
   - Header 1: **Shown in Mixer** (pick). "Shown in the Mixer" is the owner's phrasing, but the setting's name and all five menu items that name the Mixer drop "the"; sentences keep it, and so do the header and caption being replaced. "In the Mixer" is shipped, and names a state rather than the setting.
   - Header 2: **Hidden unless playing** (pick, shipped). "Hidden from Mixer" matches the menu item but loses when the speaker comes back. "Shown only while playing" matches the setting caption, but two headers starting with Shown blur together.
   - Caption: **Shown while playing** (pick). "In the Mixer while it plays" is shipped and mixes "In the" with the Show/Hide verbs. "Shown in Mixer now" states the moment but not when it ends.
   - Checkmark item: **Show even when unavailable** (pick). "Keep in Mixer when unavailable" is shipped and clear, but it is the one verb outside Show and Hide. "Always show in Mixer" matches the value Always, but unticked it doesn't say when the speaker does show.
4. Overview
   - Second row: **Unavailable** (pick). "Can't be found" already means only the not-seen-this-launch part and has its own Forget row. "Out of reach" is plain, but a new phrase for a state the app already names.
   - First row label: **Available** (pick). No label saves space, but then "4 AirPlay" reads as a total again, which is the misreading the owner hit. "Ready" is the Mixer's word for an idle network speaker, but a connected Bluetooth speaker reads "Connected", not Ready.
   - VoiceOver while loading: **AirPlay, still looking** (pick). "AirPlay, counting" and "AirPlay, loading" both work, but neither is a word the app already uses for the search.

## Strings elsewhere that change to stay consistent

| File:line | Now | Becomes |
|---|---|---|
| `AudioutWindowUI/SidebarViewController.swift:94` | In the Mixer | Shown in Mixer |
| `AudioutWindowUI/SidebarViewController.swift:98` | In the Mixer while it plays | Shown while playing |
| `AudioutWindowUI/SidebarViewController.swift:380`, `:407` | Keep in Mixer when unavailable | Show even when unavailable |
| `AudioutWindowUI/SidebarViewController.swift:634`, `:1175` | Speakers (plate) | Overview |
| `AudioutWindowUI/SidebarViewController.swift:1178` | Speakers, manage speakers | Speakers overview |
| `AudioutWindowUI/SidebarViewController.swift:1319` | , in the Mixer while it plays | , shown in the Mixer while playing |
| `AudioutWindowUI/SpeakersPageViewController.swift:285-297` | the search caption | removed |
| `AudioutWindowUI/SpeakersPageViewController.swift:337` | Unknown | counted under Unavailable |
| `AudioutWindowUI/SpeakersPageViewController.swift:367` | "4 AirPlay" | the VoiceOver rows above |
| `AudioutWindowUI/DeviceDetailViewController.swift:698` | Listed while it's on the network. | Shown while your Mac can reach it. ("on the network" is wrong for a Bluetooth speaker.) |
| `AudioutWindowUI/DeviceDetailViewController.swift:699` | Listed even while it's unavailable. | Shown even when your Mac can't reach it. |
| `AudioutWindowUI/DeviceDetailViewController.swift:700` | Listed only while it plays. | Shown only while it plays. |
| `window-harness/main.swift:98-99` | expects "In the Mixer" and the plate "Speakers" | the new headers and plate |
| `DESIGN.md:497-513` (worktree root) | the Speakers page with its search caption and "away" | the new page |
| `DESIGN.md:670-682` | In the Mixer, its caption, Keep in Mixer when unavailable | the new strings |
| `AudioutWindowUI/AGENTS.md:29` | Speakers landing: search result, kinds, … | drop "search result" |

Tests asserting the old strings: `MixerWindowControllerTests`, `ControlPanelWindowControllerTests`, `GroupsHeaderParityTests`, `DeviceDetailViewTests`, `SidebarActionsTests`, `SpeakersPageTests`, `BTRowsUITests`, `AppSurfaceControllerTests`.

Optional, owner's call: `AudioutCore/SpeakerLibraryStore.swift:14` "Hide when not in use" could become "Only while playing", so every value finishes the sentence "Show in Mixer: …" and matches the sidebar's "playing". It is shared with the popover's speaker menu (`AudioutPopoverUI/PopoverController.swift:3327`). Nothing breaks if it stays.

## Flags

- `DESIGN.md:699-705` was stale before this change. It describes a Speakers page subtitle counting speakers in the Mixer and hidden, plus a discovery-result row; the shipped page and `DESIGN.md:497-513` replaced both. Delete it when the page section is rewritten.
- These strings assume the brief's reading (b) for the sidebar dot: filled means available, rim means unavailable. That reading gives the dots and the overview's Available and Unavailable rows one pair of words. Under reading (a), a reachable AirPlay speaker that isn't playing would wear the same rim as a missing one, while the overview counts it as Available.
- On a Mac where Bluetooth access is unsupported, the Bluetooth row's title says "Bluetooth access is off" and its tooltip says access is unavailable on this Mac (`AudioutCore/SpeakerLibraryController.swift:81`). Outside this brief.
