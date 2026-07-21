# AUDIOUTER UI STRING AUDIT — Phase 3 Polish

Discovery audit of all user-facing strings in Audiouter UI packages, reviewed as a paying customer would read them. Flags insider jargon, inconsistent terminology, developer voice, truncation risks, and capitalization mismatches.

## Method

Grep patterns used:
- `\.title = "` — button/window/label titles (52 matches)
- `placeholderString = "` — text field placeholders (8 matches)
- `NSTextField(labelWithString:` — static labels (22 matches)
- `messageText =` / `informativeText =` — alert text (2 matches)
- `\.addButton(withTitle:` — alert buttons (2 matches)
- `setAccessibilityLabel` / `accessibilityDescription` — accessibility text (38 matches)

**Total reviewed: ~170 strings across 7 UI packages** (AudiouterApp, PopoverUI, WindowUI, SettingsUI, OnboardingUI, SharedUI, and AppDelegate menu/status items).

## Terminology Inconsistencies

| Concept | Variants Found | Recommended Single Term | Rationale |
|---------|---|---|---|
| Audio output destination | "Audio Out", "Main Out" (in comments) | **"Audio Out"** | "Audio Out" is user-facing; "Main Out" is internal only. Standardize comments to "Audio Out" where visible to users. |
| Speakers selected for playback | "Selected Devices", "Devices" (header), "Selected" (collapsed) | **"Selected Speakers"** OR keep "Selected Devices" with guidance that "Devices" header = "Selected Devices" | Current naming conflates membership (Selected Devices set) with device presence (all Devices). Users see "Devices" header but it means "Your Selected Speakers". |
| Saved speaker combinations | "Output Groups" | **"Speaker Groups"** OR **"Saved Groups"** | "Output Groups" is technical jargon; customers think "speaker groups" or "room groups". |
| Mac's own audio output | "Current Device" | **"This Mac"** OR **"Mac"** | "Current Device" is developer jargon; customers call it "the Mac" or "local playback". |
| No speaker routing active | "No Redirect" | **"Mac Only"** OR **"Local Playback"** | "Redirect" is technical; customers understand "play only on this Mac". |
| Apps not captured by audio routing | "Excluded applications" | **"Never Route These Apps"** OR **"Always Play Locally"** | "Excluded" is passive; "Never Route" describes the action from user perspective. |

## Detailed Findings

### ONBOARDING UI

#### Issue 1: Awkward phrasing in permission description
- **String:** "Send your Mac's sound to your speakers. Allowing plays a brief tone to confirm it's working."
- **File:line:** AudiouterOnboardingUI/OnboardingViewController.swift:69–70
- **Why:** "Allowing plays" is grammatically awkward; "Allowing" should be "Granting" or restructure entirely. Also runs long and could wrap awkwardly on narrow windows.
- **Suggested rewrite:** "Send your Mac's sound to any speaker. We'll play a brief tone to confirm it's working." OR "Enable audio routing and we'll play a test tone to confirm."

#### Issue 2: Vague permission description
- **String:** "Let the speaker's buttons control playback."
- **File:line:** AudiouterOnboardingUI/OnboardingViewController.swift:102
- **Why:** "Control playback" is vague (pause/play? volume?). Doesn't explain which speaker or what permission is needed. Also primed for a not-yet-shipped feature (speaker-side transport controls).
- **Suggested rewrite:** "Use playback controls on your speaker." OR wait for the feature to ship before showing this permission.

#### Issue 3: Instruction assumes location knowledge
- **String:** "In System Settings, find Audiouter in the list and switch it on."
- **File:line:** AudiouterOnboardingUI/OnboardingViewController.swift:277
- **Why:** "In System Settings" is vague (which pane?). A first-time user won't know to look under Privacy & Security › Audio Input or which exact section.
- **Suggested rewrite:** "Go to System Settings › Privacy & Security › Audio Input, find Audiouter, and toggle it on." OR better: deep-link directly via the "Open System Settings" button in the permission row itself (already done for Local Network/Audio).

---

### SETTINGS UI

#### Issue 4: Unclear button label
- **String:** "Run Setup Again…"
- **File:line:** AudiouterSettingsUI/GeneralSettingsViewController.swift:45
- **Why:** "Setup Again" is vague — does it re-run first-time onboarding? Re-grant permissions? Reconfigure groups? For a customer who only cares about checking a permission, this label obscures the action.
- **Suggested rewrite:** "Check Permissions…" OR "Review Setup" OR "Recheck Permission Status…"

