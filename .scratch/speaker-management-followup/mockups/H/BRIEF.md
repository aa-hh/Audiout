# Direction H: one list, one eye per speaker

**Sidebar: option (b).** This page replaces the sidebar's speaker rows; the sidebar keeps the Scenes plate, Main Audio and Speakers. Clicking a row opens that speaker's detail page (Equalizer first, Back to Speakers above), so the Equalizer is one click away, marked by a chevron.

**Borrowed, and improved.** SoundSource's visibility button beside each name: kept, and the Mixer's right-click says the same "Hide from Mixer", so undo lives where the hide happened. Airfoil restores hidden speakers from a separate window: here they sit in a collapsed "Hidden speakers (n)" group at the foot of the same list. SoundSource's AirPlay "Hide All": kept, beside "Show All" at that group's head. Windows and Roon split "enabled" from "show disconnected": here that second question appears only on a kept speaker that is away now, as one checkbox, "Keep in Mixer".

**First read.** The Mixer's own list in its order, then one closed group.

**An eye, not a switch.** A switch says "turn this on"; this page never activates anything. An eye answers the one question, "do I see it in the Mixer", and stays truthful when a hidden speaker plays: eye crossed out, gold "Playing, shown until it stops". Borderless `NSButton`, `eye` / `eye.slash`.

**States.** Unavailable: grey name, the Mixer's word. Can't be found: Forget… instead of the checkbox. Bluetooth denied: unconnected Bluetooth rows drop out; one line plus "Open Privacy Settings…". Empty: This Mac alone, "Speakers appear here as Audiout finds them", no group.

**2 vs 15.** Fifteen scroll; Hide All clears a neighbour's network.

**Trade-offs.** Always for a speaker that is here now needs right-click or its detail page.

**Maps to.** `NSOutlineView` with one group item in `SpeakersOverviewViewController`; `DeviceIconWellView`; checkbox `NSButton`; `setBluetoothAccessExplanation`; `SpeakerMixerVisibility` unchanged (eye off = `hideWhenNotInUse`, ticked = `always`).

**Owner rulings.** Forget (NEW: leaves every scene); the Mixer menu's three values becoming Hide plus Keep in Mixer.
