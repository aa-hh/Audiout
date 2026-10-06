# Direction I: your speakers on the Mixer's line

**Sidebar: option (b).** This page replaces the sidebar's speaker rows; the sidebar keeps Scenes, Main Audio and a Speakers plate. A row click (chevron) opens that speaker's page, Equalizer first.

**Borrowed.** Bluetooth's My Devices / Other Devices, as **Your speakers** and **Other speakers · not in the Mixer**; SoundSource's per-row eye. **Improved:** the person chooses the section, and Your speakers hang on E's ember rail in Mixer order, so the page shows what the Mixer will list.

**Focal moment.** The line from the Mixer well, one gold node on TV. Clicking an eye moves a row on or off the line; the line stretches to meet it in 200 ms.

**Rail.** Filled ember: listed now. Hollow: kept, not listed while away. Gold: sounding now, nowhere else. No node: Other speakers.

**Secondary option.** "Keep listed while away", on away rows only: ticked = Always, unticked = When available. Off the line = Hide when not in use.

**States.** Away: cool ink. Missing: no transport, "Not found on any network". Hidden but in use: gold node on a dashed spur, "Playing now · in the Mixer until it stops". Bluetooth denied: a nodeless row closes Other speakers, "Open Privacy & Security…". Empty: This Mac alone.

**Trade-offs.** The eye leans on its tooltip; away rows carry three controls; fifteen speakers scroll under a fixed header.

**Maps to.** `MembershipBusView`, `BusRailOverlayView`, `DeviceIconWellView`, `NSTableView` group rows, toggle `NSButton` (`eye`/`eye.slash`), checkbox, `setBluetoothAccessExplanation`, `SpeakerMixerVisibility` unchanged.

**Rule bent.** The rail means scene membership in the editor, Mixer listing here. DESIGN.md gains: "On the Speakers page the rail draws the Mixer's lineup: filled is listed now, hollow is kept but away; the node is drawing, never the control." (DESIGN.md's light gold `#A67C1E` is stale; code has `#E8B84B`.)

**Rulings.** 1. Forget (NEW; missing speakers, right-click; leaves scenes). 2. New speakers land in Other speakers or on the line (today)?
