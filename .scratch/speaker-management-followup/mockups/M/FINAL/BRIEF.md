# Speakers tab: final build spec

This file is the whole spec. It merges, later wins: `../BRIEF.md` (M), `../dot-discovery/direction-c/BRIEF.md` (the chosen sidebar), `../passes/HARDEN.md`, `../passes/CLARIFY.md`, `../passes/DESIGN-PASSES.md` with its four passes, `../copy/COPY.md`, the rulings in `../OWNER-BRIEF.md`, and the owner's answers of 2026-10-04. Those files keep the reasoning; a builder needs only this one.

Code: `claude/speakers-nav` at b9b70310. Every cited line was checked against that commit on 2026-10-04. Another session has uncommitted edits in that worktree that already move some lines (the Forget code in `MixerWindowController.swift` sits about 26 lines lower), so re-anchor by symbol name when building. Paths are under `AudioutCore/Sources/` unless they start at the worktree root. Names in `code font` that don't exist yet are proposed code names.

Mockups: `mockup.html` (`mockup.png`, `mockup-dark.png`) draws the tab with the owner's 20 speakers, six overview states, selected rows on both highlights, and Forget from the keyboard and the menu. `pages-greys.html` (`pages-greys.png`, `pages-greys-dark.png`) draws the one open colour question.

## Owner answers applied (2026-10-04)

- Second subsection "Hidden unless in use"; a hidden speaker's caption "Shown while in use".
- Reduce Motion only: the overview header reads "Looking for speakers…" while counts are unknown; each unknown count shows an en dash in `labelCool2`.
- Command-Delete in the sidebar forgets the selected speakers that can't be found, through the sheet that names them.
- Speaker pages and the Main Audio page in cool greys: open until he has seen `pages-greys.png`.
- Defaults taken: divider wording "8 unavailable"; no mark on reachable rows; moves wait while the pointer is over the sidebar, with no time limit; middle-truncated names; no state line on Main Audio; 10 s before Forget appears; Unavailable is the fifth count; the speaker page's red "Can't be found" glyph becomes `questionmark.circle`.

## 1. Sidebar (`AudioutWindowUI/SidebarViewController.swift`)

### 1.1 Tree, heights, positions

R is `outlineView.rowHeight`, 32 pt on macOS 27 (the code reads it, never a literal, `:1148`). The source list adds 13 pt above every group row, outside the row. x is from the sidebar's leading edge; the sidebar is 210 pt (`SurfaceLayout.swift:17`).

| # | Node | Kind | Height | Positions |
|---|---|---|---|---|
| 1 | "System Audio" | group row | 19 | text x 14, its bottom 3 pt above the row's bottom |
| 2 | Main Audio | child of 1, plate | R + 8 | plate x 10-200, full row height; icon x 16-38; label x 46; chevron ends x 192 |
| 3 | "Speakers" | group row | 31 (19 + 12) | as 1; the extra 12 pt sits above the text |
| 4 | Overview | child of 3, plate | R + 8 | as 2, icon `hifispeaker.2` |
| 5 | "Shown in Mixer" | group row, never folds | 19 | as 1 |
| 6 | Reachable speakers | children of 5 | R | icon x 16-38 (centre 27); name x 46-186 |
| 7 | Divider "N unavailable" | child of 5, only when 5 holds an unreachable speaker | 24 | §1.3 |
| 8 | Unreachable speakers | children of 5 | R | as 6, cool inks (§1.5) |
| 9 | "Hidden unless in use" | group row, only when it has rows, folds through the stock Show/Hide | 19 | as 1 |
| 10 | Its speakers, divider, unreachable speakers | children of 9 | R; a hidden speaker in use R + 12 | as 6-8 |
| | Add scene bar | below the outline | R | §1.10 |

Gaps that result: 28 pt from a plate to a section title's text, 16 pt from the row above to a subsection header's text, 8 pt from the last reachable row to the divider label, 3 pt from any heading's text to the first row it heads.

Build:
- `heightOfRowByItem` (`:1142-1151`) returns the heights above. Header text is pinned to the cell's bottom − 3 instead of centred (`:1262`); in a 19 pt row that equals centring.
- M's 16 pt spacer row is not built. No blank node exists for arrow keys or VoiceOver to stop on.
- "Speakers" holds the Overview plate as its child, the way "System Audio" holds Main Audio (`:529`). The two subsection headers stay top-level.
- `PlateRowView.rowHeight` (`:917`, 36) becomes R + 8.
- At `.medium` the table replaces the font of a cell's `textField` outlet (measured offscreen: group rows become 11 pt regular, other rows 13 pt regular). Header labels, plate labels and the divider label are therefore labels the cell owns but not its `textField`. Speaker names stay in the outlet: they want the 13 pt source-list font, and the expansion tooltip reads the outlet. If the live sidebar already renders its headers semibold today, this bullet drops.
- R = 32 was measured offscreen on macOS 27; the 2026-08-12 window snapshot drew 28. Confirm on the live sidebar first. Every height is written against R, so the table holds either way.

### 1.2 Order inside each group

- Reachable speakers first: This Mac first, then by display name (`localizedStandardCompare`, then id, as `:516-523` sorts today).
- Then the divider row, then the unreachable speakers in the same order.
- Reachable means `isLocalDevice || isAvailable` (`AudioutCore/SpeakerLibraryController.swift:101`, `:105`), the overview's own rule (§2.4). The rows above the dividers therefore equal Available, and the dividers add up to Unavailable.
- The groups stay the Show in Mixer setting. Reachability never moves a speaker from one group to the other.

### 1.3 The divider row

- 24 pt, a child of its group, not a group item. `Node.Payload` gains a divider case carrying its count.
- Glyph: SF Symbol `antenna.radiowaves.left.and.right.slash`, 11 pt regular, `labelCool`, in a 22 pt box centred on x 27, sitting on the label's first baseline.
- Label: "8 unavailable" / "1 unavailable", `Tokens.Font.captionDigits` (new, §5.1), `labelCool`, at x 46, its box 3 pt above the row's bottom.
- Rule: 1 pt `Tokens.Color.separator` (`Tokens.swift:151`) from 8 pt after the label to x 192, centred 3 pt above the label's baseline (the middle of the 11 pt x-height).
- Never selectable: `shouldSelectItem` returns false for it by name (today it returns `!isGroupItem`, `:1134-1137`, and the divider is not a group item). No menu; `selection(for:)` (`:559`) returns nil for it.
- A drop on it goes to its group's header (`validateDrop`/`acceptDrop`, `:1091-1105`).
- VoiceOver: one element, "8 unavailable speakers" / "1 unavailable speaker", set on every reuse. Glyph and rule `setAccessibilityElement(false)`.