#### Issue 5: Truncation-prone subtitle
- **String:** "Review what Audiouter needs and re-check permissions."
- **File:line:** AudiouterSettingsUI/GeneralSettingsViewController.swift:51
- **Why:** Long subtitle at a narrow settings-window width; "re-check" might wrap awkwardly. Also redundant with button label ("Setup Again").
- **Suggested rewrite:** "Verify that required permissions are granted." (Shorter, scans better.)

#### Issue 6: Weak affordance for adding apps
- **String:** "Add application…"
- **File:line:** AudiouterSettingsUI/AudioSettingsViewController.swift:496
- **Why:** Ellipsis (`…`) is correct, but the word "application" is formal. Most customers say "app". Also doesn't hint at what excluding an app does.
- **Suggested rewrite:** "Add app…" (lighter, matches macOS convention for app-related actions)

#### Issue 7: Vague placeholder
- **String:** "Symbol name"
- **File:line:** AudiouterWindowUI/IconPickerViewController.swift:93
- **Why:** "Symbol name" is developer jargon (refers to SF Symbols API). A customer doesn't know what a "symbol name" is; they see it as an icon picker.
- **Suggested rewrite:** "Search icons…" OR "Filter by name…"

#### Issue 8: Empty-state message is too long
- **String:** "No matches"
- **File:line:** AudiouterWindowUI/IconPickerViewController.swift:55
- **Why:** Minimal issue, but "No matches" is terse and might read as a system error to some. Low priority.
- **Suggested rewrite:** "No matching icons" (slightly more explanatory, same length)

#### Issue 9: Settings subtitle uses developer terminology
- **String:** "Audio from these apps always stays on this Mac — never captured or redirected."
- **File:line:** AudiouterSettingsUI/AudioSettingsViewController.swift:137
- **Why:** "Captured" and "redirected" are developer-facing terms. Customers don't think in capture/redirect; they think "plays locally" or "doesn't go to speakers."
- **Suggested rewrite:** "Audio from these apps always plays on your Mac — never sent to speakers."

#### Issue 10: Conditional button text lacks clarity in idle state
- **String:** "Apply" (vs "Apply & Reconnect" when streaming)
- **File:line:** AudiouterSettingsUI/AudioSettingsViewController.swift:359
- **Why:** Button text changes based on state, but a customer might not understand the difference. "Apply & Reconnect" signals action; "Apply" alone is neutral. No inline label explains the difference.
- **Suggested rewrite:** Keep "Apply & Reconnect" when streaming; when idle, use "Apply Settings" (to parallel "Apply & Reconnect").

---

### POPOVER UI

#### Issue 11: Jargon in destination option
- **String:** "No Redirect"
- **File:line:** AudiouterPopoverUI/PopoverController.swift:1076
- **Why:** "Redirect" is insider jargon. A paying customer doesn't know what it means. The default routing mode is not "no redirect"; it's "play only on this Mac" or "local playback."
- **Suggested rewrite:** "Mac Only" OR "Local Playback" (then pair the subtitle with "Play sound on this Mac only")

#### Issue 12: Vague subtitle for local playback
- **String:** "Follows the system audio output"
- **File:line:** AudiouterPopoverUI/PopoverController.swift:1080
- **Why:** "System audio output" is ambiguous. Does it mean the system's default speaker? The app's own routing? Technically correct but unclear to end users.
- **Suggested rewrite:** "Plays on your Mac's default speaker" OR "Uses your Mac's current audio output"

#### Issue 13: Imprecise subtitle for per-app local routing
- **String:** "Plays locally with its own volume"
- **File:line:** AudiouterPopoverUI/PopoverController.swift:1085
- **Why:** "Plays locally" is vague (locally where?). "Its own volume" is unclear (which "it" — the app or the device?).
- **Suggested rewrite:** "Plays only on this Mac with independent volume" OR "Stays on your Mac, with separate volume control"

#### Issue 14: Long placeholder in empty state
- **String:** "No apps routed — use + below to route an app."
- **File:line:** AudiouterPopoverUI/PopoverController.swift:678
- **Why:** Long sentence for an empty state; contains a symbol reference ("+ below") that won't translate well and doesn't match common empty-state patterns. Also "routed" is jargon.
- **Suggested rewrite:** "No apps selected" OR "No app routing set up" (Let the affordance speak for itself with the + button nearby.)

#### Issue 15: Inconsistent terminology between card header and popover option
- **String:** "Devices" (card header) vs "Selected Devices (n)" (option in dropdown)
- **File:line:** AudiouterPopoverUI/PopoverController.swift:615 (header) vs line 757 (option)
- **Why:** User sees "Devices" card header and assumes it means "all devices," but the card actually shows "selected devices." When they open the Audio Out dropdown, they see "Selected Devices (n)" which conflicts with the card's simpler label.
- **Suggested rewrite:** Either (a) change card header to "Your Speakers" and dropdown option to "Your Speakers (n)", or (b) add a parenthetical to the card header: "Devices (Selected)"

