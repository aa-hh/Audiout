# Direction C: one page, list over inspector

**Job.** A Mac owner with several speakers decides which ones the Mixer shows. Configuration only.

**Thesis.** The overview and the detail become one page. A compact speaker list sits on top; the selected speaker's detail fills the space below it. The Show in Mixer choice lives in the detail, so it is made while looking at that speaker's status and scenes.

**Split: stacked, not side by side.** At 443 pt wide, a list column beside the inspector would put speaker names in three columns at once (sidebar, list, inspector). Stacked keeps both full width: seven 34 pt rows take 238 pt, and the inspector scrolls below a draggable stock divider.

**Focal moment.** Click a row; the three choices appear as one stock segmented control, captioned with what the choice does for this speaker.

**States.** One selected (Bedroom, unavailable, Always). Several selected: the inspector becomes one choice for all, Mixed until picked, This Mac excluded. Missing speaker: no transport, no Equalizer. Bluetooth denied: note with link button above the list. Empty: only This Mac, plus a line saying speakers appear as Audiout finds them.

**Trade-offs.** Versus today: no column headers or per-row pop-ups. Versus a separate detail page: no Back step, but the inspector starts at mid-height, so the Equalizer sits below the fold.

**Maps to.** List: `GroupedSectionView` + `DeviceIconWellView` rows as in `GroupEditorViewController`. Inspector: `DeviceDetailViewController` slots, reused whole. Choice: `NSSegmentedControl`. Split: `NSSplitView`. Note: `NSButton` link style. Sidebar: `SidebarViewController`, unchanged, same selection.
