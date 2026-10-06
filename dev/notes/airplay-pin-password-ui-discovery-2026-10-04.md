# AirPlay password and PIN: where the UI would go (discovery, 2026-10-04)

Read-only map. Nothing built. Lines cite this worktree, `audiout-remote` main and `audiout-shared` main.

## What already exists

- The engine reports `.passwordRequired` (`AirPlayEngine/Sources/AirPlayEngine/AirPlayTypes.swift:106-107`, error at `:174-175`).
- The app already keeps it apart from other failures as `ConnectionFailure.Cause.authRequired` (`AudioutCore/Sources/AudioutCore/ConnectionState.swift:43`). Both paths map it: a failed connect (`NativeBackend.swift:3587`) and a live session dying (`NativeBackend.swift:5117-5140`). `AudioutCore/AGENTS.md` makes this a rule: `.passwordRequired` never flattens to `.unknown`.
- Copy today: headline "Password required" (`ConnectionState.swift:99`); the suggestion says a Mac receiver should allow "Anyone on the same network", then "Entering a password here isn't supported yet." (`:120-125`). That sentence has to change when entry ships.
- Both auth paths also set `isAvailable = false` (`NativeBackend.swift:3592`, `:5121-5122`). The speaker is on the network and answering, so this is a decision to revisit: the phone sorts a password-blocked speaker into "Unavailable" because of it.
- `DiagnosisContext.requiresAuth` (`ConnectionState.swift:151-152`, consumed at `ConnectionDiagnostics.swift:134-137`) is never constructed anywhere in `Sources`. It is a leftover from the OwnTone design and does not feed a lock hint today.
- No Keychain code exists in the app. The only mention is a doc comment (`AirPlayEngine.swift:107-111`).
- The engine's identity seed is fresh on every launch: `EngineConfig` defaults `installSeed` to `freshInstallSeed()` (`AirPlayEngine.swift:83`, `:93`) and the app never passes one (`OutputBackend.swift:704`). If the HomeKit-style pairing identity derives from it, a stored PIN key will not survive a relaunch. The engine-validation track should confirm.

## 1. Mac surfaces

### How a speaker is joined, and the states a row shows

- The row's checkbox and a name click both go through `deviceRow(_:didToggleEnabled:for:)` (`AudioutSharedUI/DeviceRowView.swift:55`; name click per `docs/SPEC.md:615`). A greyed Bluetooth row's name click reconnects instead (`DeviceRowView.swift:56-61`).
- Connecting: dashed `rim` ring around the icon, and on the rail a hollow gold node with the line stopping 9 pt short (`DESIGN.md:729-760`; row code at `DeviceRowView.swift:846-858`).
- Failed: solid failure-red ring, and the FEED column draws one `exclamationmark.triangle` pill with no words; the headline rides the tooltip and the spoken value (`DeviceRowView.swift:1262-1276`, `DESIGN.md:712-727`).
- Unavailable: the same glyph-only pill, tooltip "Unavailable" (`DeviceRowView.swift:1217-1233`, `:1277-1287`). Failed outranks unavailable on the Mac.
- Rows that do not host the rail (Groups screen) print "Couldn't connect" or "Unavailable" as a sublabel (`DeviceRowView.swift:1124-1131`).

### Where a lock glyph beside the name fits

- The name sits in a vertical `identityStack`: name, meter, sublabel (`DeviceRowView.swift:364`, built at `:1691-1700`). A glyph on the name line needs either an SF Symbol text attachment on `nameLabel` (`:223`, `:625`) or a small horizontal stack replacing `nameLabel` as the first arranged view.
- Constraint: `AudioutSharedUI/AGENTS.md` says the identity stack yields the Equalizer slot on every row so names truncate alike. An attachment truncates with the name; a separate image view would need the same yield.
- `lock.fill` already means "this Setup step is locked" (`AudioutOnboardingUI/SetupCardView.swift:318`). Different surface, but the same glyph.
- Data needed: the lock has to be known before a join. `NativeDiscovery.classify` reads only the `features` TXT key (`NativeDiscovery.swift:622-631`). The TXT `flags` key carries PIN required (bit 3), password required (bit 7) and one-time pairing required (bit 9) (`airplay.c:184-187`), and raop records can carry `pw=1` (sample at `airplay.c:4047`). A new `Device` field fed from those is the seam; `Device` has no such field today (`Device.swift:104-185`).

### Where join failures surface today

1. Row state: red ring plus the glyph pill (above).
2. An inline diagnosis panel that auto-opens under the row once per failure, with headline, suggestion, "Try again", "Copy details" and a close button (`AudioutPopoverUI/ConnectionDiagnosisView.swift:7-16`, `:102-103`, `:134`). Mounted by `PopoverController.mountDiagnosisPanel` (`PopoverController.swift:3702-3712`), driven off state edges in `handleConnectionTransitions` (`:3573-3600`). "Try again" calls `GroupController.retryConnection(for:)` (`PopoverController.swift:3738-3742`, `GroupController.swift:582`), then `OutputBackend.retryOutput` (`OutputBackend.swift:419`).
3. Telemetry: `airplay:connect_failed` and `airplay:session_failed` with `cause: authRequired` (`NativeBackend.swift:3597-3599`, `:5149-5155`), plus `connection:failed` and `connection:diagnosis_shown`.

