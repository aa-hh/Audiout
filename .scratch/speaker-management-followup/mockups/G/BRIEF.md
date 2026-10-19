# Direction G: Your speakers, Other speakers nearby

**Borrowed, improved.**
- **macOS/iOS Bluetooth** (My Devices over Other Devices): kept above, seen below. Improvement: the person moves a speaker either way; pairing fixes nothing.
- **SoundSource** (Hide All for crowded AirPlay lists). Improvement: Hide All only folds the lower section to one line, changing no choice.
- **Airfoil** (right-click hide, undo elsewhere). Improvement: the row menu repeats the Mixer right-click's choices; undo sits where the hide happened.

**Sidebar: option (b).** This page replaces the sidebar's speaker rows. The sidebar keeps the Scenes plate, Main Audio and a Speakers plate.

**First read.** "Your speakers" is what the Mixer lists. Below, sunk in a `.well`, "Other speakers nearby": seen, left out. ("Nearby": Onkyo is Bluetooth.)

**Per-row control.** Lower rows: "Show in Mixer" in Bluetooth's Connect slot, activating nothing (sets When available). Upper rows: a borderless pull-down titled with the current choice. Menu: the three choices, Speaker settings…, Forget…. Research: the middle value earns its place (a switched-off HomePod stays listed); nobody ships columns of bordered pop-ups.

**Equalizer in one step.** Each kept row carries the Mixer's Equalizer button (gold seat when not flat). It opens the speaker's page at its Equalizer; the rest of the row opens that page at the top.

**States.** Unavailable, not connected, missing: cool ink, never expired (unlike Sonos). In use: gold "Playing now"; hidden and playing stays below: "Playing, so the Mixer shows it until it stops". This Mac: "Always", no menu. Bluetooth denied: remembered Bluetooth speakers read "Bluetooth access is off"; one row below offers "Open Privacy Settings…". Empty: This Mac, "Speakers appear here as Audiout finds them."

**2 and 15.** Two: a short list. Fifteen: six kept rows, one folded line.

**Trade-offs.** Section and menu repeat the choice; two targets per row.

**Maps to.** `GroupedSectionView` `.card`/`.well`, `DeviceIconWellView`, borderless `NSPopUpButton(pullsDown:)`, small `NSButton`, `SpeakerMixerVisibility`.

**Owner rulings.** Forget… (new, no code). Should new speakers start below, like Bluetooth's Nearby?
