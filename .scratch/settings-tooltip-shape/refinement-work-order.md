# Settings refinement work order

Apply to this worktree's current uncommitted changes. Preserve the native `HelpButton` implementation and its focus repair. Preserve every retained explanation verbatim, including live updates. Do not restore subtitles. No changes to backends, settings persistence, transport, licence policy, or shared default row layout.

## Findings

- Advanced has an unconditional second row. `AudioSettingsViewController.swift:595-619` creates a 20 pt status view, wraps it in `SettingsPane.makeLaneRow` (9 pt above and below, `SettingsPane.swift:95-105`), and appends it even though its label starts hidden. `makeCard` records that wrapper as a visible row (`SettingsPane.swift:85`), so `GroupedSectionView.swift:156-180` draws its divider. Hiding the label cannot remove the 38 pt wrapper.
- Connection-volume truncation is explicit. `ListRowView.swift:92` chooses `.byTruncatingTail`; its `layout()` only measures the caption (`:224-230`). The volume accessory contains a 160 pt slider, 56 pt value and 8 pt gap (`AudioSettingsViewController.swift:249-259`), leaving limited space for the title and help button. The row already centers its text and accessory vertically (`ListRowView.swift:135,165`).
- The empty-app card has one Add button containing a `ListRowView` pinned on all four sides (`AudioSettingsViewController.swift:763-782`). A row already has a 44 pt minimum and a low-priority pull toward its smallest height (`ListRowView.swift:134,185-187`); the card adds 6 pt above and below (`SettingsPane.swift:77-80`, `GroupedSectionView.swift:100`). Source alone does not establish which native sizing constraint produces the screenshot's excess height. Do not describe the button's intrinsic size as a confirmed cause. Measure first as specified below.
- The Settings host pins the document to the pane, without requiring the document to fill the viewport (`SettingsRootViewController.swift:238-240,260-265`). Avoid changing the scroll host to fix a local Add row.

All line numbers refer to source inspected before these edits. Source paths below are relative to `AudioutCore/Sources`; test paths are relative to `AudioutCore/Tests/AudioutCoreTests`.

## Help decisions

| Title | Decision | Reason and source |
|---|---|---|
| Launch at login | Remove | “Open Audiout automatically when you log in” repeats the title. Keep its separate permission warning. `AudioutSettingsUI/GeneralSettingsViewController.swift:103-106`. |
| Reconnect last speakers when Audiout starts | Remove | On describes the title; off describes starting without reconnecting. No separate consequence is lost. Remove the unused help writer, field and test hook. `GeneralSettingsViewController.swift:128-131,201-210,322-324`. |
| Use Audiout's Touch Bar controls | Keep | Explains that volume keys control speakers instead of the Mac during speaker playback. `GeneralSettingsViewController.swift:157-159`. |
| Share anonymous usage statistics | Keep | Specifies transmitted information and the no-data state. `GeneralSettingsViewController.swift:215-226`. |
| Allow control from iPhone on this network | Keep | Includes room timing measurement, which the title does not explain. `RemoteSettingsViewController.swift:130-131`. |
| Get Audiout Remote for iPhone | Remove | The visible QR code and Open address button already provide both actions. Preserve both and their conditional visibility. `RemoteSettingsViewController.swift:179-209`. |
| Theme | Remove | System, Light and Dark choices provide the explanation. `AppearanceSettingsViewController.swift:75-84`. |
| Accent | Remove | Full gold and Subtle choices identify the effect. Explicit owner example. Remove the help field/update/test hook; preserve radio selection and token updates. `AppearanceSettingsViewController.swift:52,96,128-144,232-235`. |
| Apps that stay on this Mac | Remove | Help repeats the title's destination rule. `AudioSettingsViewController.swift:194-196`. |
| Volume when connecting a speaker | Keep | Explains that each speaker's slider takes over after connecting. `AudioSettingsViewController.swift:273-282`. |
| Restore Mac audio if speakers don't reconnect | Keep | Explains wake timing and continued silence when Never is selected. `AudioSettingsViewController.swift:373-378`. |
| Keep Bluetooth speakers streaming during pauses | Keep | Explains the silent stream and loss of sync when disabled. `AudioSettingsViewController.swift:413-419`. |
| Audio buffer | Keep | Explains the delay/dropout tradeoff and reconnection cost. `AudioSettingsViewController.swift:627-634`. |
| License | Keep | Explains the server check and data sent. Keep existing visibility conditions. `LicenseSettingsViewController.swift:22,272-273`. |

Eight help groups remain. Existing titles without explanations gain none. Native full-title hover text used for truncated titles is separate from the explanatory help buttons.

## Track A: Audio layout and shared row wrapping

Model: `gpt-6.1-sol`, high effort. The native layout measurements and changing status-row membership need careful implementation and observed geometry checks.

Ownership: `AudioutSettingsUI/AudioSettingsViewController.swift`, `AudioutSharedUI/ListRowView.swift`, `Tests/AudioutCoreTests/HelpButtonTests.swift`, `Tests/AudioutCoreTests/AudioSettingsLatencyTests.swift`. `SettingsPane.swift` is available only if the measurement establishes a Settings-wide card-sizing defect; explain evidence before changing it. No edits to `GroupedSectionView`, the scroll host, HelpButton, or other panes. Other agents are editing this worktree; preserve their changes.