No toast exists on the Mac for this.

### Device detail pane (Groups screen)

Four slots: identity, Equalizer, Scenes, About (`AudioutWindowUI/DeviceDetailViewController.swift:14-47`). About holds fact rows: Status, Kind, AirPlay (`:215-228`, values at `:612-616`, `:706-728`). There is no per-device setting with a button in About today. A "Password" fact row with a stock "Forget" button belongs here: the pane is configuration only and owns no playback (`AudioutWindowUI/AGENTS.md`). The row's right-click menu (`DeviceRowView.swift:2254-2273`, today "Equalizer…" and "Align by ear…") is a second door if wanted.

### Existing sheets and prompts

| Prompt | How it is shown | Fit for code entry |
|---|---|---|
| Bluetooth alignment wizard | `panel.presentAsSheet(sheet)` on the popover panel, only when the host window is visible (`PopoverController+BTWizard.swift:60-92`) | Proves a sheet can hang off the popover surface. Too heavy a view to copy |
| Licence sheet | `presentAsSheet` from Settings › General (`GeneralSettingsViewController.swift:510-522`); one text field, Register (gold `ProminentButton`) and Cancel, Return and Escape bound (`LicenseSheetViewController.swift:117-134`) | Closest. A wrong key keeps the sheet open, re-enables the field and prints a result line (`:230-282`). That is the wrong-code retry |
| Companion approval | `NSAlert.runModal()` from `AppDelegate.presentApprovalPrompt` (`AppDelegate.swift:3160-3186`): Allow / Don't Allow, no code | Wrong shape: app-modal, blocks everything, no field |
| Align sheet | Phone only (`SyncSheet`, below). No Mac Align sheet in this worktree | n/a |

### "Unavailable speakers" grouping

There is none on the Mac. The popover splits speakers by transport into "AirPlay Speakers", "Cast Speakers", "Bluetooth Speakers" (`PopoverController.swift:2080-2083`, `deviceSections()` at `:2293-2306`). The Groups sidebar lists every speaker under "Speakers" with an "Unavailable" annotation per row (`SidebarViewController.swift:347-378`, `:973`; `MembershipRowView.swift:166`). The phone is the one with an "Unavailable" section (part 3).

## 2. Rules that constrain this

- Stock AppKit and SF Symbols; custom drawing is a short named list (`DESIGN.md:157-159`, `:517-540`). A code field is a stock `NSSecureTextField` (none used in the app yet) or `NSTextField`.
- Gold is audio state, calls to action, selection and completion (`DESIGN.md:3`, `:172-174`). A lock glyph must not be gold; `labelCool2` is the cool state ink (`Tokens.swift:116`). The sheet's primary button may be gold, like the licence sheet's Register (`AudioutSettingsUI/AGENTS.md`).
- Failure red is fenced to failure: ring, dot and pill (`DESIGN.md:712-760`).
- Anything that opens under a row starts at `PopoverColumnGrid.firstElementLeading`, never in the rail's gutter (`AudioutSharedUI/AGENTS.md`).
- Every `show*()` gates on `HeadlessRuntime.isActive` (`AudioutCore/AGENTS.md`); Guard 9 blocks new on-screen lines in tests.
- Copy: headline short, sentence case, no full stop; suggestion one sentence ending in a full stop (`ConnectionState.swift:90`, `:113`). These strings go to the phone verbatim (part 3), so a change is a two-app change. `DESIGN.md:905-925` names the iPhone app "Audiout Remote" at first mention, "your iPhone" after. `docs/REVIEW-RUBRIC.md` covers comment and naming slop, not UI copy.

## 3. iPhone companion

- Speakers: three state sections "Playing", "Ready", "Unavailable" (`audiout-remote/AudioutRemote/UI/Speakers/SpeakersView.swift:335-346`). `SpeakerSection.of` sends any `!isAvailable` device to Unavailable first (`:82-86`), so today a password-blocked speaker lands there.
- Joining: a tap calls `session.setDeviceSelected` (`UI/Speakers/DeviceRowView.swift:1001-1006`), sent as `setDeviceSelected`.
- Failed join: a `"failed"` row swaps its controls for a failure card: the Mac's headline as sublabel (`DeviceRowView.swift:770`), a "Diagnose" text action that reveals the Mac's suggestion sentence, and a gold "Try again" that sends `retryConnection` (`:713-760`). So the phone already shows "Password required" and the Mac's sentence with no phone change.
- Text entry: one plain `TextField` in the group editor sheet (`UI/Groups/GroupEditorView.swift:127`). No secure field, no code entry.
- Approval: the Mac asks Allow / Don't Allow, no code exchanged. The phone shows "Go to {Mac} and click Allow" with Cancel (`UI/Connect/ConnectGateView.swift:403-410`). That is the precedent for sending the user to the Mac.
- Trap: the row owns its sheet today (`DeviceRowView.swift:480`). A row that changes section is rebuilt as a new view and its sheet dismisses itself (memory note, reference-speaker Align sheet, 2026-09-26). A code sheet must hang off `SpeakersView` with `.sheet(item:)` keyed by device id, like `GroupsView.swift:126`.

