# Direction J: one list, one detail

**Structure.** The sidebar's speaker rows are the window's only list of speakers. The content area shows the selected speaker, Equalizer first.

**First read, one gesture.** Click a speaker; its Equalizer is on screen, unscrolled, under the name. The Mixer's "Manage speakers…" opens the first speaker; its Equalizer door opens that row's speaker.

**Sidebar: "Your speakers" over "Other speakers".** macOS Bluetooth's words, but the section IS the Show in Mixer choice: Your = When available or Always; Other = Hide when not in use. Right-click › Show in Mixer, or the detail's pop-up, moves a speaker between them, so the grouping teaches the choice instead of adding a rule. "Here now / Away" was rejected: it sorts by something nobody can change. Away speakers stay in place, greyed, like Bluetooth's Not Connected. The stock source-list Hide on the Other header folds it.

**Speakers plate.** Counts only ("7 speakers: 6 yours, 1 other"), then up to three rows, each only when it applies: Bluetooth access off; "Hide speakers not in any scene" (SoundSource's Hide All); "Forget 1 speaker…" for speakers the Mac can't find. It lists no speaker.

**States.** Unavailable: greyed row, Equalizer editable, "Changes apply when it's back". Can't be found: greyed, failure triangle, Forget… on right-click. Hidden but playing: stays in Other, gold "Playing now". Bluetooth denied: plate row, Open Privacy Settings…. Empty: This Mac alone, no Other header. Several selected: one pop-up reading Mixed, no Equalizer.

**Concepts to hold: three.** A speaker, which section it sits in, its Equalizer. Scenes appear only as links.

**Maps to.** `SidebarViewController` (two group headers, multi-select, the Device Row's Show in Mixer menu); `DeviceDetailViewController` reordered, the choice joining About as a pop-up row; `SpeakersOverviewViewController` keeps `setBluetoothAccessExplanation`, drops its table.

**Owner rulings.** Forget (removes the speaker from scenes); what "not in any scene" covers; whether a speaker that can't be found keeps its Equalizer.