### 1.4 When rows move

1. **Launch.** Until all four overview counts are known (§2.5; 10 s at most) each group is one list in name order with no divider. A speaker not seen yet draws in the unreachable inks; one that answers brightens in place. When the counts are known, the unreachable rows move under the new dividers in one update. A window opened later never sees this move.
2. **After that,** a speaker's inks change at once and its row follows with `moveItem(at:inParent:to:inParent:)` inside `beginUpdates`/`endUpdates` (the stock move, about 0.25 s). The divider's count changes in the same update, and the divider is inserted or removed with it.
3. **Nothing moves under the user.** Moves wait while the pointer is over the sidebar (a tracking area on its scroll view), a menu from it is open (menu-tracking notifications), or a drag is running, and apply together when that ends. No time limit. Nothing waits on keyboard focus or VoiceOver.
4. **No extra delay** for speakers that blink off: AirPlay and Cast removals already wait 3 s before they reach the list (`AudioutCore/NativeDiscovery.swift:283`, `AudioutCore/NativeBackend.swift:1132`).
5. **Reduce Motion:** the same updates with no animation (`NSAnimationContext` duration 0; `[]` as the animation for inserts and removes).
6. **Rows keep their identity.** One `Node` per device id across every update, changed only through moves, inserts and removes, from the first build on. Changed inks and labels go to the visible cell (`view(atColumn:row:makeIfNecessary: false)`), never through `reloadItem` or `reloadData`. Today `reload` rebuilds every node and calls `reloadData` (`:528-538`), then restores only the first selected row (`:546`), which collapses a multiple selection whenever any speaker changes. A selected row that moves stays selected; the list does not scroll to follow it.
7. **Forget** removes rows with the stock remove animation. The divider's count drops, and the divider goes when its part is empty.
8. Drop `isPlaying` from `SidebarProjection` (`AudioutWindowUI/MixerWindowController.swift:782`, `:798`). Nothing draws it any more, and it triggers an update on every connect and disconnect.

Accepted, recorded: colour is the only visible cue for up to 10 s before the first split and while a move waits for the pointer. The spoken suffix is right throughout.

### 1.5 Fonts and inks

| Element | Font | Ink, unselected |
|---|---|---|
| Section title "System Audio", "Speakers" | `captionEmphasized` (`Tokens.swift:1302`) | `labelCool` (was `label2`, `:1251`) |
| Subsection "Shown in Mixer", "Hidden unless in use" | `captionMedium` (`Tokens.swift:1296`), in its own reuse pool so a reused cell never carries the other level's font | `labelCool` |
| Plate label "Main Audio", "Overview" | `bodyEmphasized` (`Tokens.swift:1260`) | `label`; icon `label`; `chevron.right` 10 pt semibold in `labelCool2` (was `label3`, `:838`) |
| Reachable speaker | source-list font, 13 pt regular; icon a 13 pt medium SF Symbol | name and icon `label` |
| Unreachable speaker | same | name `labelCool` (was `label3`, `:1300`); icon `labelCool2` (was `label3`, `:1298`) |
| Caption "Shown while in use" | `caption` | `labelCool` (was `label3`, `:850`) |
| Divider | §1.3 | glyph and label `labelCool`; rule `separator` |

- After this change the sidebar holds no `label2`, `label3`, `ember`, `gold`, `failure` or green. Leaving with the dot: `SidebarPresenceDotView` and all its states (`:952` onward), `dotState(for:)` (`:466-471`), and the gold `IconLabelCellView.activeMarkerView` (`:815-828`) that no row shows.
- `labelCool2` is never sidebar text: 4.06:1 on the darkest dark ground.
- Speaker names truncate in the middle: `lineBreakMode = .byTruncatingMiddle` on the name field only (`:1343`), and `outlineView.allowsExpansionToolTips = true` (set nowhere today) so a cut name shows whole on hover. Headers, the caption and plates keep tail truncation. At the 140 pt name width: "Move 2 (S…Bedroom)", "Sonos Mo…S Kitchen)", "MacBook Pro Speakers" whole. At 123 pt (the list scrolls and scroll bars are set to always show): "Move 2 (…Bedroom)", "Sonos M…Kitchen)", "MacBook…Speakers".

### 1.6 Selected rows

