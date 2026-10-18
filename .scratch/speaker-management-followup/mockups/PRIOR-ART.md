# Prior art: managing remembered speakers

Researched 2026-10-04. "Verified" = read on a first-party page this session. "Inferred" = from third-party write-ups or general product knowledge, not confirmed on a first-party page. The repo's competitor study (`dev/notes/competitor-parity-research-2026-08-05.md`) has nothing on hiding or forgetting devices; its only related finding is that Sonos users backlash when rooms vanish from the list (same failure class as discovery loss).

## Product by product

**Roon.** Verified: Settings › Audio lists every output "grouped by type, and in some cases, by which computer or device they are connected to". Each row has an Enable button; "A device must be enabled in order to play music in Roon. Enabled devices will appear as Zones." A disabled device never reaches the zone picker; it stays in Settings › Audio. Private Zones hide an output from every other remote's picker ("can only be controlled from the device that it's connected to"). Inferred: renaming and per-device settings live behind the gear on the same row. https://help.roonlabs.com/portal/kb/articles/audio-setup-basics, https://help.roonlabs.com/portal/en/kb/articles/private-zones

**Airfoil.** Verified (Rogue Amoeba blog, Airfoil 5): "if you regularly connect to a shared network which contains devices you don't control, you may wish to hide them entirely", done from the Advanced Speaker Options window. Inferred (TidBITS, 5.1): right-click a speaker in the main window to hide it. Hidden speakers are restored from that same options window, not from the main list. https://weblog.rogueamoeba.com/2016/02/18/now-playing-airfoil-for-mac-5, https://tidbits.com/?p=16529

**SoundSource.** Verified (manual): "You can hide a device within SoundSource by toggling the visibility button next to its name in the sidebar" of the Audio Devices window; the AirPlay Outputs section has a "Hide All" button for crowded networks. Per-device "show in menu bar" exists for the system output. https://www.rogueamoeba.com/support/manuals/soundsource/?print=true

**Sonos.** Verified: offline products stay listed; "If a product continues to remain offline for over 3 months, or has been registered to another household, it will disappear." Manual path: Settings › Your System › the offline product › Hide, with a confirm. A second Sonos page gives 72 hours for removal, so the two pages disagree (flag). https://support.sonos.com/en-gb/article/sonos-product-shows-a-not-connected-status-in-the-app, https://support.sonos.com/en/article/products-missing-from-the-sonos-app

**macOS Sound settings.** Verified: "All sound output devices available to your Mac are listed … and AirPlay devices." No hide control is documented; only present devices appear. https://support.apple.com/guide/mac-help/change-the-sound-output-settings-mchlp2256/mac

**macOS Bluetooth settings.** Verified: hover a device and click Disconnect; Control-click › Forget ("You have to connect it again if you want to use it later"). Inferred (from the shipping UI): "My Devices" shows paired devices with Connected / Not Connected, a "Nearby Devices" section below; "Show Bluetooth in menu bar" lives in Control Center settings. https://support.apple.com/guide/mac-help/connect-a-bluetooth-device-blth1004/mac

**macOS Bluetooth permission.** Verified for iOS: apps ask once ("Don't Allow" / OK); changing it later is Settings › Privacy & Security › Bluetooth. Inferred for macOS 11+: same pane, same once-only prompt. https://support.apple.com/HT210578

