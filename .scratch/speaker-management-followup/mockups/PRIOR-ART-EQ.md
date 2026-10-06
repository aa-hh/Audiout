# Prior art: a per-speaker equalizer on a device page

Researched 2026-10-04. "Verified" = read on a first-party page (or its search-indexed text) this session. "Inferred" = third-party write-up or product knowledge. Compares against what Audiout already has (DESIGN.md "Equalizer Door"; `EQEditorView.swift`): a simple tier of Bass / Treble / Balance / Loudness always visible, a 10-band graphic plus response curve behind an "Advanced" fold, Reset on the host's "Equalizer" title line, a bypass sentence when the EQ is not reaching audio, and in the Mixer only a row button (gold seat when not flat) and a context-menu item. The 2026-08-05 competitor study already recommended the Sonos-shaped floor (bass/treble/balance/loudness) over a 10-band default; nothing below contradicts that.

## Product by product

**Roon.** Verified: "Each zone has its own, independently configurable DSP Engine"; reached from the zone's volume control › DSP, right-click or long-press the zone icon, Signal Path › three dots, or Command-/. Inside: fixed filters (Headroom, Sample Rate Conversion, Speaker Setup) then addable ones (Parametric EQ, Procedural EQ, Crossfeed, Convolution) via "Add Filter", each with its own enable switch plus one for the whole engine. Editing is desktop-only. The EQ is not on the device settings page; it is its own full-screen editor. Inferred: parametric view draws a curve above per-band rows; no built-in preset library. 2 clicks from the zone. https://help.roonlabs.com/portal/en/kb/articles/dsp-engine, https://help.roonlabs.com/portal/en/kb/articles/dsp-engine-parametric-equalizer, https://help.roonlabs.com/portal/en/kb/articles/audio-setup-basics

**SoundSource.** Verified: every app and output device gets "two built-in effects added automatically: the Volume Overdrive and 10-Band EQ", flat by default. Expanding a source's row reveals its effects area; the EQ's inline view shows "almost two dozen presets"; expanding to a popover lets you "configure the EQ bands and preamp gain manually". "Add Effect" adds more (Headphone EQ with "profiles available for thousands of different headphone models", Audio Units). Per-source "Bypass Effects" and reset to defaults. EQ shares the expanded row with volume, balance and output routing. 1 click to expand, 1 more for sliders. https://www.rogueamoeba.com/support/manuals/soundsource/?print=true

**Audio Hijack.** Verified: EQ is a block in a pipeline; clicking the Parametric EQ block opens a popover with Type, Frequency, Q and Gain per band. Inferred: the 10-Band EQ block popover has a presets pop-up and sliders; blocks can be pinned as floating windows. Not per-device: the EQ sits upstream of whichever Output Device block follows. https://www.rogueamoeba.com/support/manuals/audiohijack/?page=advancedblocks

**Sonos.** Verified: Settings › product under "Your System" › Sound › EQ › sliders for Bass, Treble, Balance (select products), Loudness. Also an opt-in "EQ Shortcut" (Account › App Preferences) that opens EQ by tapping the volume slider during playback. The product page around it holds Trueplay, name/room, and other sound settings (inferred from the "Sound" section heading). No reset documented on that page. EQ is a sub-page, 3 taps from Settings. https://support.sonos.com/en/article/adjust-the-bass-treble-balance-and-loudness

**Apple Music (Mac).** Verified: Window › Equalizer; "more than 20 presets"; drag faders; Make Preset from the pop-up. Global, one floating window, not per output. https://support.apple.com/en-nz/guide/music/museb684a3de/mac

**HomePod (Home app).** Verified: tap the HomePod › turn on "Reduce Bass". One switch inside the accessory settings page; no other EQ. https://support.apple.com/HT208341

**AirPods.** Verified: Headphone Accommodations is in Settings › Accessibility › Audio & Visual, a guided "Custom Audio Setup" with tone choices and Play Sample, not on the AirPods page. Inferred (Engadget, iOS 27): Settings › AirPods › Audio & Routing › Equalizer, 3 sliders (Lows, Mids, Highs), "Recommended" vs "Custom", a Reset to flat, stored on the AirPods. Adaptive EQ has no user control. https://support.apple.com/HT211218, https://engadget.com/2245470/how-to-adjust-custom-eq-settings-airpods-ios-27/

**Spotify.** Verified: Settings › Playback › Equalizer switch, presets, "drag the dots" on a curve. Global; "You can't change audio settings when using Spotify Connect to play on another device." https://support.spotify.com/article/equalizer/

**Plexamp.** Verified (Plex release notes on forums.plex.tv): 3.7.0 added "equalizer per-output presets"; 10 bands, preamp, ±10 dB. One global editor whose active preset follows the output: the closest match to a global EQ with a per-device override. https://forums.plex.tv/t/plexamp-release-notes/221280/31

**eqMac.** Verified: Basic (Bass/Mids/Treble), Advanced (10 fixed bands), Expert (unlimited parametric) as three modes of one window; "Super Presets" switch presets on Output Device change. Device is picked inside the app's own output list. https://eqmac.app/

**Boom 3D.** Inferred (press kit and reviews): pick an output type from illustrated cards so Boom can tune for it; one global equalizer with genre presets and a 31-band custom. https://www.globaldelight.com/press/Boom3DPressKit.pdf

