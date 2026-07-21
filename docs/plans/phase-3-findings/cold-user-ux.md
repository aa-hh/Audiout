# Cold-User UX Clarity Audit — Audiouter (Phase 3 / A2)

Audited as a total stranger who just paid for the app and has never seen its
mental model before. Scope: every flow the task listed, walked as a code
read-through (no live app launch — read-only, no live audio/AirPlay session
started per task rules). Severities: Critical (blocks or silently breaks core
use, or is a hard dead end) / Major (causes real confusion or a support
ticket, but the user can eventually recover) / Minor (a stumble, not a
blocker) / Nit (cosmetic/internal-consistency only).

## Method

Read the repo-root `AGENTS.md` and the `AGENTS.md` nearest each package
touched (`AudiouterCore/`, `AudiouterCore/Sources/Audiouter{SharedUI,
PopoverUI,WindowUI,SettingsUI,App}/`). Read `docs/SPEC.md` §9 (UI contract,
~lines 300–575). Then traced each of the 8 requested flows end-to-end through
the actual `AppKit` construction code (`loadView`/`buildSubviews`/`apply`
methods) and the plain-language copy those methods set as `stringValue`,
`title`, `toolTip`, and menu-item text — i.e., exactly what a mouse-and-eyes
user would see, not what the code comments explain to a future engineer.
`AudiouterOnboardingUI` has no `AGENTS.md` of its own; its contract lives in
`AudiouterApp/AGENTS.md`'s "First-run onboarding" section, which was read in
full. No app process was launched and no audio/AirPlay session was started.

---

## Flow 1 — First launch: onboarding → permissions → skip/deny paths

**[Critical] "Done" never gates on any permission being granted — a stranger can sail through onboarding having granted nothing, with zero warning.**
`OnboardingViewController.makeFooter()` builds `Done` as a plain, always-enabled button (`AudiouterCore/Sources/AudiouterOnboardingUI/OnboardingViewController.swift:290-295`); `doneTapped()` (line 348) calls `onDone()` unconditionally — it never reads `model.audioStatus`/`localNetworkStatus`. `OnboardingWindowController.finish(markComplete:)` (`OnboardingWindowController.swift:103-107`) then unconditionally calls `model.complete()`, permanently marking `AppSettings.hasCompletedSetup = true` regardless of whether any row shows "Allowed," "Denied," or the untouched default. There is no confirmation dialog ("You haven't granted permissions yet — continue anyway?"). A cold user who clicks through without reading each row gets a fully "completed" app that can't discover devices (no Local Network grant) or can't hear anything once connected (no System Audio grant), with no error surfaced at the moment of the mistake.
*Fix direction:* On Done with any row un-granted, show a one-line confirmation ("Some permissions weren't granted — Audiouter may not work until you allow them. Continue / Go back") rather than silently completing.

**[Major] The only recovery path after skipping is buried three clicks deep, and nothing ever points a struggling user to it.**
Re-running the flow requires: popover → gear icon (Settings) → "General" section → "Setup" row → **"Run Setup Again…"** (`AudiouterCore/Sources/AudiouterSettingsUI/GeneralSettingsViewController.swift:42-52`). Nothing in the popover, in a failed-connection diagnosis panel, or anywhere else ever mentions this button or links to it, even when a symptom (no devices ever appear, a connected device plays no sound) is a direct consequence of a skipped permission.
*Fix direction:* surface "Check permissions" as a suggested action from the empty-devices state and from the diagnosis panel when a failure pattern is consistent with a missing grant.

