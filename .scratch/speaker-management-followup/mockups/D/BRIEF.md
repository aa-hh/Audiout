# Direction D: one yes per speaker, sorted by where it is

**Reframe.** The three values hide two questions: "do I want this speaker in my Mixer?" (yes/no) and "keep it there while it's away?", the only difference between When available and Always, and it only changes anything while the speaker is away. So: one switch per row; the away checkbox appears only on away rows that are switched on. A speaker the Mac can't find gets one decision, forget it. No row offers a choice that changes nothing now (Principles 1, 2).

**Terms.** *Here now* = available or connected. *Away* = known, unavailable or not connected. *Can't be found* = today's Missing speaker. *In Mixer* on = When available; off = Hide when not in use; on + *Keep in the Mixer while away* = Always. Section labels are chrome; every control reads in plain speech.

**First read.** "5 of 7 in the Mixer", then Here now on plain ground, Away and Can't be found in `.well` recesses (the recess means out of reach).

**The one interaction.** Flip a switch. Bulk: select rows, Space flips all. Right-click: In Mixer, Keep while away, Speaker settings…, Forget….

**States.** Hidden but playing: switch off, gold caption "Playing, so it stays in the Mixer until it stops". Away: cool ink. Can't be found: scene count + **Forget…**. Bluetooth denied: note inside Away + **Open Privacy Settings…**. Empty: This Mac alone + "Speakers appear here as Audiout finds them."

**Refuses.** Column headers, pop-ups, transport sections, chevrons (sidebar opens detail), last-seen times (nothing stores them).

**Trade-offs.** Always on a speaker that is here now moves to the context menu and detail. **Forget…** is new behaviour (leaves scenes): owner ruling needed.

**Maps to.** `NSTableView`, `NSSwitch` `.small`, checkbox `NSButton`, `GroupedSectionView` `.well`, `GroupsOverviewLayout` header row, `setBluetoothAccessExplanation`, `SpeakerMixerVisibility` unchanged.
