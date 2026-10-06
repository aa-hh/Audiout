# Direction A: the scene-editor grammar

**Job and audience.** A household user in the Scenes window checks every speaker the app knows and decides which ones the Mixer shows. Visited rarely; nothing here plays sound.

**Thesis.** The page borrows the scene editor's parts: the Scenes page header, captioned rounded sections, and one-line rows with a trailing caption. One section per transport, in Mixer order (This Mac, AirPlay, Cast, Bluetooth), with missing speakers last. The table, its column headers and the seven pop-ups go.

**Focal moment.** The trailing caption on each row ("Always in Mixer", "Hidden from Mixer"). It answers the page's one question per speaker, in the editor's words. "Shown while in use" sits above it when a hidden speaker is playing.

**States.** Normal; rows selected (neutral wash, never gold; the header count becomes "2 selected" plus the bulk pop-up, reading "Mixed" for a mixed set); unavailable and not-connected rows (cool name, status line); missing speaker (no transport invented); Bluetooth denied (explanation row inside the Bluetooth section, with "Open Bluetooth Privacy…" in gold, its call-to-action colour); empty (This Mac section only, "1 speaker").

**Trade-offs.** You can no longer see every choice as a control. Changing one takes a right-click or a bulk selection. Section titles carry the transport, so "Available" and "Connected" drop from rows.

**Maps to.** Header: `GroupsOverviewLayout` header row. Sections: `GroupedSectionView` `.panel`. Icon: `DeviceIconWellView`. Row: `MembershipRowView` without rail or checkbox. Bulk control: stock `NSPopUpButton`. Footer: the editor's footer caption slot in `ContentPaneHostViewController`. Wash: `Tokens.Color.engagedChrome`.
