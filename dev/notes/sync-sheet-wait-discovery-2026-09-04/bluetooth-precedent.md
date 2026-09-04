# Products that align speakers in time, and what their UX does

Lens: products whose job is to make two or more speakers (or a speaker and a picture) land together, with Bluetooth in the mix. General calibration rituals and the psychology of waiting are covered in `precedent.md` by another agent and are not repeated here.

Every claim about another product carries a URL. Claims I could only find second hand are marked **not verified**.

What I read from our own code first: `SyncSheet.swift:149-219` (the placement page, the disabled button reading `"Ready in \(remaining)s"` at :196-198, the two published preconditions at :204-209, the local one second tick at :213-220), and `SyncSheet.swift:463-599` (the by-ear page: a bare track, no numbers, no procedure).

---

## 1. Catalogue

Grouped by mechanism. Long rows have notes underneath.

### Phone or camera measures the delay

| Product | What it aligns | Mechanism | UX as documented | How it explains why | Wait, and what is shown | Several speakers | URL |
|---|---|---|---|---|---|---|---|
| Apple TV Wireless Audio Sync (tvOS 13+) | Wireless speaker (HomePod, AirPods) against the TV or receiver's own speakers | iPhone microphone hears tones the Apple TV plays | Settings > Video and Audio > Calibration > Wireless Audio Sync. A card appears on a nearby iPhone, user taps Continue. First time, a code on the TV is typed into the phone. Hold the phone near the TV or receiver speakers. Apple TV plays tones. Both screens show a tone is playing. Ends with "Audio Sync is Complete" and Done. Failure offers Try Again with advice to move closer or raise the volume | "audio latency, a delay that sounds like an echo when playing audio on both receiver speakers and a wireless speaker" | "only a minute or two"; no further interaction during the test; no percentage | One calibration for the whole system, stored on the Apple TV, with a Reset option | [Apple](https://support.apple.com/guide/tv/calibrate-video-and-audio-atvb228b7711/tvos), [iDownloadBlog](https://www.idownloadblog.com/2020/10/15/set-up-wireless-audio-sync-apple-tv/), [iMore](https://www.imore.com/how-set-and-use-wireless-audio-sync-apple-tv) |
| Roku Adjust Audio Delay | Streambar or soundbar against the picture | Phone **camera** pointed at the screen, in the Roku app | Roku app > Devices > pick the device > remote icon > settings icon > Adjust Audio Delay > allow camera > follow the steps in the app | Framed as re-syncing after wireless latency | Not stated. The article tells the user up front: "Perform Adjust Audio Delay a few times to get the desired fix" | One device at a time | [Roku](https://support.roku.com/article/sound-is-out-of-sync) |
| AmpMe | Several phones, each driving its own Bluetooth speaker | Guest phone's microphone hears the host, plus a server-side matching step | Host starts a party, guests join with a four digit code while physically near the host, sync then runs automatically. A manual offset lives in party settings behind the gear icon | Product copy only. No mechanism explanation found | Not documented. Reviewers report the sync step sometimes "takes just a little long" | Any number of phones, each joined separately | [AmpMe FAQ](https://ampme.com/faq?locale=en_US), [Android Police](https://www.androidpolice.com/2015/10/01/ampme-turns-multiple-phones-into-speakers-for-your-music-how-it-works-and-how-it-compares-to-soundseeder/), [App Store reviews](https://apps.apple.com/ca/app/ampme-speaker-music-sync/id986905979?see-all=reviews) |

Note on AmpMe: the exact wording and screens of its microphone sync step are **not verified**. Press coverage describes "server-centric proprietary audio matching technology" and a proximity requirement at join time, and the app's help describes a manual offset, but I found no screenshot or first-party walkthrough of the listening step itself.

### Manual offset, adjusted by ear while the music plays

| Product | What it aligns | Mechanism | UX as documented | How it explains why | Wait, and what is shown | Several speakers | URL |
|---|---|---|---|---|---|---|---|
| Google Home / Nest group delay correction | Speakers inside a cast group, including a Bluetooth speaker hanging off a Nest Mini | Manual slider, per device | Home app > device tile held down > Settings > Audio > Group delay correction. Adjust **while music is casting to the group**. Stand between the speakers, or as close to between as you can. Match their volumes first. Move the slider until it sounds in sync. Diagnostic rule: "always correct the speaker that is playing last"; raise one speaker's correction, and if it gets worse set it back to 0 and try another | "Don't adjust the group delay correction unless you notice a consistent, significant delay" | None. The control is live and the change is heard immediately | Per device, and that device's value then applies to every group it is in | [Google](https://support.google.com/googlehome/answer/6318642?hl=en) |
| WiiM Group Audio Delay | Speakers in a multi-room group | Manual value, per device **and per input** | Home app > Devices > device settings icon > Group Audio Delay. Must be set on the group lead device to take effect | Lower values help lip sync on TV inputs, higher values help multi-channel stability. Warns that too low a value can cause sound loss on some devices | None | Per input on the lead device; users report 70 ms and 150 ms modes | [WiiM](https://faq.wiimhome.com/en/support/solutions/articles/72000638653-using-the-group-audio-delay-setting-for-wiim-multi-room-audio) |
| Airfoil (Rogue Amoeba, Mac and Windows) | Every output it streams to, including Bluetooth | Automatic alignment to the slowest output, plus a manual Sync slider per output | Advanced Speaker Options window, one slider per destination, adjusted while music plays, by trial and error. Remembered between launches | States the initial delay per transport: computer output almost none, AirPlay 2 s, Chromecast 2 s, Bluetooth "a variable delay, depending on their connection, generally not exceeding two seconds" | None. Alignment is automatic; the sliders are the exception | All outputs at once, equalised to the highest latency device. Bluetooth sliders can only **add** delay, up to +1.00 s | [Rogue Amoeba](https://rogueamoeba.com/support/knowledgebase/?showArticle=Airfoil-AudioLatency) |
| SoundSeeder | Phones and tablets playing the same music, each possibly feeding a Bluetooth speaker | Manual offset, per speaker device, 10 ms steps | In Speaker Mode, the +/- button bottom left. Recommended procedure: try -100 ms and +100 ms first to find which direction you need, then move in 10 ms steps until it is in sync. Saved for later connections | Blunt and mechanical: Bluetooth speakers "use their own audio buffer, that adds an additional delay", and "On most speakers this delay varies between 20ms and 70ms each time you start your playback". Page opens with "Synced playback via Bluetooth speakers can not be guaranteed!" and advises wiring the speaker to the line out instead | None | Each speaker device sets its own offset | [SoundSeeder sync](https://soundseeder.com/help/sync-playback/), [SoundSeeder Bluetooth](https://soundseeder.com/help/using-soundseeder-with-bluetooth-speakers-via-a2dp/) |
| Snapcast (open source multi-room) | Every client in a synced group | Per-client latency value, 1 to 1000 ms | Set with a `--latency` flag or a Home Assistant action. Docs note a Bluetooth speaker on a client "can have a delay of about 250 ms" | Defines latency plainly: sound leaves the speaker N ms after the client played it | None | Per client | [Home Assistant](https://www.home-assistant.io/actions/snapcast.set_latency/), [Snapcast discussion](https://github.com/snapcast/snapcast/discussions/743) |
| Roon zone group delay | Grouped zones of mixed hardware | Manual millisecond value per device | Device Setup > Advanced > zone group delay | Community support material only; no first-party explainer found | None | Per device inside a group | [Roon community](https://community.roonlabs.com/t/sound-out-of-sync-solved-adjust-zone-grouping-delay/167847) |
| Sonos TV Dialog Sync / line-in Audio Delay | Soundbar against the picture; line-in against grouped rooms | Manual slider (lip sync) and fixed presets (line-in) | Sonos app > Settings > System > Home Theater > TV Dialog Sync, drag right to add delay. Line-in offers Low 75 ms, Medium 113 ms, High 150 ms, Max 2000 ms | The 75 ms floor is the buffer that lets grouped rooms play together; it has been there since the first ZonePlayers | None | The line-in delay exists precisely so several rooms can share one input | [Sonos](https://support.sonos.com/en-us/article/tv-audio-and-video-are-out-of-sync), [Sonos community on the 75 ms floor](https://en.community.sonos.com/advanced-setups-229133/no-delay-option-for-era100-speakers-6889932) |
| VLC, Kodi, Plex audio offset | Sound against picture | Manual, live, keyboard or on-screen slider | VLC desktop: J and K move the audio in 50 ms steps during playback, Shift+K resets. VLC Android: "..." menu > Audio delay, slider plus +/- buttons. Plex: Alt+A and Alt+Shift+A, 50 ms per step, or an offset control in the player's audio menu. Kodi: adjust the offset during playback, then "apply to all videos" | Not explained; assumed | None. The readout changes as you press | One stream | [VLC guide](https://www.stellarinfo.com/blog/fix-audio-video-delay-in-vlc-media-player/), [Plex fixes](https://smarttvs.org/plex-audio-out-of-sync/), [Kodi forum](https://forum.kodi.tv/showthread.php?tid=367357) |
| Samsung and LG TV AV sync | Soundbar against picture | Manual slider in TV settings | Samsung: Settings > Sound > Expert Settings > Digital Output Audio Delay. LG webOS: Settings > All Settings > Sound > AV Sync Adjustment, switched on, then a delay bar | Not explained in the menu | None | One output | [PointerClicker](https://pointerclicker.com/how-to-fix-lip-sync-on-samsung-lg-tvs/) |

### Automatic, no user control at all

| Product | What it aligns | Mechanism | UX as documented | How it explains why | Wait, and what is shown | Several speakers | URL |
|---|---|---|---|---|---|---|---|
| Denon and Marantz Auto Lip Sync | Receiver against TV over HDMI | Automatic, TV reports its own delay | A single On/Off setting. The manual states plainly that "automatic correction may not be performed depending on the specifications of your TV even when Auto Lip Sync is set to On", and that the value it lands on can be adjusted by hand afterwards | Names the failure case in the same sentence as the feature | None | One link | [Denon manual](https://manuals.denon.com/AVRX3400H/EU/EN/GFNFSYxnslsydu.php) |
| TuneBlade (Windows to AirPlay) | Several AirPlay receivers | Automatic: picks the highest of the receivers' minimum acceptable latencies so all stay together. A global buffer size slider in Custom Streaming Mode | Three presets plus a custom buffer size | Higher buffer means higher latency and more reliability | None | All receivers at once. Per-device sliders appear not to exist (**not verified**, first-party docs describe a global setting only) | [TuneBlade docs](http://www.tuneblade.com/support/documentation/3.html) |
| Samsung Dual Audio | Two Bluetooth speakers from one phone | Automatic, and no delay control exists | Pick two devices in the media panel | Nothing | None | Two devices. Users' workaround is to uncheck and re-check one speaker until a connection happens to land in sync | [Samsung community](https://eu.community.samsung.com/t5/other-galaxy-s-series/dual-audio-not-in-sync/td-p/3350639) |
| Apple Share Audio (two sets of AirPods) | Two headphones from one iPhone | Automatic | Control Centre > AirPlay icon > Share Audio, bring the second pair close with the case open, tap Share Audio when prompted. Long-press the volume slider for a separate slider per set | Nothing about timing | None | Two sets | [Tom's Guide](https://www.tomsguide.com/audio/airpods/this-hidden-iphone-feature-lets-you-connect-two-pairs-of-wireless-headphones-at-once-for-shared-listening-but-theres-a-catch) |

### Party and group flows with no timing control

| Product | Mechanism | UX as documented | Several speakers | URL |
|---|---|---|---|---|
| JBL PartyBoost / Connect+ | Automatic | Button on each speaker, or the app. Support article for sync trouble offers only physical advice: move the source closer, move the speakers closer, restart everything | Connect+ claims over 100 speakers | [JBL setup](https://support.jbl.com/howto/setting-up-multiple-partyboost-speakers-in-a-group-us/000016749.html), [JBL dropouts](https://support.jbl.com/us/en/howto/audio-distortion-or-drop-outs-while-using-partyboost-or-connect-us/000021182.html) |
| Ultimate Ears PartyUp | Automatic | In the Boom app, tap the PartyUp icon, then **drag and drop** nearby speakers onto the primary one | Up to 150 speakers | [Logitech press release](https://ir.logitech.com/press-releases/press-release-details/2016/Ultimate-Ears-Turns-the-Party-Up-with-PartyUp/default.aspx) |
| Bose SimpleSync and Party Mode | Automatic | In Bose Connect, tap the two-speaker Party Mode icon, then drag the top speaker onto the bottom one. A voice prompt says "Party mode enabled". A bottom toggle switches to Stereo L/R | Two products maximum, within about 9 m of each other | [Bose](https://www.bose.com/stories/how-to-connect-multiple-bluetooth-speakers), [Bose groups](https://www.bose.com/help/using-groups) |
| Soundcore PartyCast | Automatic | App: connect the first speaker, tap the PartyCast button. Or double-press the PartyCast button on the second speaker. Marketing claims "millisecond-perfect synchronization" | Over 100 speakers | [Soundcore](https://www.soundcore.com/partycast) |
| Sony Party Connect and Stereo Pair | Automatic | Music Center: Speaker & Group > Group with other speakers > Party Connect > select devices > Next. Stereo Pair asks for the two speakers to be within 1 m of each other and validates model and firmware before proceeding | Party Connect up to 100 speakers | [Sony](https://www.sony.co.uk/electronics/support/articles/MC000013), [Sony help guide](https://helpguide.sony.net/speaker/srs-xb13/v1/en/contents/TP1000200014.html) |
| Samsung Sound Tower Group Play | Automatic | Press GROUP PLAY on the main speaker, its display reads HOST and its light blinks. Press GROUP PLAY on the second. Both displays read GROUP PLAY CONNECTED. **To add a third: press the host's button, wait 15 seconds, then press the next speaker's button.** Repeat | Up to ten extra speakers | [Samsung](https://www.samsung.com/us/support/answer/ANS00086422/) |
| Auracast on Samsung Galaxy | Broadcast, no timing control | Broadcaster: Settings > Connections > Bluetooth > three dots > Broadcast sound using Auracast > name and optional password > Start broadcast. Listener: Bluetooth > gear next to their buds > Listen to Auracast broadcast > pick from Available broadcasts, entering a password if set | Many listeners | [Samsung](https://www.samsung.com/us/support/answer/ANS10003615/) |

### One product that shows the link's readiness as state

| Product | What it shows | UX as documented | URL |
|---|---|---|---|
| Dante Controller (professional audio networking) | A per-device clock lamp. Green means "the device is currently synced to (or is driving) the network clock"; red means "the device is not currently synced". A red mute icon means the device is muted, "usually due to loss of clock sync". A Clock Status Monitor in the corner turns red on any loss and keeps a History tab | The engineer's routine is to look down a list of devices and check the lamps before doing anything else | [Audinate](https://dev.audinate.com/GA/dante-controller/userguide/webhelp/content/clock_status_view.htm) |

A Q-SYS support tip is quoted in search results as saying to let the system settle because clocks adjust over the first 30 seconds to 5 minutes. I could not confirm that sentence on the page itself, so treat it as **not verified**: https://support.qsys.com/en_US/tips/tip-%7C-steps-to-ensure-dante-network-operates-as-expected

### Products that refuse the use case rather than dress it

| Product | What it says | URL |
|---|---|---|
| djay (Algoriddim) | Advises against Bluetooth speakers and headphones because of latency, and does not support pre-cueing over Bluetooth or AirPlay at all. The recommended answer is a wire | [Algoriddim](https://help.algoriddim.com/topic/troubleshooting/reduce-audio-midi-latency) |
| Android developer options | Offers a Bluetooth codec picker, sample rate, bits per sample and an A2DP hardware offload toggle. No offset control anywhere | [Google Oboe tech note](https://github.com/google/oboe/wiki/TechNote_BluetoothAudio) |
| Windows 11 | No offset control. Official guidance is troubleshooting: check the output device, run the troubleshooters, restart audio services, update drivers, re-pair | [Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/3744246/delay-low-quality-on-bluetooth-audio-windows-11) |

---

## 2. Five moves worth borrowing

### Move 1. A readiness lamp per speaker, so the wait is a list to read rather than a paragraph

**From:** Dante Controller. Every device on the network carries one lamp: green if its clock is locked, red if not, with a red mute icon when a device has lost sync. An engineer's first move is to scan the column, not to read an explanation. https://dev.audinate.com/GA/dante-controller/userguide/webhelp/content/clock_status_view.htm

**Why it works:** it converts an invisible internal condition into a thing you look at. Nobody has to understand what a clock lock is to understand that four rows are green and one is not. It also makes the wait finite by making it visible per item.

**In our sheet:** the waiting state stops being one paragraph plus a disabled button, and becomes a short list of the user's Bluetooth speakers with one word of state each. The Mac already publishes `settleRemainingSeconds` inside each device's alignment block, so the phone can render the whole list today with no new wire field (brief section "What the phone can see and do"). Warm Signal allows exactly one gold action per decision screen, so the list rows are plain and the single gold button stays at the bottom. The list is the answer to Alec's "have them define which speakers they want to set up": it is the same screen, doing scope-setting and status at once. No fake progress is involved because every row shows only what the Mac said.

### Move 2. Connect them one at a time, with the pause attached to each speaker

**From:** Samsung's Sound Tower Group Play. Adding a third speaker is documented as: press the host's button, **wait 15 seconds**, then press the next speaker's button. The wait is stated, small, attached to an action the user just took, and repeated per speaker. https://www.samsung.com/us/support/answer/ANS00086422/ Sony's Stereo Pair does the same job with a physical precondition instead of a clock: put the two speakers within 1 m of each other before pairing. https://helpguide.sony.net/speaker/srs-xb13/v1/en/contents/TP1000200014.html

**Why it works:** a wait the user caused, on the item they just touched, reads as the machine doing what they asked. A wait imposed before they have done anything reads as a toll.

**In our sheet:** when the user has more than one Bluetooth speaker to set up, they pick them on the list from move 1, and the sheet works them in order. Speaker one is measured while speakers two and three are settling, so the wait for the later ones is spent on real work rather than on a countdown. Our rule that nothing is app-initiated still holds: the list does not run itself, each speaker's measurement starts on a tap. The honest limit worth naming now is that this only banks the wait if the Mac's settle clock runs from link-up regardless of whether anyone is watching. See question 1.

### Move 3. Say that measuring is cheap and repeatable, so measuring early stops being a gamble

**From:** Roku tells users up front, in the support article for its camera-based delay calibration, "Perform Adjust Audio Delay a few times to get the desired fix." https://support.roku.com/article/sound-is-out-of-sync Apple TV keeps a Reset in the Wireless Audio Sync menu so the calibration is a thing you own and can redo. https://support.apple.com/guide/tv/calibrate-video-and-audio-atvb228b7711/tvos

**Why it works:** the reason a user resents a gate is that they think the thing behind it is one shot. Once a measurement is framed as repeatable, waiting becomes optional rather than compulsory, and the escape hatch stops feeling like a trap.

**In our sheet:** the phone branch's "Measure it now" line already offers the early measurement, and it is the line Alec calls a pass-through with no meaning. The change is what sits beside it: not a warning about variance, but the plain fact that a measurement takes about twenty seconds and can be run again whenever. Nothing here is invented state; the Mac already tracks staleness and already re-checks. Keep the announced, refusable re-check as the one app-initiated exception it already is.

### Move 4. Name the speaker that is late, and give the by-ear page a direction to try first

**From:** Google Home's group delay correction gives the user an actual procedure rather than a slider. Stand between the speakers. Match their volumes. Adjust while music is casting so you hear the change. Then the diagnostic rule: "always correct the speaker that is playing last", and if raising one speaker's correction makes it worse, set that speaker back to 0 and try another. https://support.google.com/googlehome/answer/6318642?hl=en SoundSeeder gives the same shape for its offset: try -100 ms and +100 ms first to learn which direction you need, then move in 10 ms steps. https://soundseeder.com/help/sync-playback/

**Why it works:** a bare slider with no anchor gives the user no way to know whether they are helping. A find-the-direction-first procedure turns a continuous guess into two decisions.

**In our sheet:** the by-ear page today is a track with two chevrons, no scale and no procedure (`SyncSheet.swift:549-573`). It gains one plain instruction of the same shape, phrased without numbers so it stays true to the page's design: slide well over to one side, then well over to the other, keep the side where the two clicks got closer, then work in small moves. This costs no new state and no new wire field.

### Move 5. One sentence about the buffer, placed where the user asks "why again?"

**From:** SoundSeeder's help page for Bluetooth speakers, which explains the whole mechanism in two sentences: Bluetooth speakers "use their own audio buffer, that adds an additional delay to your audio playback", and "On most speakers this delay varies between 20ms and 70ms each time you start your playback." https://soundseeder.com/help/using-soundseeder-with-bluetooth-speakers-via-a2dp/ Airfoil does the same with one clause, listing Bluetooth as "a variable delay, depending on their connection". https://rogueamoeba.com/support/knowledgebase/?showArticle=Airfoil-AudioLatency

**Why it works:** it is short, it is mechanical, and it gives the user a model that explains every future surprise, including why a saved tuning goes stale. It is put in help text next to the control it explains, not in front of a button the user is trying to press.

**In our sheet:** the settling explanation moves off the placement page and onto the moment it actually answers, which is when a row that was tuned yesterday says "Check timing again". One sentence: the speaker picks a fresh delay every time it reconnects, so the old number no longer fits. Our current placement page leads with about forty words of theory before anything to do; every product in this catalogue puts the theory after the first instruction or leaves it out.

---

## 3. Three anti-patterns in this category

### A. A delay slider with no reference, so the user cannot tell which speaker is wrong or whether they are helping

Google Home ships the control, and the community threads are full of people who cannot make it do anything. Reports include the correction making no difference at any setting, and raising it on one speaker lengthening the delay while raising it on another does nothing. The negative range caps at 0.2 s, which is not enough to claw back what a Nest Mini adds for a Bluetooth speaker hanging off it.
https://www.googlenestcommunity.com/t5/Speakers-and-Displays/Problem-with-music-group-sync-of-multiple-Google-Devices/m-p/374881
https://www.googlenestcommunity.com/t5/Speakers-and-Displays/Overcorrecting-group-delay-for-bluetooth-connected-home-mini/td-p/179238
https://www.googlenestcommunity.com/t5/Speakers-and-Displays/Delay-correction-not-working/td-p/4538

What we do about it: our by-ear page has the same shape, so move 4 above is the mitigation. Our advantage is that the microphone measurement names the direction for the user before they ever touch the track.

### B. Shipping the grouping and withholding the timing control, so users invent rituals

Samsung Dual Audio has no delay setting at all. The workaround people share is to uncheck one speaker in the media panel and check it again until a connection happens to land in sync, which is a user manually re-rolling the Bluetooth buffer. Others ask Samsung directly for a slider.
https://eu.community.samsung.com/t5/other-galaxy-s-series/dual-audio-not-in-sync/td-p/3350639
https://r1.community.samsung.com/t5/galaxy-s/dual-audio-manual-delay-sync/m-p/38331183

Sonos is the same story from the other end: the 75 ms line-in floor exists so grouped rooms can play together, there is no way to remove it, and the thread asking for a "none" option runs on with no official answer. One user writes that "the introduced delay and the missing option to fully remove it destroyed the perfect image of these speakers for me."
https://en.community.sonos.com/advanced-setups-229133/no-delay-option-for-era100-speakers-6889932

What we do about it: keep the by-ear page reachable from every screen in the sheet, which it already is (`SyncSheet.swift:174`, :311, :442). Our risk is the opposite of Samsung's: we have the control and are gating it.

### C. A one-shot measurement that fails with a message the user cannot act on, and leaves nothing behind

Apple TV's Wireless Audio Sync reports "No Tones Detected" and stops. The thread I read has 57 "me too" marks and was closed with no reply at all. The user's summary of the experience is "I can't understand how this happened as I am here alone and have changed no settings."
https://discussions.apple.com/thread/255528581

The same feature also went stale silently for Dolby Atmos users for years, and Apple's fix was a new version of the calibration shipped in tvOS 18.5.
https://www.techradar.com/televisions/streaming-devices/apple-tv-audio-not-syncing-properly-tvos-18-5-should-fix-this-strange-dolby-atmos-bug

What we do about it: our refusal pages already say the Mac's own reason and always offer the by-ear page instead (`SyncSheet.swift:399-451`). The part worth guarding is staleness: a stored number that quietly stopped being right is exactly this failure, and it is what our stale reasons exist to prevent.

---

## 4. How long real Bluetooth links take to stabilise

Thin evidence, and none of it is a proper distribution. What exists:

**Latency falling for tens of minutes after connecting.** An Apple developer forum post measures AirPods 2 on an iPhone 12 mini: actual latency starts at 215 to 220 ms right after connecting and falls continuously, settling at 155 to 160 ms after roughly 20 to 30 minutes, which is when it finally matches the value `AVAudioSession` was reporting all along. If the AirPods had already been in use for a while, the starting point is around 180 ms instead. The developer's own word for it is that Bluetooth needs to "warm up", and says the effect is stronger on older iOS devices. Other developers confirmed it in the thread. Apple never replied.
https://developer.apple.com/forums/thread/679274

That is the single strongest external data point I found, and it is much longer than our 60 s window. It is one device pair, and it is headphones rather than a speaker, so do not generalise it.

**A fresh delay on every playback start.** SoundSeeder's own documentation: "On most speakers this delay varies between 20ms and 70ms each time you start your playback." Note this is per playback start, not per pairing, which is a harsher claim than our per-connection model.
https://soundseeder.com/help/using-soundseeder-with-bluetooth-speakers-via-a2dp/

**A range wide enough that a product will not name a number.** Airfoil describes Bluetooth as "a variable delay, depending on their connection, generally not exceeding two seconds", against flat 2 s figures it is willing to state for AirPlay and Chromecast.
https://rogueamoeba.com/support/knowledgebase/?showArticle=Airfoil-AudioLatency

**Latency that drifts upward during a session.** HiFiBerry OS users report Bluetooth input latency around 300 to 400 ms that "seems to increase to almost 1 second sometimes", needing a reboot to come back down.
https://github.com/hifiberry/hifiberry-os/issues/292
https://support.hifiberry.com/hc/en-us/community/posts/360011298877-Improve-Bluetooth-audio-latency-on-HifiBerryOS

**Baseline buffering, which sets the floor.** Patent literature describes A2DP devices adopting buffers of roughly 150 to 200 ms of audio as a trade between robustness, latency and memory, with clock drift and retransmissions added on top, and transmit and receive clocks not synchronised. Android's own guidance says most Bluetooth latency comes from buffering in the headset rather than from the phone.
https://patents.justia.com/patent/10334358 (403 to my fetch tool, so the assignee and claims are **not verified**; the figures above come from the search summary of the patent family)
https://github.com/google/oboe/wiki/TechNote_BluetoothAudio

**By codec, not by brand.** SBC 200 to 250 ms, AAC 120 to 150, aptX 100 to 150, aptX Adaptive and Low Latency 40 to 80, LC3 under 30.
https://www.outeraudio.com/bluetooth-speaker-latency-explained/

**Per brand, what little there is.** Snapcast's docs use "about 250 ms" as a representative Bluetooth speaker client. https://www.home-assistant.io/actions/snapcast.set_latency/ Sonos applies a fixed 75 ms buffer to line-in and community answers say Bluetooth is "slightly more". https://en.community.sonos.com/advanced-setups-229133/no-delay-option-for-era100-speakers-6889932 One Sonos Roam user reports roughly half a second over Bluetooth, **not verified**. https://en.community.sonos.com/portable-speakers-229130/latency-between-sonos-roam-and-macbook-when-using-bluetooth-6887888

**What I could not find.** No product documents a settling window before measurement. No product tells the user to wait for a Bluetooth link to stabilise. The only place I found that idea stated at all is professional audio networking, where the practice is to read a per-device clock lamp before trusting anything, and where a support tip is quoted as saying clocks adjust over the first 30 seconds to 5 minutes (**not verified**, see the Dante row in section 1). So our 60 s gate has no consumer precedent to copy. What it does have is a professional precedent for showing readiness as state, which is move 1.

Read against our own measurement (Sonos Move 2 chaotic for 0 to 42 s, Sony WH-1000XM3 settled from second one, brief section "What the wait actually is"), the external evidence agrees on the shape and says nothing useful about the spread. Nobody knows how often the wait will be long, and nothing I found changes that.

---

## 5. Three questions only Alec can answer

1. **Does the Mac's settle clock run from link-up whether or not anyone is watching?** Move 2 only banks the wait if connecting three speakers up front means speakers one and two have finished settling by the time the user reaches speaker three. If the countdown only starts when the sheet opens, the whole one-at-a-time idea collapses into three sequential 60 s waits, which is worse than today.

2. **On his own ears and his own Sonos Move 2, how wrong is a measurement taken during settling?** If measuring at second five lands within a few tens of milliseconds, the gate should become advice and moves 3 and 5 carry the work. If it lands hundreds of milliseconds out and the user then hears a fixed speaker sounding worse than before, the gate has to stay and moves 1 and 2 carry it. Everything in this report branches on that number, and it is a listening judgement.

3. **Is he willing to widen the sheet from one speaker to a list of speakers?** Every party and group product in this catalogue is list-first: you pick the speakers, then the system works them. Our sheet is single-speaker-first with one forward link after a verdict (`SyncSheet.swift:338-352`). Moves 1 and 2 both assume a list. That is a scope change to the sheet's shape, not a copy change, and the Mac's own by-ear wizard has no gate at all today, so it is worth deciding in the same breath whether the Mac gains the gate or the phone loses it.