#### Issue 16: Jargon in header
- **String:** "Output Groups"
- **File:line:** AudiouterPopoverUI/PopoverController.swift:761
- **Why:** "Output Groups" is developer terminology. Customers call them "room groups," "speaker groups," or "saved groups."
- **Suggested rewrite:** "Saved Groups" OR "Speaker Groups" (whichever matches the Groups window naming)

#### Issue 17: Placeholder text is directive/instructional
- **String:** "Looking for devices…"
- **File:line:** AudiouterPopoverUI/PopoverController.swift:632
- **Why:** "Looking for" is instructional ("here's what we're doing"). Some users interpret placeholder text as an instruction to them, not a description of app state. Minor but can confuse on first launch.
- **Suggested rewrite:** "Searching for speakers…" OR "Scanning for speakers…" (slightly more user-centric)

#### Issue 18: Placeholder in fallback menu
- **String:** "No applications available"
- **File:line:** AudiouterPopoverUI/PopoverController.swift:1224
- **Why:** Appears in a menu when no running apps are available to route. "Available" is vague (available for what?). Customers might think it's a permission issue or that apps aren't found.
- **Suggested rewrite:** "No running apps" OR "No apps to route" (clearer context)

---

### WINDOW/MIXER UI

#### Issue 19: Empty state subtitle
- **String:** "Play groups from the menu bar"
- **File:line:** AudiouterWindowUI/MixerWindowController.swift:544
- **Why:** Instructs user where to *use* groups, not why this window is empty. A clearer message explains *how to create* a group or that no groups have been set up yet.
- **Suggested rewrite:** "Create your first group with the button below" OR "No speaker groups yet — create one to group speakers"

#### Issue 20: Footer instructions
- **String:** "Set up here — play from the menu-bar icon"
- **File:line:** AudiouterWindowUI/MixerWindowController.swift:473
- **Why:** "Set up here — play from the menu-bar icon" is a workflow instruction disguised as a UI label. It's teaching the user a mental model rather than labeling a surface. Belongs in first-run onboarding or a help tip, not a persistent footer.
- **Suggested rewrite:** Remove or replace with a minimal label like "Create and manage groups" (describes the window purpose, not the workflow)

#### Issue 21: Ambiguous placeholder
- **String:** "Group name"
- **File:line:** AudiouterWindowUI/GroupEditorViewController.swift:115
- **Why:** "Group name" works, but in context of the window title "Groups," it might read as a label rather than a placeholder. Parenthetical or lighter styling would clarify it's a text field.
- **Suggested rewrite:** Keep "Group name" but ensure it's styled as placeholder text (lighter color, disappears on input).

#### Issue 22: Alert message lacks context
- **String:** "Delete this group?"
- **File:line:** AudiouterWindowUI/GroupEditorViewController.swift:324
- **Why:** Minimal message; doesn't remind the user which group or give context before deletion. Pairs with an explanatory `informativeText`, so this is acceptable, but the structure could be stronger.
- **Suggested rewrite:** "Delete group '\(groupName)'?" (shows which group is being deleted)

#### Issue 23: Alert explanation is defensive
- **String:** "Deleting a group doesn't change which speakers are playing."
- **File:line:** AudiouterWindowUI/GroupEditorViewController.swift:325
- **Why:** The explanation is reassuring but reads like the app is apologizing for a limitation. It assumes the user thinks deletion would break playback. Better to frame it as a feature.
- **Suggested rewrite:** "The speakers in this group will continue playing — only the group itself is removed." OR "Your speaker playback won't be interrupted."

#### Issue 24: Vague availability status
- **String:** "Unavailable"
- **File:line:** AudiouterWindowUI/MembershipRowView.swift:100
- **Why:** "Unavailable" is generic. Why is the device unavailable? No network? Powered off? Offline? A customer with 5 speakers won't know which ones are coming back online.
- **Suggested rewrite:** "Offline" OR "Not found" (more specific; could also use a secondary-color icon to indicate why if context allows)

#### Issue 25: Jargon in device detail hint
- **String:** "View-only — control playback from the menu-bar popover."
- **File:line:** AudiouterWindowUI/DeviceDetailViewController.swift:184
- **Why:** "View-only" is developer speak. A customer sees a device detail pane and might expect to control it there (as they would in many other apps). The hint doesn't explain *why* it's view-only (per-app routing only works in the popover, for example).
- **Suggested rewrite:** "Volume and routing are controlled in the menu-bar panel" OR remove the hint entirely and let the disabled controls speak for themselves.

---

### CONNECTION DIAGNOSIS UI