**iOS Bluetooth.** Verified (Apple Community answer, matches Apple's guide): "MY DEVICES" lists paired devices with connected / not connected; "OTHER DEVICES" lists discoverable, unpaired ones; ⓘ › Forget This Device. https://support.apple.com/en-bh/HT204091, https://discussions.apple.com/thread/254848593

**Apple AirPlay picker / Home.** Inferred: the Control Center and Music AirPlay picker list only speakers currently discoverable; an unreachable HomePod drops out of the picker and shows "Not Responding" only in the Home app. No hide control. https://support.apple.com/en-au/HT208380

**Audio MIDI Setup.** Not verified: Apple's guide shows no hide, disable or remove control per device; only aggregate and multi-output devices can be deleted.

**Windows.** Inferred from consistent third-party guides (no Microsoft page found): classic Sound panel right-click › "Show Disabled Devices" / "Show Disconnected Devices"; device Properties › "Don't use this device (disable)". Windows 11 Settings: device page › Audio › "Don't allow", re-enable from Advanced › All sound devices; newer builds add toggles to show or hide disabled, disconnected and unplugged devices on that page. Microsoft's API defines the states ACTIVE, DISABLED, NOTPRESENT, UNPLUGGED. https://learn.microsoft.com/en-ie/Windows/Win32/coreaudio/device-state-xxx-constants, https://www.howtogeek.com/751183/how-to-easily-disable-sound-devices-on-windows-11/

**Spotify Connect.** Verified: a "show only local/nearby devices" setting under Settings › Apps and devices hides other people's devices on shared networks. Inferred (community): three dots › "Forget device". https://support.spotify.com/article/spotify-connect

**Google Home / Chromecast.** Verified: touch and hold the tile › Settings › Remove device › Remove; removal unlinks the device from every home member's account and deletes its data. Offline devices stay as tiles marked offline (inferred from community threads). https://support.google.com/chromecast/answer/10109815

**ToothFairy.** Verified: shows only devices you add with "+" from already-paired ones; "−" removes; Command-drag reorders menu-bar icons. No hide toggle; the list is opt-in. https://c-command.com/toothfairy/manual

**Plexamp, Discord, Zoom, Logitech, Elgato.** No first-party docs found on hiding or remembering devices. Inferred: Discord and Zoom list only present devices plus a "Default"/"Same as System" entry; Plexamp's player list is discovery-only with a refresh. Nothing to borrow.

## Pattern catalogue

| Pattern | Who | Right for 2–15 speakers | Wrong |
|---|---|---|---|
| Enable/disable on a settings list; disabled never reach the picker | Roon, Windows | One clear switch, one home for it | Disabled devices vanish from the everyday list with no hint they exist |
| Show-disabled / show-disconnected toggle on the management list | Windows (classic + 11) | Lets the management list stay short | Two toggles for one question; buried in a context menu |
| Hide via right-click in the everyday list | Airfoil 5.1, Sonos (Settings) | Fast, done where the clutter is | Undo lives elsewhere; hidden speakers are hard to find again |
| Visibility button per row in a sidebar | SoundSource | State visible at a glance, one click to undo | Two values only; no "keep offline speaker listed" |
| Bulk "Hide All" for a crowded section | SoundSource (AirPlay) | Handles the neighbour's-TV case in one click | Coarse; needs per-row undo |
| Forget / Remove with a confirm | macOS + iOS Bluetooth, Spotify, Google Home | Clear ending; matches system words | Destructive; on Google it also deletes data for everyone |
| My Devices vs Other Devices sections | iOS, macOS Bluetooth | Separates "mine" from "nearby" with no setting | Fixed rule; can't promote or demote by hand |
| Offline kept listed, then aged out | Sonos (3 months), Google Home | Speaker that's switched off is still findable | Silent expiry surprises people; Sonos's own pages disagree on the timer |
| Opt-in list (add from paired) | ToothFairy | Zero clutter by construction | Every new speaker needs a trip to settings |
| Local-only filter | Spotify | Solves shared-network noise in one switch | All-or-nothing |

**Mapping to the three-value model.** "When available" is the default everywhere (Sonos, Apple). "Always" matches Sonos/Google keeping offline products listed, and Bluetooth's "My Devices … Not Connected". "Hide when not in use" matches Airfoil/SoundSource hide, softened: no product found hides a device only while idle. Nobody uses a three-value control; everyone uses one switch (enabled, visible) plus a separate destructive Forget. The model holds, because the middle value carries a real case (a Bluetooth speaker or a powered-off HomePod you want to see greyed). A plain enabled/disabled plus show-disabled toggle would lose that case.

## Recommendations (ranked)

1. **Split the Speakers page into "Your speakers" and "Other speakers on this network".** Borrows iOS/macOS Bluetooth's My Devices / Other Devices. Improvement: the person moves a speaker between sections by choosing a visibility value, not by a fixed pairing rule, and "Other speakers" gets SoundSource's "Hide All" for the neighbour's-TV case. The page then stands on its own with no reference to scenes.
2. **Keep the three values, shown as a per-row pop-up on the Speakers page, with the Mixer right-click offering all three.** Borrows SoundSource's always-visible per-row control and Airfoil's right-click hide. Improvement over Airfoil: undo lives in the same place the hide happened (Mixer right-click) and on the Speakers page, never only in a hidden options window.
3. **Offline speakers set to Always stay in the Mixer greyed, with a "last seen" line; never auto-expire.** Borrows Sonos and Google Home keeping offline products listed. Improvement: no silent 72-hour or 3-month removal; only the person removes a speaker, through a Forget action with a confirm (Bluetooth's word, which people already know), placed on the Speakers page, not in the Mixer.
4. **Show Bluetooth speakers as one row-level state when permission is missing, with one button to System Settings › Privacy & Security › Bluetooth.** Borrows Apple's once-only prompt and Windows' explicit "disconnected" state. Improvement: instead of the section silently being empty (Discord/Zoom/Plexamp behaviour), the Speakers page says why and how to fix it in one place.
