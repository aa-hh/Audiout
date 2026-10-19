# Prior art: showing "reachable now" and "not reachable" in a device list

Researched 2026-10-04 for the Speakers sidebar (direction M, owner rulings after the critique). The question: in a sidebar of remembered speakers, how to show reachable on the network vs not reachable, with filled = reachable kept, no red, and no hollow ring.

"Verified" means read this session on a first-party help page, in a first-party help image, in Apple's shipping string tables or symbol list on this Mac, or in the vendor's own source code. "Inferred" means forum threads, press, or general product knowledge. Discord's and UniFi's help centres sit behind a bot check; I read their Internet Archive copies and did not try to get past the check. Roon's help centre renders by script and has no archived text.

## What Audiout already uses (checked in code, `claude/speakers-nav`)

| Mark | Meaning | Where |
|---|---|---|
| Hollow ring, `rim` ink, 1.5 pt | Mixer: connected, silent | `RouteArmedDotView.swift:180-186`; width `PopoverColumnGrid.swift:397` |
| Dashed `rim` ring | Mixer: connecting | `HaloRingView.swift:242-253` |
| Ring in `failure` ink | Mixer: failed | `HaloRingView.swift:250` |
| Gold disc with a 1 pt `ember` edge | Mixer: routed | `RouteArmedDotView.swift:180-183` |
| The word "Unavailable" in `labelCool2` | Mixer: speaker can't be reached | `DeviceRowView.swift:1177` |
| Gold `speaker.wave.2.fill`, trailing | Sidebar: playing (the slot exists; no row shows it today) | `SidebarViewController.swift:802-826 (marker at 816)` |

Every ring style and the filled gold disc are taken. The Mixer's own mark for "can't be reached" is a word.

## Product table