1. Extend an existing Audio test suite with a defect-naming geometry case before fixing the empty card. Mount the real Audio pane at the Settings host width in an invisible borderless window, using the existing test pattern in `HelpButtonTests.swift:173-185`. Locate the Add button through its accessibility label and inspect its nested ListRow, card and stack. Compare actual and fitted heights with an ordinary one-row card at the same width. Capture diagnostic values in assertion messages. Cover initial empty, add one excluded app, remove it, and reopen the pane. The empty card should contain one compact row plus existing card padding, and removal must return to its initial height. Determine which constraint or wrapper causes extra height and make the smallest local correction. Do not force every Settings card to a fixed height or change shared row minimums.
2. Add a default-off title-wrapping option to `ListRowView`, with a two-line cap when enabled. Opt in only the connection-volume row for this request. Use word wrapping and supply `preferredMaxLayoutWidth` from the title's actual allotted width, excluding its help button and gap. Default callers retain truncation. Keep help adjacent to the label, controls at their current sizes and trailing edge, and both help and volume controls centered against the two-line title. No smaller font, shorter title, narrower slider, restored caption, or wider Settings pane. Extend `HelpButtonTests` with real fitted title-height and accessory-center assertions at the actual Audio card width; verify the full title fits two lines and does not overlap help or controls. Existing default-truncation/help-position and spanning-caption cases still pass. Check that changing help text does not shift the geometry.
3. Retain the Advanced card tuple and status wrapper as needed. Initially mount only the buffer row. Mount the status wrapper when Reconnecting or a result is visible, and unmount it when feedback clears. Update `box.rows` from arranged rows whenever membership changes and call the existing fitted-height update. Follow General's existing mount/unmount pattern, because hiding a shown stack child retains height (`GeneralSettingsViewController.swift:35-37`; folder AGENTS). Do not hide the entire card or remove status messages. Leave the forced-launch-option warning as a visible second row. Preserve the existing 2.5-second dismissal policy, cancellation behavior, setting application and all exact status strings. The dismissal callback must remove the wrapper as well as clear label visibility. `FoldingClipView` releases its fixed height after expansion (`FoldingClipView.swift:55-70`), so expanded content can resize without a shared folding change.
4. Extend existing `AudioSettingsLatencyTests` assertions for initial one-row card, in-progress two-row card, success/partial result visibility, and clearing back to one row through the existing selection path. `test_selectLatencyOption` calls `clearTransientStatus` before its current-value no-op (`AudioSettingsViewController.swift:648-655,699-704,976-982`), so that path tests removal without waiting for wall time. Preserve override coverage. Use deterministic async coordination if observing the in-progress state; no sleeps.
5. Remove the Apps that stay on this Mac help according to the table. Do not replace it with an inline note.

The parent reports that this older branch lacks `scripts/real-time-tests.sh`; inspect affected existing tests directly under the repository's real-time-test rule rather than copying a newer script into this change. Keep existing status timing unchanged. Run scoped tests with `scripts/run-tests.sh`, which selects the configured remote capacity. The parent owns the combined verification run; report exact command, output path, results, measured root cause, and any unresolved visual check.

## Track B: Remove redundant help and update the inventory

Model: `gpt-6.1-sol`, medium effort. Decisions are fixed above; work is removal plus preserving existing callbacks and test coverage.

Ownership: `AudioutSettingsUI/GeneralSettingsViewController.swift`, `AppearanceSettingsViewController.swift`, `RemoteSettingsViewController.swift`, `Tests/AudioutCoreTests/SettingsRootViewControllerTests.swift`, `SettingsAccentAndHintsTests.swift`, and root `DESIGN.md`. Other agents are editing this worktree; preserve their changes. No Audio, shared row, HelpButton or licence edits.

1. Remove help for Launch at login, Reconnect last speakers, Theme, Accent and Get Audiout Remote. Restore plain existing titles using `SettingsPane.makeSectionTitle(_:)` or the existing label; preserve their text. Delete fields/helpers/test hooks used only by removed help. Search all references first. Keep reconnect persistence and analytics, theme choice, accent selection/token update/callbacks, Remote invitation/link/QR gates, statistics help and permission warnings.
2. Update the existing title inventory in `SettingsRootViewControllerTests.swift:68-113` to assert the six removed titles have no HelpButton and no restored inline explanation, including the Audio section title Track A removes. Preserve checks for all retained groups and live text. Update the Remote conditional test at `:116-141` to observe the invitation's actual button or row presence, retaining toggle and licence checks without requiring deleted help.
3. Replace the removed Accent hint test (`SettingsAccentAndHintsTests.swift:120-130`) with absence assertions in the inventory; do not invent a second suite. Preserve existing accent behavior tests. Update the reconnect test at `:272-284` to assert persistence and actual switch state, removing deleted help-hook assertions. Do not replace a real outcome assertion with a self-comparison.
4. Update DESIGN.md's Settings explanation description (`:651` onward) and ListRow description (`:1304` onward) to reflect eight retained help groups, compact empty app card, temporary buffer feedback row and opt-in two-line connection title. Describe the implemented result after checking Track A's diff. Do not record plans as shipped behavior, mirror instructions into AGENTS.md, or change historical briefs.

Run relevant existing tests through `scripts/run-tests.sh`. Report removed groups, preserved behaviors, exact verification output and unresolved issues. Coordinate with Track A before a combined test run.

## Acceptance

The parent reviews both diffs and combined test output, then inspects a fresh preview at the real Settings width. Verify the empty app card before/after adding and removing an app, Advanced with no feedback and with a visible result, two-line volume title and centered controls, all six absent help buttons, retained help on the other eight groups, and unchanged warnings/current states. Inspect light and dark appearance; tests do not establish native appearance. No physical audio claim follows from these UI checks. Do not regenerate snapshot goldens.

No product decision remains unresolved. The empty-card constraint responsible remains a measured investigation for Track A; the work order deliberately does not assert a source cause that has not been observed. This scope pass ran no tests or builds and edited only this work order.