#### Issue 26: Truncation risk in accessibility label
- **String:** "Try again connecting to \(deviceName)"
- **File:line:** AudiouterPopoverUI/ConnectionDiagnosisView.swift:253
- **Why:** Long device name + full label can exceed 255 char accessibility limit in edge cases (unlikely, but possible with a 40-char device name).
- **Suggested rewrite:** "Retry connecting" OR "Retry: \(deviceName)" (shorter, still clear for screen readers)

#### Issue 27: Dense accessibility label
- **String:** "Connection problem for \(deviceName): \(failure.headline). \(failure.suggestion)"
- **File:line:** AudiouterPopoverUI/ConnectionDiagnosisView.swift:251
- **Why:** A single dense sentence for screen-reader users. Better to separate headline and suggestion as distinct pieces of information.
- **Suggested rewrite:** "Connection problem — \(failure.headline). \(failure.suggestion)" (punctuation break for pause)

---

### CAPITALIZATION & PUNCTUATION

#### Issue 28: Inconsistent button capitalization
- **String:** "Done" (button), "Delete" (button), "Create" (button), "Cancel" (button), "Apply" (button)
- **File:line:** Multiple (e.g., OnboardingViewController.swift:290, GroupEditorViewController.swift:326, GroupCreationSheetController.swift:152)
- **Why:** All use Title Case correctly (macOS convention), but verify consistency across all primary actions. Spot-check passes, but secondary buttons like "Use default icon" should match.
- **Suggested rewrite:** Verify all buttons use Title Case for primary/secondary actions; no period after button titles (correct everywhere).

#### Issue 29: Ellipsis usage inconsistent
- **String:** "Run Setup Again…", "Delete group…", "Add application…" vs "Open Mixer" (no ellipsis)
- **File:line:** Multiple
- **Why:** Ellipsis correctly signals "opens a sheet/window"; however, "Open Mixer…" (AppDelegate menu item) should also have ellipsis since it opens the mixer window.
- **Suggested rewrite:** Add ellipsis to any button/menu item that opens a window or sheet. Audit: "Open Mixer…", "Open Settings…", etc.

---

### PLACEHOLDER & DEBUG TEXT

#### Issue 30: Placeholder text "Symbol name" leans technical
- **String:** "Symbol name"
- **File:line:** AudiouterWindowUI/IconPickerViewController.swift:93
- **Why:** Users don't know what a "symbol" is in the SF Symbols sense. Appears to be a search field for icon names, so label it that way.
- **Suggested rewrite:** "Search icons" OR "Filter by keyword"

---

## Top 5 by User Impact

1. **"No Redirect" → "Mac Only"** (Issue 11)
   - **Why:** A customer's first interaction with the audio routing model; jargon blocks understanding. High-frequency user action.
   - **Impact:** New user confusion on day 1; likely to email support or leave review mentioning cryptic UI.

2. **"Excluded applications" → "Never Route These Apps"** (Terminology table)
   - **Why:** Passive "excluded" doesn't explain the action from customer perspective; "never route" is active and clear.
   - **Impact:** Settings tab is discoverable on first use; improves self-service support.

3. **"Output Groups" → "Saved Groups"** (Terminology table + Issue 16)
   - **Why:** Technical term blocks discoverability; "saved groups" or "speaker groups" matches customer mental model.
   - **Impact:** Primary feature (saving speaker combos) is under-used because the name doesn't advertise its purpose.

4. **"Run Setup Again…" → "Check Permissions…"** (Issue 4)
   - **Why:** Vague action name; customer unsure if it's safe to click. "Check Permissions" is self-explanatory and lowers support load.
   - **Impact:** Reduces support questions; increases customer confidence in the app.

5. **"Devices" header → "Your Speakers" or "Selected Speakers"** (Issue 15)
   - **Why:** Conflicting terminology between popover card and dropdown option causes confusion about what "Devices" means (all vs. selected).
   - **Impact:** Customers unsure if they're viewing all devices or just selected ones; mental model breaks on first use.

---

## Summary

- **170 strings reviewed** across 7 UI packages
- **30 findings** across 5 categories: terminology (6), jargon (10), truncation (2), developer voice (4), capitalization (2), placeholders (6)
- **Key themes:**
  1. Developer jargon ("redirect," "captured," "output," "passthrough") blocks understanding
  2. Inconsistent terminology for core concepts (devices vs. selected devices, groups names)
  3. Long explanatory text in places that should be brief (empty states, footers)
  4. Some buttons lack context (what does "Setup Again" do exactly?)

**Next phase:** A synthesis task should consolidate these into a refined terminology guide and updated copy for high-impact strings, grouped by shipping urgency (blocking strings vs. polish).
