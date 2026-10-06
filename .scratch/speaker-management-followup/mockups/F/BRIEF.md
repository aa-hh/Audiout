# Direction F: two lists, one button per speaker

**Person and moment.** Someone opens "Manage speakers…" from the Mixer because it lists a speaker they never use, or lacks one they expected. They want to fix that one speaker, then leave.

**The gesture.** The page splits into "In the Mixer" and "Hidden from the Mixer". Each row has one button: Hide moves it down, Show moves it up. Dragging, or selecting several rows, does the same. The top list is the Mixer's list, so the page answers "what will I see" without a preview. The three stored values become position plus one checkbox: Hidden is Hide when not in use; In the Mixer with "Keep when away" ticked is Always; unticked is When available.

**Hardest grill question.** "When available" and unavailable right now: is that speaker in the Mixer? Not at this moment. It still sits in the top list, in cool ink, with "Keep when away" unticked. The checkbox column answers "where did it go when it switched off".

**States.** Unavailable, not connected and missing speakers: cool ink, status in plain words ("Not found on this network"). In use: gold "Playing now"; hiding it says "Playing, stays in the Mixer until it stops". This Mac: ticked, disabled, "Always" instead of a button. Bluetooth denied: unconnected Bluetooth speakers drop out and one line links to Privacy. Empty hidden list: "Nothing hidden…". 15 speakers: one scroll.

**Trade-offs.** The checkbox column costs width and does nothing for hidden rows. Details go through the sidebar, double-click or the right-click menu, not an inline chevron. This page has no forget action; the code has none.

**Mapping.** `NSTableView` with two group rows (`isGroupRow`), drag reorder via `registerForDraggedTypes`, an `NSButton` checkbox column, small rounded `NSButton`s, `NSUndoManager`. Values are `SpeakerMixerVisibility`. Note: link-style `NSButton`.