**Sony Headphones Connect.** Verified: the app's per-headphone feature list includes Equalizer alongside Sound Position Control and Surround. Inferred: preset row (Bright, Excited, Mellow…) plus Custom 1/2 with 5 bands and CLEAR BASS, on a sub-page of the device's Sound tab. https://helpguide.sony.net/mdr/wh1000xm5/v1/en/contents/TP1000534521.html

**Bose app.** Verified: "select your product then tap on the EQ button in the lower-left corner; or within the Sound section of the Settings menu, select Equalizer". Presets Flat, Bass Boost/Reducer, Treble Boost/Reducer, Custom; drag circles; "tap Reset in the upper-right corner". Two doors to one sheet. https://support.bose.com/s/article/soundlink-plus-portable-speaker-adjusting-the-tone-control-on-your-product

**Windows.** Inferred (third-party guides): Settings › System › Sound › device › "Audio enhancements" switch; the classic Properties › Enhancements tab offers Bass Boost, Virtual Surround, Room Correction, Loudness Equalization as checkboxes. No graphic EQ in the OS. https://pureinfotech.com/enable-enhance-audio-windows-11/

**Equalizer APO.** Verified: a text config with a `Device:` command scoping filters to a named playback device; the Device Selector picks which devices get the processor. https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/

**Logitech G HUB / Razer Synapse.** Verified: G HUB: select the headset › Equalizer tab, presets, saved to the device. Synapse: headset EQ lives on the "SOUND" tab; Game/Movie/Music presets are each editable and resettable; "Default" equals flat "Custom". EQ is one tab among several per device. https://support.logi.com/hc/en-us/articles/360023190814, https://mysupport.razer.com/app/answers/detail/a_id/13801/

## Pattern catalogue

| Pattern | Who | Holds up in a 443 × 670 pt detail page | Costs |
|---|---|---|---|
| EQ as a card on the device page | SoundSource (expanded row), Razer/G HUB (tab), Plexamp | Zero clicks once open; state always visible | Sliders take height; pushes identity, scenes and about facts below the fold |
| EQ behind one button on the device page | Bose (EQ button), Roon (volume › DSP), Sonos EQ Shortcut | Page stays short; one click | State hidden unless the button shows it |
| EQ as a sub-page/sheet | Sonos, AirPods (iOS 27), Sony | Full height for controls, clear Back | 2–3 steps; nobody sees the curve from the list |
| EQ as an effect slot in a chain | SoundSource, Audio Hijack, Roon | Room to grow (headphone EQ, AU) | Chain concept is heavy for bass/treble |
| Global EQ, per-device override | Plexamp, eqMac Super Presets | One editor to learn | "Which device am I editing?" ambiguity |
| Presets row + Custom | Bose, Razer, Sony, AirPods, Music, Spotify | One tap for most people | Preset names need curating |
| Single switch only | HomePod Reduce Bass, Windows Enhancements | Fits on any page | Not enough for real tuning |

Simple-tier-first is common: Sonos (4 controls), AirPods (3), eqMac Basic (3), Bose (presets first). Every product with a 10-band or parametric tier puts it one step further in (SoundSource popover, eqMac mode, Roon filter). Reset/flat is explicit in Bose, AirPods, Razer and SoundSource; Sonos documents none. Live curves appear only on the advanced tier (Roon, Spotify's dots, eqMac Expert); simple tiers are plain sliders.

For a page that must also hold identity, visibility, scenes and about facts, a full card costs the most: Audiout's simple tier is four rows (roughly 130–150 pt with its title line), which on 670 pt pushes about facts below the fold, and opening Advanced (ten faders plus the curve) would take most of the page.

## Recommendations (ranked)

1. **A collapsed Equalizer row on the speaker page that opens the existing editor in place.** One row titled "Equalizer" with a one-line summary ("Flat", or "Bass +3, Loudness on", or "10 bands set") and the same gold seat the Mixer door uses when not flat; clicking expands the existing simple tier inline, with Advanced still folded inside it. Borrows SoundSource's expand-the-row and Bose's single EQ button. Improvement: the state reads from the page without opening anything (Sonos and Bose hide it), and the page stays short until asked.
2. **Put Reset on that collapsed row, not only inside the editor.** When the curve is not flat, the row shows a Reset button beside the summary. Borrows Bose's top-right Reset and Razer's per-preset reset. Improvement: clearing a speaker's EQ is one click from the page, and the summary flips to "Flat" so the result is visible.
3. **Keep the Mixer door and the speaker page opening the same editor and showing the same state.** The door already marks non-flat with the gold seat; the page row uses the identical mark and wording, and the bypass sentence ("Not applied…") shows on the collapsed row too. Borrows Bose's two doors to one equalizer and Sonos's EQ Shortcut on the volume slider. Improvement: no second editor and no second vocabulary; a bypassed EQ is visible on the page without expanding it.
4. **Add a small preset row only if a preset tier is ever wanted, never as a separate page.** If presets come, they go as one pop-up ("Flat, Bass boost, Bass cut, Treble boost, Voice, Custom") at the top of the simple tier. Borrows the presets-row-plus-Custom pattern (Bose, Razer, Sony, AirPods, Music). Improvement over Plexamp's and eqMac's global-with-override: every speaker owns its setting, so the page never has to answer "which device is this editing". Skip it until people ask; the four simple controls already cover what Sonos ships.