### Protocol (`audiout-shared/Sources/AudioutProtocol`)

- `DeviceState.ConnectionInfo` carries `state`, `failureHeadline`, `failureSuggestion` and nothing machine-readable (`CompanionSnapshot.swift:27-35`). The Mac fills it at `CompanionSnapshotBuilder.swift:286-302`.
- A snapshot field plus one command is enough; no new message type:
  - On `ConnectionInfo`: an optional cause string (e.g. `"authRequired"`) and an optional credential kind (`"password"` or `"pin"`). The kind also covers the lock hint before any attempt.
  - One command, e.g. `submitSpeakerCode(id:code:)`, answered by the existing `commandResult(requestID:applied:refusalReason:)` (`CompanionMessage.swift:49`). Precedent: `activateLicenseKey(key:)` already carries a secret from phone to Mac (`CompanionCommand.swift:90-92`, handled at `CompanionCoordinator.swift:272`).
  - "Code rejected" is the next snapshot still failed with the auth cause, or `applied: false` with a reason. For a PIN, `retryConnection` already makes the Mac start pairing, which is what puts the code on the TV.
- Additive fields and a new command do not bump `CompanionProto.version` (`audiout-shared/AGENTS.md:64-70`). Both apps' pins move together.

## 4. Analytics naming

Live names follow `category:object_action`. Nearby ones: `connection:failed` (`kind`, `cause`), `connection:diagnosis_shown`, `connection:retry_clicked`, `airplay:connect_failed`, `airplay:session_failed`, and the licence sheet's `license:enter_sheet_opened` (`source`) and `license:key_submitted` (`outcome`) (`LicenseSheetViewController.swift:263`). The table lives in `audiout-shared/docs/analytics-events.md` (connection rows at `:70-73`, failure rows at `:172-173`).

Proposed, no device names or codes in properties:

- `airplay:code_prompt_shown`: `kind` (`password`, `pin`), `source` (`mac`, `phone`)
- `airplay:code_submitted`: `kind`, `outcome` (`accepted`, `rejected`, `timed_out`)
- `airplay:code_forgotten`: `kind`
- `Telemetry.fail(.airplay, "airplay:pairing_failed", …)` for a pairing that breaks for a reason other than a wrong code; device id in `local` only

## 5. Options

macOS benchmark (from Apple's own behaviour, not checked live here): the system AirPlay menu marks a password-protected receiver with a lock and asks for the password in a dialog; an Apple TV set to require a code shows four digits on the TV while the Mac asks for them in a small modal dialog.

**Mac A: code field inside the diagnosis panel.** When the cause is auth, the panel under the row trades its suggestion for a field and its "Try again" for "Connect". Touches `ConnectionDiagnosisView.swift`, `PopoverController.swift` (`mountDiagnosisPanel`, `retryConnection`), `ConnectionState.swift`, `GroupController.swift`, the backend. Reason: the panel already opens at exactly this moment, under the right row. Against it: the panel height re-fit, the closed-for-this-failure logic, and the gutter rule all have to absorb a text field, and the panel opens for background reconnects too.

**Mac B (recommended): a small sheet on the surface, modelled on the licence sheet.** The diagnosis panel stays; for the auth cause its button reads "Enter Password…" or "Enter Code…" and opens the sheet. A join the user just clicked opens the sheet directly; a background reconnect never does. Wrong code keeps the sheet open with a result line, as `LicenseSheetViewController.swift:266-273` does. Touches a new `AudioutPopoverUI` sheet controller, `PopoverController` (presentation as in `PopoverController+BTWizard.swift:81-83`), `ConnectionDiagnosisView.swift` (button title), `ConnectionState.swift` (cause and copy), `GroupController`/`OutputBackend` (retry with a credential), a Keychain store in Core. Forget lives in the device detail pane's About section. Reason: it matches the macOS dialog, gets Return and Escape for free, and reuses a shipped wrong-entry pattern without bending the row layout.

**Phone (recommended): send the user to the Mac.** The failure card already shows the Mac's headline and suggestion. Once entry exists on the Mac, change the auth suggestion to point at the Mac, matching "Go to {Mac} and click Allow". No phone code and no protocol change. If phone entry is wanted later: the two `ConnectionInfo` fields and one command above, and a sheet presented from `SpeakersView.swift` keyed by device id, never from `DeviceRowView`.
