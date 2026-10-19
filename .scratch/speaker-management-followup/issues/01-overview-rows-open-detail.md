# 01 Overview rows open the detail pane
Status: todo

`SpeakersOverviewViewController`: double-click and Return on a row open that speaker's
detail (`MixerWindowController` selects the speaker in the sidebar, same host path the
detail pane's Scenes rows use through `onSelectGroup`). Single click keeps selecting for
bulk. Add a trailing chevron in the identity column. Local Mac row opens Main Audio detail
if that is the existing sidebar behaviour for it, else is excluded. Test: a real
`doubleAction` dispatch selects the sidebar row and swaps content; no routing change.
