# Work order: make the speaker-management suite green (scoped 2026-10-04)

All 7 Guard 4 failures are tests asserting pre-feature behaviour or bypassing the host path. Test-file edits only; NO file under AudioutCore/Sources. Feature stays staged; no git add/commit.

Evidence: DeviceRowView.buildContextMenu (SharedUI/DeviceRowView.swift:2266-2290) appends one separator + host items; PopoverController.speakerVisibilityMenuItems (:3110-3121) = ["Always show in Mixer","Hide from Mixer"] for non-local rows. hasLiveConnection (DeviceRowView.swift:220) treats connected+undiscovered as live (approved Cast rule); MembershipBusTests/FeedColumnTests makeDevice defaults connectionState .connected, so isAvailable:false now builds the live-Cast state. GroupEditorViewController.show(groupID:devices:) (:734-745) uses injected library records and ignores `devices`; GroupRenameFieldTests calls it directly so the gate closes and render never runs (count-only failure, text preserved).

Steps:
1. PopoverEqualizerEntryTests.swift:78 expected → ["Equalizer…", "", "Always show in Mixer", "Hide from Mixer"].
2. Same file :87-88 expected → ["Equalizer…", "Align by ear…", "", "Always show in Mixer", "Hide from Mixer"]; message → "tone first, alignment second, then the host's Mixer visibility actions after one separator".
3. PopoverBTAlignmentUITests.swift:984-985 → the 5-item BT array; :989-991 → ["Equalizer…", "", "Always show in Mixer", "Hide from Mixer"].
4. MembershipBusTests.swift:52 makeDevice(isAvailable:false) → makeDevice(connectionState: .off, isAvailable: false); comment above: "// .off on purpose: a connected-but-undiscovered device is a live Cast session and renders live."
5. Same file :257 same fixture change.
6. FeedColumnTests.swift:139 same fixture change + same comment.
7. Same file :176 same fixture change.
8. GroupRenameFieldTests.swift:296 `editor.show(groupID: group.id, devices: renamed)` → `window.update(devices: renamed)`; replace comment lines 290-291 with "// A real change pushed through the host, so the library and the pane's gate both see it and `render` genuinely runs — this is not a test of the gate." Keep both #expects.

Guard 11: no @Test added/moved, no sentence needed.

Verify (in this worktree):
bash scripts/run-tests.sh --filter 'PopoverEqualizerEntryTests|PopoverBTAlignmentUITests|MembershipBusTests|FeedColumnTests|GroupRenameFieldTests'
Expect exit 0, all five suite names in output, then `git status --short` shows only these five test files changed beyond the staged feature. Executor: haiku/low, run in this worktree (not a fork).

Follow-up tickets (not this PR): show(groupID:devices:) ignores `devices` when a library is injected; hasLiveConnection is not Cast-scoped (backend only produces that state for Cast).