- List focused (accent pill; the cell's `backgroundStyle` is `.emphasized`): every ink in the cell (name, icon, caption, chevron) is `NSColor.alternateSelectedControlTextColor`.
- List not focused (grey pill): every ink is `Tokens.Color.label`.
- Fonts never change with selection. A selected unreachable row still sits under the divider and still speaks ", unavailable".
- Mechanism: speaker rows and the Main Audio plate get a row view that re-inks its cell when `isSelected` or `isEmphasized` changes, the pattern `PlateRowView` uses (`:945`); today only the Overview plate has a custom row view (`:1157-1166`). The grey pill leaves the cell's `backgroundStyle` at `.normal`, so the cell alone cannot tell. Check on macOS 14 with `scripts/run-on-vm.sh`.
- The same re-ink runs over the visible rows on `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`, so Increase Contrast reaches the names and icons. Today only the dot listened (`:965`).

### 1.7 Plates

- `PlateRowView` (`:906-946`): radius `Tokens.Layout.Radius.control` (10), 1 pt `containerEdge` edge, as today.
- Fill, light: `raised`, as today. Fill, dark: `Tokens.Color.label` at 5 % (new `PlateRowView.darkLiftAlpha = 0.05`), a translucent lift. `raised` dark `#1F232A` is darker than the measured dark sidebar ground `#282828`, so today's plate reads as sunk. The lift measures 1.13:1 over `#282828` (the light plate is 1.09:1 over `#F0F0F0`), and because it is translucent it stays lighter than every dark ground in the macOS 14.4-26 range.
- Selected: the source list's pill alone, as today (`:895-905`).
- Main Audio moves onto the plate path that `rowViewForItem` and `heightOfRowByItem` give `.speakersOverview` (`:1139-1166`); its cell pool passes `emphasized: true` (`:1281-1285`; rewrite that comment, which says Overview is the only pool that asks).

### 1.8 Words, spoken labels, tooltips

| Row | Shown | VoiceOver |
|---|---|---|
| Section title | System Audio | "System Audio", heading |
| Plate | Main Audio | "Main Audio" |
| Section title (new) | Speakers | "Speakers", heading |
| Plate | Overview | "Speakers overview" |
| Subsection | Shown in Mixer | "Speakers shown in Mixer", heading |
| Subsection | Hidden unless in use | "Speakers hidden unless in use", heading |
| Hidden speaker in use | name, then caption "Shown while in use" | name + ", shown in the Mixer while in use"; the caption itself `setAccessibilityElement(false)` (today it is read twice) |
| Divider | 8 unavailable | "8 unavailable speakers" |
| Reachable speaker | name | name |
| Unreachable network speaker, or no saved kind | name | name + ", unavailable" |
| Bluetooth speaker not connected (listed, or unlisted because Bluetooth access is off) | name | name + ", not connected" |
| Speaker in the can't-be-found set (§2.6) | name | name + ", can't be found" |

- Every unreachable row has a tooltip: line 1 the full name; line 2 "Unavailable", "Not connected" or "Can't be found"; a speaker with no saved details adds its id as line 3 (today's whole tooltip, `:1191`). Reachable rows have only the expansion tooltip for a cut name.
- All four titles get the heading role with the Mixer's call, `setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))` (`markAsAccessibilityHeading`, `AudioutPopoverUI/PopoverPanelViewController.swift:1379-1381`), with no version gate. Their spoken labels are set on every reuse.
- The ", playing" suffix goes (`:1316`).

### 1.9 Right-click menu and Command-Delete

Menu, one shown speaker (`:367-392`): Hide from Mixer · **Show even when unavailable** (ticked = Always; was "Keep in Mixer when unavailable", `:380`) · separator · Speaker settings… · then, only for a speaker in the can't-be-found set, separator · **Forget "Name"…** with ⌘⌫ shown.
Hidden speaker: Show in Mixer, unchanged.
Several selected (`:395-418`): Hide N speakers from Mixer / Show N speakers in Mixer · Show even when unavailable (`:407`) · separator · **Forget N speakers…** with ⌘⌫, N = the selected speakers in the set.

- While the set is empty (the first 10 s, §2.6) no Forget item and no separator for it appear.
- The ⌘⌫ on the item is display only (`keyEquivalent "\u{8}"`, `.command`). A context menu's key equivalents do not fire while it is closed; the sidebar handles the key.

Command-Delete, with the sidebar focused in the key window:
- Forgets the selected speakers that are in the set, through `onForget` (`:88`) → `requestForget` (`MixerWindowController.swift:224`, `:530`) → the sheet in §4.
- Selected speakers outside the set are skipped; the sheet names only the ones it forgets. None in the set, or the set not filled yet: `NSSound.beep()` and nothing else.
- Build: the repo handles Delete as a responder action, not a key code (`AudioutSharedUI/AppRowView.swift:912-933`). Under the standard key bindings Command-Delete arrives as `deleteToBeginningOfLine:`; implement that on the sidebar controller and prove with a test that the key reaches it from the outline. If it does not, override `keyDown(with:)` in an `NSOutlineView` subclass for key code 51 with exactly `.command`.
- `speaker:forgotten` fires per speaker as it does now (`AudioutCore/SpeakerLibraryController.swift:273`). No new event.

### 1.10 Add scene bar

- Height R (was 28, `:248`). The same single `NSButton`; its image becomes a 26 × 22 pt template image with `plus` (13 pt medium) centred at the image's x 11, and its leading edge moves to x 16 (was 8, `:250`). Result: the plus centred on x 27, "Add scene" from x 46.5. No hairline above the bar.

### 1.11 Keyboard and announcements

- Arrow keys skip titles, subsection headers and dividers. Both plates stay on the arrow path.
- Shift ranges cross the divider. `outlineView(_:selectionIndexesForProposedSelection:)` drops plate rows from any proposal of more than one row (today Shift-Up from the first speaker adds Overview and switches the page).
- `outlineView(_:typeSelectStringFor:item:)` returns the display name, "Main Audio" or "Overview", and nil for titles, subsection headers and dividers.
- `outlineView(_:shouldCollapseItem:)` returns `isHiddenHeader(item)`, so VoiceOver's disclosure command cannot fold the other headers.
- One low-priority `.announcementRequested` when the only selected row changes reachability while the sidebar has focus in the key window: "Mac Cast Receiver, unavailable" / "Mac Cast Receiver, available"; for Bluetooth "…, not connected" / "…, connected". Nothing else about moves is announced.
- Rows (32) and plates (40) meet the macOS 28 pt target.

## 2. Overview page (`AudioutWindowUI/SpeakersPageViewController.swift`)

### 2.1 Header

- Column on `GroupsPaneLayout`: top inset 28 (`GroupsPaneLayout.swift:42`), x 14, at most 415 wide (`:61`).
- Icon well 48 pt (`DeviceIconWellView.swift:66`) at pane x 52.5 (`columnInset` 14 + `contentLeadingInset` 38.5), y 44. `hifispeaker.2` in `labelCool`, edge `containerEdge`, as the code already draws it (`DeviceIconWellView.swift:154`, `:286`). VoiceOver "Speakers" (`:143-144`).
- Title **Overview** (was "Speakers", `:119`), `heading` (`:146`), `label`, 12 pt after the well, centred on it.
- Caption 2 pt under the title, `captionDigits`, `labelCool` (through `captionField`, `:312-314`, was `label2`): "20 speakers" / "1 speaker" / "No speakers".
- While the total is unknown: a 14 × 8 pt placeholder alone on the line (radius 2.5), then "20 speakers" fades in as one string. Under Reduce Motion the line reads "Looking for speakers…" in `caption` / `labelCool` instead.
- The caption's VoiceOver value: the total; while unknown, "Looking for speakers".
- Removed (`:285-297`): the spinner, "Looking for speakers on your network…", "N found so far", the green check (`.systemGreen`, `:289`), "All N speakers found", "Done looking", the caption dots, "N found", "N away".

### 2.2 Card

- `GroupedSectionView` `.card`: `raised` fill, 1 pt `containerEdge` edge and row dividers, radius `Radius.panel` 26 (`Tokens.swift:1445`). Pane x 14-429, top 36 pt under the icon well (`:208`).
- Rows, in this order, each only when stated: the counts strip (always); can't be found (the set is not empty); Local Network access is off (access known denied); Bluetooth access is off (as today, `:240-245`); Pair Bluetooth speaker… (always).

### 2.3 Counts strip

Replaces the single `.fillEqually` stack (`:331-381`):

```
strip            horizontal, .fill, alignment .lastBaseline, spacing 0
                 insets 18 leading, 10 trailing, 12 top, 11 bottom: 387 pt wide
├ availableGroup vertical, .leading, spacing 4
│ ├ "Available" + its rule
│ └ kindTiles    horizontal, .fillEqually: AirPlay · Bluetooth · Cast · This Mac (77.4 pt each in English, at least 62)
└ unavailable    tile, at least 77.4 pt, high hugging; content inset 13 (1 pt rule + 12)
                 rule: 1 pt containerEdge on its leading edge, strip top + 2 to strip bottom − 2
```

- "Available": `captionEmphasized`, `labelCool`. Its rule: 1 pt `containerEdge` from 8 pt after the caption to the kind tiles' trailing edge − 12, centred 3 pt above the caption's baseline, minimum width 0. (`hairline` is not allowed on `raised`.)
- Tile: 16 pt glyph in `labelCool2` (`ListRowView.glyph(_:tint:)`, `ListRowView.swift:45`, tint passed at the call site), 6 pt, count in `headingDigits` (new, §5.1) in `label`, or `labelCool2` for 0. Label 1 pt under in `caption` / `labelCool`. Each count's first baseline is pinned to AirPlay's count and each label's to AirPlay's label (15 pt apart).
- Glyphs: `airplayaudio`, `radio`, `tv.and.hifispeaker`, `laptopcomputer`, `antenna.radiowaves.left.and.right.slash`.
- English, card coordinates: caption x 18-67, its rule x 75-315.6, vertical rule x 327.6, Unavailable glyph x 340.6. Nothing truncates in English.
- Long translations: the Unavailable tile is 13 + the wider of its label and its glyph-and-count, at least 77.4; the kind tiles share the rest, at least 62 each; the caption rule follows the kind tiles. Past 126 pt the Unavailable label truncates at the tail. No wrapping. German: Unavailable 95.2, kind tiles 72.95, caption rule ends at x 297.8.
- Both rules `setAccessibilityElement(false)`.

### 2.4 Counting rule

| Record in `library.records` | Counts as |
|---|---|
| `isLocalDevice` (`SpeakerLibraryController.swift:101`) | This Mac |
| otherwise `isAvailable` (`:105`) and kind `homePod`, `appleTV`, `airportExpress`, `sonos` or `generic` | AirPlay |
| otherwise `isAvailable` and kind `bluetooth` (connected to this Mac) | Bluetooth |
| otherwise `isAvailable` and kind `cast` | Cast |
| everything else, kind `nil` included | Unavailable |

- Total = `records.count`, every speaker row in the sidebar. Unavailable = the sidebar's dividers added together.
- The Unknown tile goes (`:337`).
- The five numbers live in a new struct beside `SpeakerLibraryCounts`, which keeps its fields for the analytics event (§6).

### 2.5 When each number is known

`SpeakerSearch` (`:43-92`) gains `startedAt`, one `DiscoverySettleTracker` per kind, and `knownKinds`, and calls the host back when `knownKinds` grows.

- `startedAt` is the earlier of the first `libraryDidChange()` whose live-id set is not empty (where it arms its ceiling today, `:79-82`) and the first time the page appears (new `pageDidAppear()`, called from `viewDidAppear`).
- Each tracker starts at `startedAt` and is fed, on every `libraryDidChange()`, the ids of that kind's records with a live device:

| Tile | Fed | Quiet window | Known when |
|---|---|---|---|
| This Mac | nothing | none | a local record with a live device exists |
| Bluetooth | kind `bluetooth` | 0.5 s (`SpeakerSearch.quietWindow`, `:48`) | its tracker settles |
| AirPlay | the five AirPlay kinds | 2.0 s (new `networkQuietWindow`) | its tracker settles |
| Cast | kind `cast` | 2.0 s | its tracker settles |

- At `startedAt` + 10 s (`SpeakerSearch.ceiling`, `:51`) every kind not yet known becomes known with its current count.
- Unavailable, the header total and the end-of-search announcement wait until all four kinds are known. The sidebar's first split (§1.4) happens at the same moment.
- After that every number changes in place with the 180 ms fade for the rest of the launch. No placeholder returns, and a page first opened later never shows one.
- Why 2.0 s for network speakers: an AirPlay speaker appears only after the Mac's test connection opens (`AudioutCore/NativeDiscovery.swift:984-995`), and Bonjour waits at least 1 s before asking again (RFC 6762 §5.2), so a late answer arrives a second or more after the rest. With 0.5 s armed on first arrival, "0 AirPlay · 15 Unavailable" could look final.
- Illustrative times for the owner's fleet: This Mac at 0 s; Bluetooth 0 at 0.6 s; Cast 3 at 2.9 s; AirPlay 4, Unavailable 12 and "20 speakers" at 3.1 s; "6 speakers can't be found" at 10 s.

### 2.6 The can't-be-found set

`lostIDs`, computed by the host and pushed on every change the way `setBluetoothAccess` is (`:222-225`): records with `!isLocalDevice && liveDevice == nil`, **empty until `startedAt` + 10 s**, then leaving out
- Bluetooth records while Bluetooth access is not `.granted`;
- records whose kind is `nil` or `isDiscoveredOverLocalNetwork` (`AudioutCore/Device.swift:48-55`) while Local Network access is known denied, or while no AirPlay or Cast record has had a live device this launch (Wi-Fi off, or a network that hides devices from each other, looks exactly like every speaker gone).

All three doors read it:
- the overview's row (replaces `:247-248`);
- the sidebar's `isLost` (`:457-459`): the spoken ", can't be found", the tooltip, the menu's Forget, Command-Delete;
- the speaker page's `isLost` (`DeviceDetailViewController.swift:594-596`): its caption, glyph and Forget button (`:612`, `:646-654`).

- `requestForget` (`MixerWindowController.swift:530`) intersects the ids it is handed with the current set before building the sheet; if nothing is left, no sheet. `forget` already re-filters at confirm (`SpeakerLibraryController.swift:253-273`).
- Before the set fills, a remembered speaker not seen yet shows its ordinary status: sidebar ", unavailable" (Bluetooth ", not connected"); its page "Sonos · Unavailable", "Bluetooth Speaker · Not connected" or "Missing speaker"; no Forget anywhere.
- A seen speaker that goes away keeps its live device (`AudioutCore/OutputBackend.swift:28-30`), counts as Unavailable, and is never "can't be found" this launch.

### 2.7 Rows

| Row | Glyph, `labelCool2` | Title, `body` / `label` | Accessory | Tooltip and VoiceOver hint |
|---|---|---|---|---|
| Can't be found | `questionmark.circle` (was red `exclamationmark.triangle`, `:260`) | 6 speakers can't be found / 1 speaker can't be found | Forget 6 speakers… / Forget 1 speaker… | "6 of the 12 unavailable speakers haven't appeared since Audiout opened." then the shipped scene sentence (`:252-257`) |
| Local Network (new) | `wifi` | Local Network access is off | Open Privacy Settings… | Allow Local Network access in System Settings to see AirPlay and Cast speakers. |
| Bluetooth | `Device.Kind.bluetooth.symbolName`, unchanged | Bluetooth access is off | unchanged: Open Privacy Settings… / Allow Bluetooth… / none (`SpeakerLibraryController.swift:70-89`) | unchanged |
| Pair | `plus.circle` | Pair Bluetooth speaker… | `chevron.right` in `labelCool2` (was `label2`, `:416`) | Opens Bluetooth settings to pair a new speaker. |

- Local Network row: shown only when `permissionAuditModel?.localNetworkStatus == .denied`, the read the popover's AirPlay section uses (`AudioutApp/AppDelegate.swift:1385-1391`). Never on `.unknown` or `.requested`; never on macOS 14, where the model reports granted. The host pushes it (a new setter beside `setBluetoothAccess`) when the page is built and after each permission audit (`AppDelegate.swift:2050-2053`), so returning from System Settings clears it. The button opens `SystemSettingsPane.localNetwork.url` (`AudioutCore/SetupModel.swift:126`, `:149-150`). Not `Tokens.Color.permissionLocalNetwork`: the permission hues stay in onboarding. Width 404.6 pt of 415.
- The Forget button keeps its view and is retitled in place.

### 2.8 States

| State | Header caption | AirPlay · Bluetooth · Cast · This Mac · Unavailable | Rows |
|---|---|---|---|
| Mid-search, 1.5 s (mockup panel 1) | placeholder | placeholder · 0 · placeholder · 1 · placeholder | Pair |
| Same moment, Reduce Motion (panel 2) | Looking for speakers… | – · 0 · – · 1 · – | Pair |
| Every speaker reachable (panel 3) | 12 speakers | 7 · 2 · 2 · 1 · 0 | Pair |
| Some unavailable (panel 4) | 9 speakers | 3 · 1 · 0 · 1 · 4 | 1 speaker can't be found [Forget 1 speaker…], Pair |
| Bluetooth access off (panel 5) | 14 speakers | 6 · 1 · 2 · 1 · 4 | 2 speakers can't be found [Forget 2 speakers…], Bluetooth access is off [Open Privacy Settings…], Pair |
| Local Network access off (panel 6) | 6 speakers | 0 · 1 · 0 · 1 · 4 | Local Network access is off [Open Privacy Settings…], Pair |
| The owner's fleet, finished (window) | 20 speakers | 4 · 0 · 3 · 1 · 12 | 6 speakers can't be found [Forget 6 speakers…], Pair |
| No speakers at all | No speakers | 0 · 0 · 0 · 0 · 0, settled 10 s after the page appears | access rows if true, Pair |
| After Forget | total and Unavailable drop | | the row goes when the set is empty |

- Bluetooth access off: paired speakers macOS won't list without access count as Unavailable, speak "not connected", and stay out of Forget. The 2 that can't be found are network speakers.
- Local Network access off: AirPlay and Cast settle to 0, which is what the Mac sees; no Forget row, because the Mac can't look for network speakers.
- The owner's fleet: six paired Bluetooth speakers are switched off but listed by macOS (Unavailable, not in the set); five AirPlay speakers and one with no saved kind have not appeared (the six Forget offers).
- 0 speakers happens only before the backend adds This Mac (`AudioutCore/NativeBackend.swift:2066`) or if Core Audio never reports the Mac's output. This Mac at 0 speaks "This Mac, unavailable". The sidebar then shows System Audio, Main Audio, Speakers, Overview and an empty "Shown in Mixer" header, which stays as a drop target (`:531`).
- Around 60 speakers: "41 speakers can't be found" (163.3 pt) and Forget 41 speakers… (150.0 pt) fit in 415. A long title truncates and the button keeps its size (`ListRowView.swift:60-62`, `:104`).

### 2.9 Placeholders and motion

- Count placeholder: 20 × 12 pt, radius 3, `Tokens.Color.meter` (`Tokens.swift:327`), starting where the first digit starts (6 pt after the glyph), centred on the count's line. The count field stays in the tile as an invisible "00" (`alphaValue` 0) under it, so the line height never changes when the number lands.
- Header placeholder: 14 × 8 pt, radius 2.5, alone on its line.
- Moving highlight, one per page: a 44 pt horizontal gradient, clear → highlight → clear; highlight = `meter.blended(withFraction: 0.70, of: .white)` in light, `0.30` in dark. It travels in pane coordinates from −44 to 443 in 1.1 s with `cubic-bezier(0.45, 0, 0.55, 1)`, then rests 0.5 s: a 1.6 s period. Each placeholder clips a `CAGradientLayer` animating `position.x` from `−44 − x` to `443 − x` (x = the placeholder's offset in the pane), key times [0, 0.6875, 1], all on one `beginTime` taken when the first placeholder appears. One light crosses the header, then the strip, left to right.
- Arrival: placeholder and number crossfade in 180 ms, `cubic-bezier(0.16, 1, 0.3, 1)`. Nothing moves and the number does not count up. That placeholder's animation is removed and `.valueChanged` is posted on its tile.
- Paused while the page is off screen; removed for good when the last placeholder fills. At most six placeholders share the one highlight, whatever the fleet size.
- Reduce Motion, read from `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` when placeholders appear and followed live through `redrawOnAccessibilityDisplayChange()` (`AudioutSharedUI/AccessibilityDisplayRedraw.swift:33`): no highlight and no bars. Each unknown count is "–" (en dash) in `headingDigits` / `labelCool2`; the header reads "Looking for speakers…". The 180 ms fade stays, opacity only. (The still `meter` bar measured 1.59-2.30:1, under the 3:1 floor in all four modes.)
- The moving highlight is new custom drawing, so it gets named in `AudioutWindowUI/AGENTS.md` (DESIGN.md Don'ts).

### 2.10 Page accessibility and updates

- **Built once, updated in place.** Header, strip and rows are built once. Updates set text, spoken values and button titles on the existing views; a problem row is inserted or removed only when its condition changes. Today `reload()` removes and rebuilds every row on every backend event (`:228-275`, reached through `MixerWindowController.swift:729-730`), which drops keyboard focus and sends `.valueChanged` to views VoiceOver was never on.
- Strip: one group labelled "Speaker counts". Each tile is `setAccessibilityRole(.staticText)` with no label and its sentence as `accessibilityValue`:
  - known: "4 AirPlay speakers available", "1 Cast speaker available", "No Cast speakers available"; "This Mac, available" (at 0, "This Mac, unavailable"); "12 speakers unavailable", "1 speaker unavailable", "No speakers unavailable";
  - unknown: "AirPlay, still looking"; the same for Bluetooth, Cast and Unavailable.
- Help, as tooltip and VoiceOver hint: AirPlay "AirPlay speakers on your network right now." Bluetooth "Bluetooth speakers connected to this Mac right now." Cast "Cast speakers on your network right now." This Mac "This Mac's own output." Unavailable "Speakers your Mac can't reach right now, and Bluetooth speakers that aren't connected."
- When all four kinds become known, if the window is key and the page is on screen: one low-priority announcement, "Finished looking for speakers." Nothing else is announced.
- No new focusable controls. Forget, the access buttons and Pair are Tab stops when Keyboard navigation is on.

## 3. Speaker page and Main Audio page

In this build:
- A speaker in the set: its caption glyph becomes `questionmark.circle` in `labelCool2` (was `failure`, `DeviceDetailViewController.swift:216`); the text "<Kind> · Can't be found" is unchanged (`:646-654`). `failure` stays for real connection failures.
- `isLost` reads the set (§2.6). Before it fills the page shows the ordinary status and no Forget.
- Show in Mixer captions (`:698-700`): "Shown while your Mac can reach it." / "Shown even when your Mac can't reach it." / "Shown only while it's in use." ("on the network" was wrong for Bluetooth, and "while it plays" was wrong for a selected speaker in silence.)
- Forget "Name"… on the page opens §4's one-speaker sheet.
- Main Audio plate: no state line.

Open (`pages-greys.png`): whether the two pages' warm inks go cool in the same build. If yes, the mapping is: text in `label2` → `labelCool`; quieter text in `label3` → `labelCool2`; glyphs (the scene links' chevrons, `:912`) → `labelCool2`. Both inks pass 4.5:1 on `panel`, `raised` and `well`. The sites:
- `DeviceDetailViewController.swift:211, 258, 265, 268, 294, 912, 931`;
- `MainOutDetailViewController.swift:103, 128`;
- `ListRowView.swift:65`, the caption default, which only the speaker page relies on (the overview sets its inks at its call sites);
- `AudioutSharedUI/EQEditorView.swift:216, 240, 307, 334, 376, 381, 384, 475, 506`. The Equalizer editor sets nine warm inks of its own, which the colour pass did not count. Only these two pages host it (`DeviceDetailViewController.swift:179`, `MainOutDetailViewController.swift:73`), so the change stays inside this tab. Without them the Equalizer card stays warm inside a cool page.
- Stays: the green Equalizer mark (a site the Equalizer-hue fence allows), `label` text, stock controls.

## 4. Forget sheet (`MixerWindowController.swift:552-584`)

- NSAlert sheet, `.warning`, unchanged except the informative text.
- Title: `Forget “Name”?` / `Forget N speakers?` (`:571`).
- Buttons: **Forget** (`hasDestructiveAction`, no key equivalent) and **Cancel** (Return) (`:578-583`).
- Which names: the speakers being forgotten, after the intersection with the set, in sidebar order. A speaker with no saved details ("Missing speaker", `metadataIsKnown == false`) is never named; it only counts toward "more". All named and 3 or fewer: name them all; otherwise the first two named speakers, then "and N more". Curly quotes, joined with ", " and " and ", as the refusal sheet joins scene names (`:564`).
- Informative text, each case one whole sentence so a translation can reorder it:

| Case | Text |
|---|---|
| One, in scenes | It will be removed from 2 scenes. If it turns up again, it comes back to the speaker list, but not to those scenes. |
| One, no scene | It isn’t in any scene. If it turns up again, it comes back to the speaker list. |
| Several, in scenes | “ION Speaker”, “isaac” and 4 more will be removed from 2 scenes. If one turns up again, it comes back to the speaker list, but not to those scenes. |
| Several, no scene | “ION Speaker”, “isaac” and 4 more aren’t in any scene. If one turns up again, it comes back to the speaker list. |
| Several, 3 or fewer, all named | “ION Speaker”, “isaac” and “teevee” will be removed from 1 scene. If one turns up again, … (same ending) |
| Several, none named | They will be removed from 2 scenes. If one turns up again, … (same ending) |

- "1 scene" / "N scenes" as today (`:575-576`).
- The second sentence is what the code does: `forget` removes the speaker from every scene and deletes its saved details and Mixer setting (`SpeakerLibraryController.swift:258-266`); the list is every live device plus every saved one (`:291`), so a forgotten speaker that answers again is listed again, set to When available, in no scene.
- The refusal sheet ("Can’t forget…", `:561-569`) is unchanged.

## 5. Tokens

### 5.1 New fonts (`Tokens.Font`)

- `headingDigits` = `.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize + 3, weight: .semibold)`: the five counts and the Reduce Motion dash. `heading` has proportional digits (`Tokens.swift:1269-1271`), so "1" is 7.59 pt and "4" 10.42 pt wide; tabular, every digit is 10.19.
- `captionDigits` = `.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)`: the divider label and the header total. With it the divider's rule starts at the same x for every one-digit count. (`DeviceRowView.swift:2066-2067` builds the same font privately; leave that site alone.)

### 5.2 Colours (no new colour token)

| Token | Light | Light, Increase Contrast | Dark | Dark, Increase Contrast | Defined |
|---|---|---|---|---|---|
| `label` | system `labelColor` | | | | `Tokens.swift:94` |
| `labelCool` | `#4E5A63` | `#414B53` | `#A9B3BB` | `#C0C8CD` | `:511-513` |
| `labelCool2` | `#5F6A73` | `#464E55` | `#818C94` | `#A6AEB3` | `:527-529` |
| `panel` | `#FAFAFB` | | `#15171A` | | `:211-213` |
| `raised` | `#FAFAFB` | | `#1F232A` | | `:218-220` |
| `containerEdge` | `#AEB3BB` | `#67696E` | `#3D4247` | `#6A6E72` | `:295-298` |
| `meter` | `#C6C9CE` | `#B4B8BF` | `#464C55` | `#545B66` | `:327-330` |
| `separator` | system `separatorColor` | | | | `:151` |
| Sidebar ground (system, measured on macOS 27) | `#F0F0F0` | | `#282828` | | |
| Grey selection pill (system) | `#DCDCDC` | | `#464646` | | |
| Accent selection pill (system, default blue) | `#0064E1` | | `#0059D1` | | |

### 5.3 Contrast, worst case across light, dark and both Increase Contrast modes

- `labelCool` text on the sidebar ground: 5.79:1 (floor 4.5); on `raised`: 6.79.
- `labelCool2` glyphs on the sidebar: 4.06:1 (floor 3), so never sidebar text.
- `labelCool2` zeros and dashes on `raised`: 4.59:1 in dark (floor 4.5), the tightest pass.
- `label` on the grey pill: 7.33:1. White on the accent pill: 4.02-6.27 in dark, AppKit's own selected text.
- Divider rule `separator`: 1.24 light, 1.36 dark; decoration, the label carries the meaning.
- Plates: light `raised` 1.09:1 and dark lift 1.13:1 against the ground; no floor, the edge and the label carry them.
- On macOS 14.4-26 the ground is unmeasured; across the bracket `#E8E8EA`-`#F8F8F8` / `#1E1E20`-`#2C2C2E` every figure above still passes.

## 6. Analytics

- `speaker:library_counted`: unchanged. Same name, same nine properties (`SpeakerLibraryCounts.analyticsProperties`, `SpeakersPageViewController.swift:31-35`), same moment: once per launch from `SpeakerSearch.finish()` (`:86-91`), on the overall 0.5 s settle (`:69-70`, `:83`) or the 10 s ceiling (`:79-82`). The per-kind trackers are separate instances and never call `finish()`. `isDone` and `onDone` keep meaning the analytics moment; the page stops reading them (`AppDelegate.swift:1100`, `:2419` move to the new callbacks). On a slow network it can still fire before AirPlay answers; that is left alone so its history stays comparable.
- `speaker:forgotten`: unchanged, fired per speaker at the one place every Forget reaches (`SpeakerLibraryController.swift:273`): menu, Command-Delete, the overview's button, the speaker page's button.
- New: the Local Network row's button is a new user action, and CLAUDE.md requires one to be instrumented. `speaker:privacy_settings_opened` with `["access": "local_network"]`, fired in the host's handler after the open call. Its row goes into `docs/analytics-events.md` in audiout-shared first. (Owner call 2.)
- No event is removed or renamed.

## 7. Builder checklist

### 7.1 Strings that change (b9b70310)

| Where | Now | Becomes |
|---|---|---|
| `SidebarViewController.swift:94` | In the Mixer | Shown in Mixer |
| `:95` | Hidden unless playing | Hidden unless in use |
| `:98` | In the Mixer while it plays | Shown while in use |
| `:380`, `:407` | Keep in Mixer when unavailable | Show even when unavailable |
| `:634`, `:1175` | Speakers (plate) | Overview |
| `:1178` | Speakers, manage speakers | Speakers overview |
| `:1316` | , playing | removed |
| `:1319` | , in the Mixer while it plays | , shown in the Mixer while in use |
| `SpeakersPageViewController.swift:119` | Speakers | Overview |
| `:285-297` | the search caption | the total, or under Reduce Motion "Looking for speakers…" |
| `:337` | Unknown | removed |
| `:367` | "4 AirPlay" | §2.10 sentences |
| `DeviceDetailViewController.swift:698-700` | Listed while it's on the network. / Listed even while it's unavailable. / Listed only while it plays. | §3 |
| `MixerWindowController.swift:571-577` | informative text | §4 |
| `window-harness/main.swift:98-99` | expects "In the Mixer" and the "Speakers" plate | the new headers and plate |

New strings: the section title "Speakers"; "N unavailable"; "Available"; "Unavailable"; "Local Network access is off" and its help; every spoken string in §1.8, §1.11 and §2.10; the tooltip lines in §1.8; the can't-be-found row's tooltip; "No speakers"; "Finished looking for speakers.".

### 7.2 Code by file

- `SidebarViewController.swift`: §1 throughout. Divider payload; reachable-first order; node identity and moves; pointer, menu and drag hold; heights; header and divider labels off the `textField` outlet; second header pool; inks; selected-row re-ink; Increase Contrast listener; plate dark lift; middle truncation and expansion tooltips; Add scene bar; menu strings and ⌘⌫; Command-Delete; `shouldSelectItem`, `selectionIndexesForProposedSelection`, `typeSelectStringFor`, `shouldCollapseItem`; spoken labels, heading role, tooltips; remove the dot, `dotState(for:)` and `activeMarkerView`.
- `SpeakersPageViewController.swift`: §2. `SpeakerSearch` per-kind state; the five-count struct; title; caption; strip structure; rows and the Local Network setter; build once and update in place; placeholders, highlight, Reduce Motion; spoken values and help.
- `MixerWindowController.swift`: drop `isPlaying` from `SidebarProjection`; `requestForget` intersects with the set; the sheet's informative text; push the set to the sidebar, the page and the speaker page.
- `DeviceDetailViewController.swift`: `isLost` from the set; caption glyph; Show in Mixer captions.
- `AppDelegate.swift`: compute and push the set; push Local Network status to the page; rewire `:1100` and `:2419` to the new callbacks; the new event in the Local Network handler.
- `Tokens.swift`: the two fonts; doc lists `:116-117` (`label3` no longer serves subsection headers) and `:1294-1295` (`captionMedium` now serves the sidebar's subsection headers).

### 7.3 Tests that buy their place

Each carries its "turns red" sentence (Guard 11); none goes in a one-test file.
1. Two rows selected; one speaker goes unavailable and its row moves under the divider; both ids are still selected. Red if the update falls back to `reloadData`.
2. No sidebar row, header, divider or overview element is set in `label2`, `label3`, `ember`, `gold` or `failure` (on the pattern of `GroupsInkTemperatureTests`). Red if the brown comes back.
3. `labelCool` at 4.5:1 or better and `labelCool2` at 3:1 or better against `#2C2C2E`, beside the existing contrast pins. Red if a token edit drops either under its floor on the darkest sidebar.
4. `SpeakerSearch` with only This Mac and Bluetooth arriving: AirPlay is not known at 1.9 s and is at 2.0 s. Red if AirPlay settles on the 0.5 s window again.
5. `SpeakerSearch`: `speaker:library_counted` fires once, at the overall 0.5 s settle, with unchanged properties, while AirPlay is still unknown. Red if the event moves onto the page's rule.
6. The set is empty at 9.9 s and filled at 10 s; with no AirPlay or Cast record ever live, network records stay out at any time. Red if Forget is offered for slow or unreachable speakers.
7. With the set empty, a never-seen speaker's menu has no Forget item. Red if the right-click door skips the hold.
8. Command-Delete with a can't-be-found row and a reachable row selected calls `onForget` with the can't-be-found id only; with only reachable rows selected it does not call it. Red if the key stops reaching the sidebar or the set filter is lost.
9. Before all four kinds are known the sidebar has no divider and keeps name order; after, unreachable rows sit under the divider. Red if the split runs from the first frame.
10. The divider can't be selected by click, arrow key or Shift range. Red if `shouldSelectItem` falls back to `!isGroupItem`.
11. A count update on the overview keeps the same Forget button view and keyboard focus. Red if `reload()` rebuilds rows again.

Goes: `SidebarActionsTests.swift:123-124` (pins `.playing` and `.lost` dot states). Rewritten: `test_subtitleText`, `test_kinds`, `test_discoveryShowsSpinner`, `test_sectionTitles`. Suites asserting old strings: `MixerWindowControllerTests`, `ControlPanelWindowControllerTests`, `GroupsHeaderParityTests`, `DeviceDetailViewTests`, `SidebarActionsTests`, `SpeakersPageTests`, `BTRowsUITests`, `AppSurfaceControllerTests`.

### 7.4 Docs that change with the code

- `DESIGN.md`: :403-417 (the two tabular styles; the sidebar's two header levels); :497-513 (the Speakers page; `heading` → `headingDigits` at :510); :678-717 (Speakers Sidebar and Pages: dots, search caption, `systemGreen`; add that the Speakers tab shows no sound, so its secondary ink is cool); :688 ("on a 40 pt row" → "on a row 12 pt taller than the others"); :641 and :766 (macOS 14.2 → 14.4, `Package.swift:79`). The stale paragraph at :699-705 goes. The worktree's `DESIGN.md` has another session's uncommitted edits; merge, don't overwrite.
- `AudioutWindowUI/AGENTS.md`: the map lines for `SpeakersPageViewController` ("search result, kinds, Bluetooth, lost, Pair" → counts, can't be found, access, Pair) and `SidebarViewController` ("presence dots" → reachable first, divider, unavailable); the rule "The sidebar's dot shows presence, never routing" loses "dot"; name the moving highlight as custom drawing.
- `AudioutWindowUI/AGENTS-HISTORY.md`: new dated lines only (rows now move; sidebar inks are cool). Guard 12 forbids rewriting :91-94, :165-182 and :278, which are stale.
- Window harness `window-harness/main.swift:98-99`.

## Changed from M

Sidebar
1. No dot on any row. Reachable speakers come first; a divider row "N unavailable" with `antenna.radiowaves.left.and.right.slash` heads the unreachable ones, which draw in cool inks. (M: filled `rim` dot / 2 pt `rim` ring.)
2. Rows move when reachability changes, under the rules in §1.4. (M: fixed name order.)
3. Measured grid: rows R (32), headers 19, plates R + 8, the captioned row R + 12, divider 24, Add scene bar R; x 14 / 16-38 / 46 / 186 / 192. (M: 28 pt rows, 36 pt plates, a 40 pt captioned row, a dot slot.)
4. No spacer row; the "Speakers" title row is 31 pt.
5. Every secondary ink is cool: titles, subsection headers, the caption and unreachable names in `labelCool`; unreachable icons and chevrons in `labelCool2`. (M: `label2` and `label3`.)
6. Subsection headers in `captionMedium` from their own cell pool, at x 14. (M: `caption`, the same as the row caption, stepped in 16 pt.)
7. "Hidden unless in use", "Shown while in use", ", shown in the Mixer while in use". (M: "…playing".)
8. A selected row draws every ink in the pill's text colour. (M: only the dot.)
9. Bluetooth speakers that aren't connected speak ", not connected"; every unreachable row has a two-line tooltip.
10. Middle-truncated names with expansion tooltips.
11. Command-Delete forgets selected can't-be-found speakers; the Forget menu item shows ⌘⌫; Forget waits for the can't-be-found set.
12. Rows keep their identity across updates, so selection and VoiceOver's place survive.
13. VoiceOver: subsection headers speak "Speakers shown in Mixer" and "Speakers hidden unless in use"; all four titles are headings; the caption is no longer read twice; one announcement when the selected row changes state.
14. Keyboard: plates leave multi-row selections; type-to-select strings; only the second subsection can fold.
15. Add scene bar on the icon and name columns, no hairline.
16. Plates in dark lift with `label` at 5 % instead of `raised`, which sank below the ground.

Overview
17. Page title "Overview". (M: "Speakers".)
18. Icon well at pane x 52.5, as the code places it. (M's mockups drew x 28.)
19. Header total in `captionDigits` / `labelCool`; while loading, the placeholder alone. (M: placeholder plus the word "speakers".)
20. Reduce Motion shows en dashes and "Looking for speakers…". (M: still `meter` bars at 1.59:1.)
21. "Available" carries a rule across the four kind tiles; the strip is `.fill`, and the Unavailable tile grows for long translations. (M: five equal tiles.)
22. Counts in `headingDigits` with pinned baselines. (M: `heading`, proportional digits.)
23. Labels `labelCool`; glyphs and zeros `labelCool2`. (M: `label2`; zeros `label3`.)
24. Unavailable wears the divider's glyph; the can't-be-found row wears `questionmark.circle`. (M: the ring on both, read as 12 + 6.)
25. Per-kind "known" rule: AirPlay and Cast wait for 2.0 s of quiet from the start; Unavailable and the total wait for all four. (M: AirPlay armed on first arrival with 0.5 s; Unavailable at the overall settle.)
26. The can't-be-found set waits 10 s and leaves out Bluetooth while access is off, and network speakers while Local Network is denied or nothing on the network has answered.
27. New row: Local Network access is off.
28. Unavailable's help adds "and Bluetooth speakers that aren't connected".
29. The page is built once and updated in place.

Elsewhere
30. The Forget sheet names the speakers and says what happens if one comes back. (M: unchanged sheet.)
31. Speaker page: `questionmark.circle` instead of the red glyph; Show in Mixer captions reworded; Forget waits for the set.
32. One new analytics event for the Local Network button.

## Owner calls still open

1. **Speaker pages and the Main Audio page in cool greys** (`pages-greys.png`). Default: yes, same build. It is 18 sites plus one default, nine more than the colour pass counted: the Equalizer editor's own warm inks (§3). If no, clicking from Overview to a speaker switches the pane from cool captions to warm ones.
2. **The Local Network row's button sends `speaker:privacy_settings_opened`** with `access: local_network`. Default: yes. CLAUDE.md requires a new button to be instrumented, and the event name becomes an external contract once sent.
