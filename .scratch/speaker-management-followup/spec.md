# Speakers overview ↔ detail navigation (follow-up to speaker management)

Decided by Alec 2026-10-04, after the speaker-management work was approved: link the
Speakers overview and the speaker detail pane; land as a separate PR after the
speaker-management PR merges. Direction record stays
`.impeccable/surfaces/audioutpopoverui-popovercontroller-swift-665a05cf.md`.

Problem: in the Scenes tab, scene cards open the scene editor on click, but rows in the
Speakers overview open nothing. The detail pane (per-speaker, from the sidebar) has no
path to the overview. The sidebar "Speakers" entry is drawn as a grey section heading, so
it does not read as a page. The Mixer row context menu offers two of the three visibility
choices.

Scope: navigation and affordance only. No change to what visibility means, no new
visibility state, no playback, connection, or membership side effects.