| Product | Reachable mark | Unreachable mark | Colour alone? | Source |
|---|---|---|---|---|
| macOS System Settings › Network | Green dot, "Connected" under the name | Yellow dot, "Not connected"; grey and dimmed when off, "Inactive"; red = not set up | The dot is (same filled circle, colour only); the word under it is not | Verified: support.apple.com/guide/mac-help/mchlp1202/mac ; support.apple.com/en-gb/guide/platform-support/sup20c669055/web ; strings in `Network.appex` `Localizable.loctable` |
| macOS Bluetooth settings | "Connected" under the name, in My Devices | "Not Connected" under the name, same section; unpaired devices go in a separate Nearby Devices section | No: text, no dot | Verified: support.apple.com/guide/mac-help/blth8111/mac ; strings `connected` / `not_connected` in `Bluetooth.appex` |
| Finder sidebar, Locations | Mounted server listed with an Eject button; discovered computers under Network | Not listed | No: present or absent | Verified: support.apple.com/guide/mac-help/mchlp1140/mac ; support.apple.com/guide/mac-help/mchlp1546/mac |
| Mail sidebar | No mark | Lightning-bolt icon beside the account's mailboxes; clicking it takes the account online | No: an icon appears | Verified: support.apple.com/guide/mail/mlhlp1032/mac |
| AirPlay picker (Control Center, Music) | Listed | Not listed; Apple's first fix is to check the devices are on and near each other | No | Verified wording: support.apple.com/102587 ; listing behaviour inferred |
| Home app | Tile with controls | "No Response" next to the accessory | No: text | Verified: support.apple.com/102056 |
| Find My, iCloud Find Devices | Location and time under the name | Grey dot beside the device; after 7 days without a report, "No location found" under the name | The dot is; the text is not | Verified: support.apple.com/guide/icloud-iphone/aside/mme7d5a8ef/icloud ; support.apple.com/118258 ; support.apple.com/guide/findmy-mac/fmmc6c7ef383/mac |
| Sonos app | Listed in the System view | Drops out of the System view; stays in Settings › Your System as offline, with Hide; removed after 3 months offline | No: moved, plus text | Verified: support.sonos.com/en/article/products-missing-from-the-sonos-app |
| Spotify Connect | Listed in the device picker | Not listed unless the device is signed in to Spotify; a "Local device visibility" setting widens the list | No | Verified: support.spotify.com/us/article/spotify-connect/ |
| Roon | Enabled outputs appear as Zones | Not verified. Inferred: an unreachable output leaves the zone picker | n/a | Zones quote verified earlier in `../../PRIOR-ART.md`; help.roonlabs.com not readable |
| Plex | Server in the sidebar | Inferred: "Server unavailable" text | n/a | Forum only: forums.plex.tv/t/server-unavailable/899903 |
| Jellyfin | Server in the picker | Inferred: no mark; an error appears only when you choose it | n/a | Forum only: forum.jellyfin.org/t-can-t-connect-to-selected-server |
| Google Home | Tile with controls | Tile marked offline (help heading "Device appears offline") | No: text | Verified heading: support.google.com/googlehome/answer/7073578 ; tile wording inferred |
| Tailscale admin console | Last seen column reads connected | Last seen column shows a date and time; filter "Not currently connected" | No: the column is text; any dot colour inferred | Verified column and filter: tailscale.com/docs/features/access-control/device-management/how-to/filter |
| Slack | Filled green dot ("Active" beside it on the profile) | Hollow grey ring ("Away") | No: filled vs hollow | Verified from the article's images: slack.com/help/articles/201864558 |
| Microsoft Teams | Solid green circle with a check | Away: yellow clock; Offline: grey circle with an x; Status unknown: open grey circle; Away can add a last-seen time | No: a glyph per state | Verified: learn.microsoft.com/en-us/microsoftteams/presence-admins |
| Fluent UI (Teams' design system) | Available ships filled and outline icons | Offline and Unknown ship only as outline icons | No | Verified: github.com/microsoft/fluentui, `react-badge/.../PresenceBadge/presenceIcons.ts` |
| Discord | Green dot | Offline: no dot, name and avatar greyed; Invisible: hollow grey | Offline is not (dot removed, row greyed) | Verified (archive copy): support.discord.com/hc/en-us/articles/211374998 ; shape cues arrived in a 2018 colour-blind mode: pcgamer.com/discord-adds-colorblind-mode (21 June 2018) |
| VS Code Remote-SSH | Connected host named in the status bar | SSH Targets list carries no reachability mark; failure shows on connect | n/a | Verified: code.visualstudio.com/docs/remote/ssh |
| UniFi Network | "Online" | Other named states, such as "Isolated" | No: text; dot colour inferred | Verified (archive copy): help.ui.com/hc/en-us/articles/7258465146519 |
| IBM Carbon (design system) | n/a | Grey = not started | Carbon's own rule: use at least three of symbol, shape, colour and text | Verified: carbondesignsystem.com/patterns/status-indicator-pattern/ |
| Dialpad Dialtone (design system) | Green dot with a check | Offline: grey dot, no glyph; Do Not Disturb: border-only ring with a minus | Offline vs away is | Verified: dialtone.dialpad.com/components/presence.html |

Two things stand out. Apple's own settings lists (Network, Bluetooth, Home, Find My) put a word on the row. The chat apps that use dots (Teams, Discord, Dialtone) moved to one glyph per state for colour-blind users, and a hollow ring means something different in each of them: away (Slack), invisible (Discord), unknown or out of office (Teams), Do Not Disturb (Dialtone).

## Accessibility rules that bind the choice

- WCAG 2.2 SC 1.4.1 Use of Color: colour may not be the only visual means of conveying information. w3.org/WAI/WCAG22/Understanding/use-of-color.html
- The only place WCAG accepts a lightness difference alone is technique G183, for inline links, at 3:1. Dimming a row is a lightness difference, and ours is smaller: normal ink to `labelCool2` is 2.74:1 in light and 2.58:1 in dark (computed, with `labelColor` taken as 85 % black or white over the ground). Dimming alone does not meet 1.4.1 here. w3.org/WAI/WCAG22/Techniques/general/G183
- SC 1.4.11 Non-text Contrast: 3:1 against neighbouring colours for any graphic needed to understand the content. The exemption covers inactive controls only, and an unreachable row is still selectable, has a menu and offers Forget. So the mark needs 3:1, and a dimmed 13 pt name still needs the 4.5:1 text floor. w3.org/WAI/WCAG22/Understanding/non-text-contrast.html
- Apple HIG, Accessibility and Color: convey information with more than colour; add distinct shapes or icons; use colour consistently for status. HIG, SF Symbols: Apple suggests the slash variant to show an item is unavailable, and the fill variant to show selection. (Read from the data behind developer.apple.com/design/human-interface-guidelines/accessibility, /color, /sf-symbols.)
- macOS Differentiate without color (System Settings › Accessibility › Display) asks apps to show status with shapes as well as, or instead of, colour. Apps read it from `NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor`. support.apple.com/guide/mac-help/unac089/mac
- Increase Contrast raises the contrast of borders and edges; Warm Signal tokens already carry high-contrast values.
- Carbon advises against using one shape in different colours within one product. The Mixer's filled gold disc means routed; a filled grey disc in the sidebar meaning reachable is that case. The ruling stands; this is the residual risk.

### Contrast of the candidate inks (computed from `Tokens.swift`)

Light is against `#FAFAFB`, an upper bound (the sidebar material is darker). Dark is against `#2C2C2C`, the ground on which `rim` measures 2.99:1, matching the critique's measurement on the real dark sidebar.

| Ink | Light | Light, Increase Contrast | Dark | Dark, Increase Contrast |
|---|---|---|---|---|
| `rim` | 4.78 | 5.98 | 3.00 | 4.01 |
| `labelCool2` | 5.30 | 8.11 | 4.06 | 6.20 |
| `labelCool` | 6.79 | 8.54 | 6.55 | 8.24 |
| `label3` | 5.60 | 8.13 | 4.65 | 6.25 |
| `ember` | 5.82 | 8.21 | 2.78 | 3.92 |

`ember` fails 3:1 on the dark sidebar. `rim` sits on the line. `labelCool2` clears 3:1 for a mark everywhere but misses 4.5:1 for a 13 pt name in dark.

### SF Symbols on hand (from `CoreGlyphs.bundle/.../name_availability.plist`; app targets macOS 14.4)

- Usable status glyphs: `antenna.radiowaves.left.and.right.slash` (macOS 12), `wifi.slash` (10.15), `network.slash` (14), `minus.circle` (10.15), `circle.slash` (12), `circle.badge.xmark` (14).
- Device-icon slashes mostly don't exist: none for `hifispeaker`, `hifispeaker.2`, `homepod`, `homepod.2`, `appletv`, `tv.and.hifispeaker`, `airpods`, `beats.*`. Only `tv.slash` (14), `laptopcomputer.slash` (13), `headphones.slash` (15). `speaker.slash` exists but means muted.
- Filled vs outline device icons: `hifispeaker`, `homepod`, `appletv`, `tv` have both. `airpods`, `airpodspro`, `airpodsmax`, `headphones`, `beats.headphones`, `laptopcomputer` have no filled form; `tv.and.hifispeaker` has no outline.

## Patterns

**1. Leave unreachable devices out of the list.**
Who: AirPlay picker, Spotify Connect, Finder Locations, Sonos System view; VS Code checks nothing at all.
Strengths: nothing to draw, and the list is always true.
Risks for us: the sidebar is the list of remembered speakers. Forget, the visibility groups and the overview's counts all act on rows that aren't reachable. During the search (0.5 s quiet, 10 s ceiling) rows would appear one at a time and push each other down. Right for a picker, wrong for this list.

**2. Move unreachable devices into their own section.**
Who: Sonos (Settings keeps offline products, the System view drops them); macOS Bluetooth's My Devices / Nearby Devices split is the nearest Apple case, though it splits paired from unpaired.
Strengths: no per-row mark; one header can carry a count.
Risks for us: the sidebar's two groups already are the visibility setting (`AudioutWindowUI/AGENTS.md:12`). A reachability split inside each doubles the headers in a 210 pt column, and rows jump groups as the search ends. A cheaper half-step exists: the library already sorts reachable first (`SpeakerLibraryController.swift:309`), but the sidebar re-sorts alphabetically (`SidebarViewController.swift:516-521`).

**3. Put a status word on the row.**
Who: macOS Network, macOS Bluetooth, Home, Google Home, Find My, Tailscale, UniFi, Slack's profile, and Audiout's own Mixer ("Unavailable").
Strengths: the most common answer in the table and Apple's answer in its own settings. Needs no legend and no colour. Using the Mixer's word makes the two surfaces agree about the same speaker, which is CRITIQUE problem 3. VoiceOver already says ", unavailable" (`SidebarViewController.swift:1315`).
Risks for us: width and height. A trailing word takes name width in 210 pt ("MacBook Pro Speakers" barely fits; CRITIQUE flags two long Sonos names). A second line makes the row 40 pt (`SidebarViewController.swift:1148`), on 12 of the owner's 20 rows. The row has one caption, already used by "In the Mixer while it plays". "Unavailable" is wrong for a paired Bluetooth speaker that Audiout can connect (CRITIQUE problem 5).

**4. Dim the row.**
Who: Discord (offline name and avatar greyed), macOS Network (grey service), Audiout's Mixer (`labelCool2`) and today's sidebar (`label3`).
Strengths: native, zero width, and the eye skips dim rows.
Risks for us: the dim is 2.6 to 2.7:1 from normal ink, short of what 1.4.1 accepts on its own. Dimmed reads as disabled, yet the row still works. `labelCool2` names fall under 4.5:1 in dark; `labelCool` passes but is only 1.6:1 from normal ink in dark, so it barely dims. Use it only as the second signal under a shape or a word.

**5. Filled for present, hollow for absent.**
Who: Slack, Discord's Invisible, Teams' Status unknown, Fluent's outline-only Offline and Unknown icons.
Strengths: fits a 9 pt slot; familiar from chat apps; survives Differentiate without color.
Risks for us: ruled out. In the Mixer the hollow `rim` ring means connected and silent and the dashed ring means connecting. Other products give the hollow ring at least four different meanings, so there is no shared reading to borrow.

**6. Change the shape: a different symbol for the absent state.**
Who: SF Symbols slash variants (Apple's own advice for "unavailable"), Teams (check, clock, x), Discord (moon, minus), Dialtone (check, minus), Mail (lightning bolt).
Strengths: shape carries the state, so ink stays neutral, there is no red, and Differentiate without color needs no extra mode. `antenna.radiowaves.left.and.right.slash` says "no signal" without naming Wi-Fi, so it fits AirPlay, Cast and Bluetooth. `network.slash` matches the owner's words ("reachable on the network") and ships in macOS 14. Nothing in the Mixer uses either.
Risks for us: a slash glyph in a 9 pt slot is about 7 pt of ink with hairline strokes, so draw it at 1x in all four modes before choosing; `network.slash` has the finer detail of the two. The slash can't go on the device icon (missing for most of ours, and `speaker.slash` means muted). An x reads as failure even in grey. `circle.slash` and `circle.badge.xmark` still contain a ring. On the owner's fleet the glyph repeats 12 times, so its ink must be quiet.

**7. Mark only the exception.**
Who: Mail (bolt only when offline), Home ("No Response" only when failing), Audiout's Mixer (the word only when unavailable), Discord (offline loses its dot).
Strengths: the normal row stays clean; matches the standing ruling that problem rows show only when true.
Risks for us: the owner ruled that reachable rows get the filled mark and that "no dot" is out, so this survives only as "the unreachable row gets its own mark too" (pattern 6 or 3). On the owner's fleet unreachable is the majority, 12 of 20.

**8. Say when it was last seen.**
Who: Tailscale (Last seen column), Teams (last-seen time on Away), Find My (time under the name; "No location found" after 7 days), Sonos (3-month removal).
Strengths: tells "switched off tonight" from "gone for good", which is the decision Forget asks for (CRITIQUE problem 2).
Risks for us: Audiout stores no last-seen time (the only `lastSeen` in the code is `NativeBackend.lastSeenSystemVolume`), so this needs new saved data, and a time per row won't fit 210 pt. Tooltip or the speaker's own page only.

## Top 3 for Audiout

1. **Keep the filled dot for reachable; give not-reachable a slashed signal glyph in the same 9 pt slot, with the name dimmed.** Patterns 6 and 4. Candidates: `antenna.radiowaves.left.and.right.slash` first, `network.slash` second. Glyph in `labelCool2` (3:1 or better in all four modes); the dimmed name in a cool ink that reaches 4.5:1 on the measured dark sidebar, which `labelCool2` misses on the proxy ground (4.06:1). Shape alone carries the state: no ring, no red, no Mixer mark reused. If either glyph blurs at 1x, take recommendation 2.
2. **Use the Mixer's word instead of a second shape.** Patterns 3 and 7. Reachable rows keep the filled dot; unreachable rows drop the dot and show "Unavailable" (Bluetooth: "Not connected") in `labelCool2` at 11 pt in the existing trailing slot. This is what Apple's Network and Bluetooth lists do, it makes the sidebar and the Mixer say the same thing about the same speaker, and it settles CRITIQUE problems 3 and 5 together. Cost: CRITIQUE measured "Unavailable" at 60.3 pt, so names truncate sooner on those rows; test the two long Sonos names first. The owner's "no dot" rejection was about rows with no mark at all; a word is a mark, but flag it to him.
3. **Whichever mark wins, sort reachable rows first inside each group.** Pattern 2 without the extra header. Order then shows the split at a glance and the mark confirms it. The library already sorts this way (`SpeakerLibraryController.swift:309`); the sidebar's own sort in `SidebarViewController.reload` drops it. Hold the order until the search is done (CRITIQUE problem 1's rule) so rows move once, not one by one.