**[Minor] Denying "Local Network" can never show as truly denied — the row is honest but the wording ("Requested") undersells the risk.**
`PermissionRowView.update(status:)` shows `.requested` as a plain gray checkmark + "Requested" (`PermissionRowView.swift:191-198`) because macOS exposes no verify API for Local Network (per `AudiouterCore/AGENTS.md`'s `LocalNetworkPriming` note). A stranger who denied the system prompt sees the same "Requested" as someone who was never asked — no orange/red cue that something may be wrong, only a same-column "Open Settings" button they have no reason to click.
*Fix direction:* acknowledge the ambiguity in the row's detail copy itself (e.g., "We can't always tell if this was granted — check here if speakers don't appear").

## Flow 2 — First speaker connect: popover → toggle → feedback → failure diagnosis

**[Major] On the shipping (native) backend, every real connection failure collapses to one generic message — the polished diagnosis panel never actually diagnoses anything in production.**
`ConnectionFailure.headline`/`.suggestion` (`AudiouterCore/Sources/AudiouterCore/ConnectionState.swift:67-97`) has seven well-written, specific causes ("Didn't respond… power-cycle it," "Not on the network… check it's on the same Wi-Fi," "Connection refused… another device may hold an exclusive session," etc.). But `AudiouterCore/AGENTS.md` states outright: "`NativeBackend` has no `ConnectionDiagnosing` seam — `.failed` cause is always `.unknown`." Confirmed in code: `NativeBackend.swift:2524`, `2603`, `2743` all construct `ConnectionFailure(cause: .unknown)` with no other cause ever produced. So the shipping app's diagnosis panel (`ConnectionDiagnosisView`) always shows "Couldn't connect" / "The connection failed for an unknown reason. Try again, or check the speaker." — never the specific, actionable copy that exists in the codebase and is exercised only by `MockBackend`/the superseded `OwnToneBackend`.
*Fix direction:* this is the highest-leverage gap for a paid release — wiring even a partial `ConnectionDiagnosing` (Bonjour-presence check, TCP probe) into `NativeBackend` would activate copy that already exists and is already tested.

**[Minor] "Connecting" gives no sense of expected duration or a stuck state.**
The on-icon status dot breathes (pulses) during `.connecting`/`.reconnecting` (SPEC.md §9 device-row table) but no row ever shows elapsed time or "still trying…" — a device that hangs in `.connecting` for the full ~10s `timedOut` window (per `ConnectionFailure.Cause.timedOut`) looks identical at second 1 and second 9. A stranger has no way to tell "almost there" from "probably stuck."
*Fix direction:* not urgent given the bounded 10s window, but a short delayed sublabel ("Still connecting…" after ~4s) would help.

## Flow 3 — Understanding the routing model (Main Out / Selected Devices / passthrough / auto-swap)

**[Major] The entire routing model is never explained anywhere in the app — a stranger must reverse-engineer it from trial and error.**
Grepping every popover/shared-UI source file for `toolTip` turns up exactly five uses (`PopoverHeaderView.swift:160`, `AppRowView.swift:374`, `PopoverPanelViewController.swift:399`, `DeviceRowView.swift:287`), none of which explain the Main Out / Selected Devices relationship. The onboarding flow (Flow 1) never mentions routing at all — its reassurance copy is only about the audio-capture permission (`OnboardingViewController.swift:262-264`). There is no first-run coachmark, no "?" affordance, no inline hint anywhere in `PopoverController.swift`. A cold user must independently discover that: (a) the "Devices" card's checkboxes compose a set, (b) the "Audio Out" row's dropdown is a *separate* control that must be pointed at that set (`"Selected Devices (n)"`) or at a saved group, and (c) toggling a checkbox only does something audible while the dropdown targets that set.
*Fix direction:* one short static caption under the System card on first open ("Check devices below, then Audio Out routes there") would close most of this gap without a full tutorial.

**[Major] The auto-swap rule (toggling AirPlay silently un-toggles the Mac) is communicated only by a visual flash — no text, ever.**
`GroupController.setDeviceSelected` performs the auto-swap silently (`AudiouterCore/Sources/AudiouterCore/GroupController.swift:249-256`); the UI's only acknowledgment is `deviceRowsByID[localID]?.flashRow()` (`PopoverController.swift:1269-1272`), a one-time visual flash with no label, toast, or tooltip explaining why the Current Device row just turned off. A stranger who only toggled ONE thing (the speaker) but sees TWO rows change state has no textual explanation anywhere in the popover.
*Fix direction:* the flash is a fine attention cue but needs accompanying text on first occurrence (e.g., a one-line transient caption: "Also turned off: your Mac's speakers").

**[Major] The one user-facing explanation of the local/AirPlay mixing block is a single tooltip with confusing, ungrammatical phrasing.**
When the Mac's own output can't join a mixed Selected-Devices set, the checkbox is disabled and its `toolTip` is set to `GroupController.localMixRefusalReason` (`GroupController.swift:189-190`): `"Synced everywhere-audio arrives with the new engine"`. This sentence has no verb agreement, doesn't name what's currently blocked, and requires the user to already understand "the new engine" (an internal, developer-facing concept) to parse it. It is also only visible on hover — there's no click-through explanation like the AirPlay-1 "coming soon" popover (`PopoverController.swift:1291-1322`) gets. If a refusal somehow still reaches the model layer, `presentRefusal(_:)` (`PopoverController.swift:1275-1281`) writes to **stderr only** — literally invisible to a shipped app's user.
*Fix direction:* rewrite as plain language ("Your Mac and an AirPlay speaker can't play in sync together yet") and give it the same click-to-expand popover treatment as the AirPlay-1 explanation.

**[Minor] The device-selector dropdown's two sections ("Selected Devices (n)" / "Output Groups") are legible but assume the user already made the Devices-card connection above.**
`refreshMainOutRow()` (`PopoverController.swift:743-761`) builds an accurate, well-labeled menu with a live count — clear ONCE the user already understands what "Selected Devices" refers to. Coupled with the Major finding above, this is fine in isolation but compounds the "must infer the model" problem.

## Flow 4 — Group creation (quick-create + manual) and editing

**[Minor] Quick-created groups get an anonymous name ("Group 1," "Group 2") with no prompt or nudge to rename, and no visible link to where renaming happens.**
`PopoverController.saveCurrentSetup()` (`PopoverController.swift:1161-1166`) names a quick-created group `"Group \(controller.groups.count + 1)"` and just calls `rebuild()` — no inline rename field opens, no toast says "Saved as 'Group 1' — rename it in Groups." A stranger has to already know the Groups window exists (see Flow 8 finding on the header icon) to ever discover the rename affordance.
*Fix direction:* a brief post-save confirmation naming the group and pointing at the groups editor would close this.

**[Minor] The Groups window is reachable ONLY through an icon-only header button whose meaning is not self-evident.**
`PopoverHeaderView` wires the groups button to SF Symbol `hifispeaker.and.homepod.mini.badge.plus.fill` (or a fallback) with accessibility label / tooltip "Open Groups editor" (`PopoverHeaderView.swift:65-70, 112-120`) — no visible text label, ever. A cold user scanning the header sees three unlabeled glyphs (speaker-plus icon, gear, power) and must hover each one to learn what they do. This is consistent with the SoundSource-style reference the SPEC cites, so it's a deliberate design choice, not a bug — but it is a real discoverability cost for a first-time user who doesn't yet know to hover icon-only buttons.

Group deletion, renaming (Finder-style commit), and membership editing (`GroupEditorViewController`, `AudiouterCore/Sources/AudiouterWindowUI/GroupEditorViewController.swift`) all read cleanly: delete has a real `NSAlert` confirmation ("Delete this group?", lines 323-330), and the empty state ("No groups yet" + a "New Group" CTA, `MixerWindowController.swift:538-586`) is a good example of what a clear empty state looks like elsewhere in this same app — no dead ends found here.

## Flow 5 — Per-app routing: add → picker → redirect dropdown → zero-routed state

**[Major] The redirect dropdown offers two options that do the exact same thing, with no indication they're equivalent.**
`appDestinations(devices:)` (`PopoverController.swift:1073-1092`) always lists a standalone **"No Redirect"** entry (subtitle "Follows the system audio output") directly above a **"Current Device"** entry showing the Mac's real name (subtitle "Plays locally with its own volume"). But `AudiouterCore/AGENTS.md` states plainly: "`.noRedirect` and `.currentDevice` are capture/engine-equivalent — both mean 'plays locally, stays in the whole-system mix' — they differ only in popover UI state (unset vs. a deliberate choice)." Nothing in the visible UI says these two menu items produce an identical outcome; their subtitles even read as if they describe different behaviors ("follows the system output" vs. "plays locally with its own volume" sound like two different routing strategies to a cold user, not one).
*Fix direction:* either merge them into a single entry, or make the subtitle wording literally identical so a user isn't invited to guess at a difference that isn't there.

**[Minor] Zero-routed-apps empty state is actually good — flag as a positive pattern, not a finding.**
`"No apps routed — use + below to route an app."` (`PopoverController.swift:678`) is plain, has an explicit call to action, and points at the exact control (the ± footer) that fixes it. This is a stronger empty state than the Devices card's (Flow 7) and could be used as the template for fixing that one.

**[Minor] An excluded app silently vanishes from the "+ Add application" picker with no note explaining why.**
`availableAppsForPicker()` filters out both already-routed AND `isAppExcluded` apps with no distinction (`PopoverController.swift:1191-1196`); the picker menu (`makeAddApplicationMenu()`, lines 1220-1237) has no "hidden because excluded in Settings" affordance — a user who excluded an app in Settings ▸ Audio and later goes looking for it in the routing picker just won't find it, with nothing telling them why.

## Flow 6 — Failure states: device disappears mid-stream, connect fails, permission revoked mid-use

Covered substantially by Flow 2's Major finding (NativeBackend always reports `.unknown`) — every mid-stream failure mode collapses to the same generic copy in production regardless of actual cause (device physically vanished vs. Wi-Fi dropped vs. speaker rebooted).

**[Major] No app-level Wi-Fi/network-reachability awareness at all — a Wi-Fi outage looks identical to "no speakers exist."** [confirm-in-G1]
A repo-wide search for `NWPathMonitor`/`Wi-Fi`/`isConnected` inside `AudiouterCore/Sources/AudiouterCore` and the popover/onboarding UI turns up no overall-network-state observer — only the per-device Bonjour/connection machinery. If the user's Wi-Fi drops entirely, the popover has no distinct code path to say so; it would present exactly the same "Looking for devices…" (Flow 7) or generic `.unknown` failure a normal empty network gives. Tagging for live confirmation since this is inferred from an absence, not an explicit negative-path test.
*Fix direction:* a lightweight `NWPathMonitor` check feeding a distinct "No network connection" state in the Devices card would meaningfully cut the most common support question ("why can't it find my speakers").

**[Minor] "Sticky-failed" is a deliberate, well-designed behavior but is entirely undocumented to the user.**
Per `AudiouterCore/AGENTS.md`, a `.failed` device keeps showing its warning even after backend-side cleanup, clearing only on retry or the device fully disappearing. This is good engineering (avoids a warning flickering away when the user didn't act) but the diagnosis panel never says "this will stay here until you retry" — a stranger might assume the app is stuck rather than waiting for their action.

## Flow 7 — Empty / edge states: no devices on network, all devices off, Wi-Fi off

**[Critical] The single most common first-run reality (a network with zero discovered AirPlay devices) shows an indefinite, unexplained "Looking for devices…" with no elaboration, no timeout, and no distinction between "still searching" and "nothing here."**
`PopoverController.rebuild()`: when `locals.isEmpty && airplay.isEmpty`, the Devices card renders exactly one non-interactive placeholder row, `makePlaceholderRow(text: "Looking for devices…")` (`PopoverController.swift:631-633`, placeholder builder at line ~853). There is no elapsed-time cue, no "make sure your speaker and Mac are on the same Wi-Fi" hint, no link to check the Local Network permission (directly relevant if Flow 1's Critical finding applies), and no state that ever says "none found" — the text is identical whether discovery started one second ago or has been running for an hour with genuinely nothing on the network. Given the task's own framing that this is "the most common first-run reality," this is the single highest-impact gap in the audit: it is the FIRST thing many buyers will see after finishing setup, and it offers them nothing to do.
*Fix direction:* after a bounded wait (e.g., 15–20s) swap to a second placeholder state with concrete troubleshooting steps (same Wi-Fi network, Local Network permission, speaker powered on) and a "Run Setup Again…" shortcut.

**[Minor] "All devices off"/unreachable state is only distinguished by the row dimming — no card-level summary.**
Individual off/unavailable devices dim per-row (SPEC.md §9 device-row table), but there's no aggregate message like "3 speakers found, none reachable right now" — a user with several known-but-currently-off speakers sees the same card shape as one with a single live device, just visually quieter.

## Flow 8 — Discoverability of settings, quit, and help

**[Major] Quit is reachable only through a small, icon-only power-glyph button in the popover header — Cmd+Q does nothing, and there is no right-click menu.**
`AudiouterApp/AGENTS.md` states the rule directly: "No main menu. The app is `.accessory` with no `NSMenu` ever assigned — no Edit/Window menu to host standard keyboard commands." Confirmed: `StatusItemController.swift` wires only a left-click action (`wireButtonAction()`, lines 37-42) with no right-click/secondary handler, and a repo-wide search for Cmd+Q handling (`terminate(`, key-equivalent `"q"`, local event monitors) in `AppDelegate.swift` finds nothing. The ONLY quit affordance in the entire app is the unlabeled "power" SF Symbol button in `PopoverHeaderView` (`PopoverHeaderView.swift:76-80`, tooltip "Quit" — text visible only on hover). This breaks one of the most deeply ingrained macOS habits (Cmd+Q) for every new user, and is corroborated by this project's own history: a prior working session needed to fall back to Activity Monitor / Force Quit for exactly this app, precisely because there's no Dock icon and no conventional quit path.
*Fix direction:* at minimum, add a right-click (secondary-click) status-item menu with a "Quit Audiouter" item — the standard macOS menu-bar-extra convention — without requiring a full main menu.

**[Major] Zero in-app Help, About, or version-number surface anywhere.**
A repo-wide search for "About," a Help menu, `CFBundleShortVersionString` usage inside the UI, or any changelog/support link inside `AudiouterCore/Sources/` returns nothing — the version string is written only into `Info.plist` by `scripts/make-app.sh:157-158`, visible solely via Finder "Get Info," never inside the running app. For a paid public release, a buyer troubleshooting an issue (e.g., before contacting support) has no in-app way to confirm which version they're running, read a changelog, or find a support link.
*Fix direction:* add a version string + a "Get Help"/support link somewhere reachable (Settings ▸ General is the natural home, next to "Run Setup Again…").

**[Minor] Settings and Groups are each discoverable only via the same icon-only header cluster as Flow 4/this flow's Quit finding — consistent, but compounds the hover-to-learn cost for a first-time user.**
Three unlabeled buttons (`groupsButton`, `settingsButton`, `quitButton`, `PopoverHeaderView.swift:44-46`) sit side by side with no visible text and no separating affordance beyond spacing; a stranger must hover all three once to build a mental map of the header.

---

## Top 5 by user impact

1. **[Critical]** Onboarding's "Done" never checks whether any permission was actually granted — a stranger can complete setup having granted nothing, with no warning, and the app then fails silently later with no link back to the fix. (`OnboardingViewController.swift:290-295, 348`; `OnboardingWindowController.swift:103-107`)
2. **[Critical]** The empty-network state ("Looking for devices…") is indefinite and unexplained — the most common first-run scenario offers a first-time buyer nothing to do and no way to tell "still searching" from "nothing will ever appear." (`PopoverController.swift:631-633`)
3. **[Major]** On the shipping native backend, every connection failure reports the same generic "Couldn't connect" — the specific, well-written diagnosis copy that exists in the codebase (`ConnectionState.swift:67-97`) never actually reaches a real user, because `NativeBackend` always hardcodes `.unknown` (`NativeBackend.swift:2524, 2603, 2743`).
4. **[Major]** The entire routing model (Main Out, Selected Devices, auto-swap, the local/AirPlay mixing block) is never explained in-app; the one tooltip that touches it is grammatically broken and jargon-laden ("Synced everywhere-audio arrives with the new engine," `GroupController.swift:189-190`), and a real refusal is logged to stderr only (`PopoverController.swift:1275-1281`) — literally invisible to the user.
5. **[Major]** Quit has no Cmd+Q, no right-click menu, and no Dock icon — the only path is a small unlabeled power-glyph button in the popover header (`PopoverHeaderView.swift:76-80`), breaking a deeply ingrained macOS habit; this is not hypothetical — it already tripped up this project's own team during development.
