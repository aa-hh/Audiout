# Audiout macOS — production hardening audit (failure & edge matrix)

Read-only sweep of `AudioutApp`, `AudioutPopoverUI`, `AudioutWindowUI`, `AudioutSettingsUI`,
`AudioutOnboardingUI`, `AudioutSharedUI` and the user-visible edges of `AudioutCore`.
26 findings: **1 P0, 5 P1, 10 P2, 10 P3.** Every claim below is cited to a line I read.

---

## Verdict

The *machinery* of honest failure handling in this app is genuinely good — better than most
shipping Mac apps. There is a real connection state machine, a taxonomy of failure causes with
plain-speech headline + suggestion copy authored on the model type, a precedence-resolved banner
slot, a silence watchdog that falls back to local playback, versioned atomic persistence with
newer-schema tolerance and clamped decode, zero-CPU-at-rest meters, correct `makeBackend()`
defaulting, and no debug UI reachable by click.

The problem is that **several of the best pieces are not connected to anything.** The
capture-engine failure message is written, documented as "UI-renderable", and referenced by zero
lines of UI code — a dead tap retries forever behind rows that still read "Connected". The
`ConnectionFailure.Cause` taxonomy has nine well-written causes and the *shipping* backend can
only ever produce three of them, so a speaker that vanishes off the network — the single most
common real-world failure, for which perfect copy already exists — tells the user "the connection
failed for an unknown reason". The diagnosis engine (`ConnectionDiagnosing`) is wired only to the
non-shipping OwnTone backend. And "Copy Details" is permanently disabled on every AirPlay failure
because `detail` is never populated on that path, so a paying user has no evidence to send anyone.

Above that sits the ambient problem: **the menu bar has no failure state.** Every failure surface
in this app lives inside the popover. A small venue running this all day (a named target audience)
gets a filled glyph turning into an outline glyph — which reads as "idle", not "your speakers
died" — and nothing else. There are no user notifications anywhere in the codebase.

Two more things must not ship as they are: the About pane renders the literal string
`TODO(Alec): add a support email or contact link` and its "View Source Code…" button opens
`https://example.com/TODO-audiout-source` (a paid binary with a GPL source-availability
obligation); and a corrupt store file silently discards the user's saved groups and is then
overwritten by the next save, permanently.

Long-running hygiene and release hygiene are, by contrast, in good shape and mostly need no work.

---

## 1. Error surfacing

### P1 — Capture-engine failure has no user-visible state at all
**Location:** `AudioutCore/Sources/AudioutCore/NativeCaptureCoordinator.swift:2662-2679`,
`AudioutCore/Sources/AudioutCore/NativeBackend.swift:5026-5060`,
`AudioutCore/Sources/AudioutApp/AppDelegate.swift:1693-1729`

`NativeCaptureError.userMessage` is documented as *"A human-readable, UI-renderable description of
the failure and its remedy"* and carries five good strings. **No UI target references
`NativeCaptureError` anywhere** (grep across all six UI targets: zero hits). The only consumer,
`handleCaptureCoordinatorStateChange`, does exactly one thing with `.failed`: schedule a
capped-exponential retry (`2 → 4 → 8 → 10 → 10 …` forever). There is no `BackendEvent` case for a
capture failure — the exhaustive `describe(_ event:)` switch in `AppDelegate.swift:1693-1729`
enumerates all fifteen event cases and none of them concerns capture.

**Impact:** the tap dies (TCC revoked mid-session, the aggregate device torn out, a bad format
read). The device rows still say **Connected**, the menu-bar glyph still says **streaming**, the
silence watchdog does not arm (it keys off `connectionState`, not capture health — see
`NativeBackend.swift:8420-8425`), and no sound comes out of any speaker. Forever, silently. This is
the single worst "UI never lies" violation in the app.

Worse for `.osUnsupported`, which is explicitly non-retryable (`NativeCaptureCoordinator.swift:2657`):
capture is permanently dead with no retry *and* no message.

**Recommendation:** add a `BackendEvent.captureFailed(message:retrying:)`, emit it from
`handleCaptureCoordinatorStateChange`, and render `userMessage` in the popover's existing note slot
(`PopoverController.resolvedSystemAirPlayNote`) at `.warning` severity, above the routing-blocked
note. The banner and its precedence machinery already exist; this is a wiring job.

### P1 — The shipping backend flattens almost every AirPlay failure to "unknown reason"
**Location:** `AudioutCore/Sources/AudioutCore/NativeBackend.swift:6081-6088`, `7911-7932`;
`AudioutCore/Sources/AudioutCore/OwnToneBackend.swift:886`

`ConnectionFailure.Cause` defines twelve causes with individually-authored plain-speech copy
(`ConnectionState.swift:94-143`). Grepping every cause construction in `NativeBackend.swift` gives
the complete produced set: `.authRequired`, `.timingUnavailable`, `.notPaired` (Bluetooth),
`.castAppUnavailable`/`.castConnectionFailed`/`.timedOut`/`.droppedMidStream` (Cast only), and
`.unknown`. **`.vanished`, `.notResponding` and `.refusedOrBusy` are never produced by the shipping
backend at all**, and `.droppedMidStream`/`.timedOut` only on the Cast path.

The `ConnectionDiagnosing` seam that exists to replace a first-guess with real evidence is wired in
`makeBackend` **only on the `.ownTone` arm** (`OwnToneBackend.swift:886`:
`backend.diagnostics = NetworkConnectionDiagnostics()`). The `.native` arm sets no diagnostics.

The code even records the cost of this: `NativeBackend.swift:7925-7928` — *"live 2026-08-06: an
auth-blocked receiver was debugged blind because the panel said 'failed for an unknown reason'
while the engine knew it wanted a password."* That one case was fixed; the general case was not.

**Impact:** a paying user's speaker refuses, times out, or drops mid-song and the diagnosis panel
says "Couldn't connect — The connection failed for an unknown reason. Try again, or check the
speaker." The suggestion copy that would actually help them is written, tested-quality, and
unreachable.

**Recommendation:** map the engine's failure reasons onto the existing causes at the two
`applyEngineState`/`convergeDevice` catch sites; or port `NetworkConnectionDiagnostics` (Bonjour
presence + TCP probe — it depends on nothing OwnTone-specific) onto the native backend and set
`diagnostics` on the `.native` arm.

### P1 — A speaker that vanishes from the network reports "unknown reason"
**Location:** `AudioutCore/Sources/AudioutCore/NativeBackend.swift:8186`

```swift
result.connectionState = .failed(ConnectionFailure(cause: .unknown))
```

The surrounding comment says exactly what happened: *"Sticky-AP2 device that went OFFLINE (lost its
`_airplay._tcp` advert…) Surface a resting `.failed` dot so it reads as 'went away, click to retry'"*.
`.vanished` exists two files away with the copy this case wants verbatim: *"The speaker is no longer
visible on the network. Check that it's powered on and on the same Wi-Fi, then try again."*
(`ConnectionState.swift:116-117`).

**Impact:** the most common household failure — a speaker unplugged, rebooted, or knocked off Wi-Fi
— gets the least useful message in the app, when the right one is a one-word change.

**Recommendation:** `cause: .vanished` at line 8186. This is a one-token fix with the highest
value-per-character in the report.

### P1 — Nothing outside the popover ever signals a failure
**Location:** `AudioutCore/Sources/AudioutSharedUI/MenuBarStatus.swift:28-44`,
`AudioutCore/Sources/AudioutApp/StatusItemController.swift:117-135`

`MenuBarStatus` has exactly two states: streaming (filled glyph) and not (outline). There is no
failure, attention, or degraded state, and the controller only ever renders those two symbols.
Grep for `UNUserNotification`/`NSUserNotification` across the whole repo: zero hits. The
silence-fallback banner (`PopoverController.swift:968`) and the diagnosis panels only exist inside
the panel, and `PopoverController.setLocalFallbackActive` explicitly does nothing visible unless
`isEffectivelyShown` (line 979).

**Impact:** PRODUCT.md names "small venues, offices, retail, studios — one Mac driving multi-room
audio all day; uptime and unattended reliability matter more than tinkering" as a target audience.
For that user the app is silent about its own failure by construction: a speaker drops at 11am and
they find out when a customer mentions it. The state change they *do* see — filled glyph →
outline glyph — is the same thing the app shows when nothing is playing, so it reads as normal.

**Recommendation:** a third menu-bar symbol state (e.g. `exclamationmark.triangle` badged, or the
existing routing-dot affordance repurposed) driven off "any desired device is `.failed`", plus an
opt-in local notification for a mid-playback drop. Both are additive to existing plumbing.

### P2 — "Copy Details" is permanently disabled on every AirPlay failure
**Location:** `AudioutCore/Sources/AudioutPopoverUI/ConnectionDiagnosisView.swift:102`
(`copyDetailsButton.isEnabled = failure.detail != nil`); `NativeBackend.swift:6081-6088`, `7929-7931`

Every AirPlay `ConnectionFailure` on the native path is constructed without a `detail`. Only the
Cast arm populates it (`NativeBackend.swift:3467-3478`).

**Impact:** the one affordance designed to give a stuck user something to send to support is a
greyed-out button whenever they most need it. With no support address either (see P0 below), a
failing user has literally no exit.

**Recommendation:** populate `detail` with the engine error's `String(describing:)` at the
`convergeDevice` catch site and the timeout path — the exact text is already discarded there.

### P3 — Jargon carrying a decision in the Cast failure copy
**Location:** `AudioutCore/Sources/AudioutCore/ConnectionState.swift:136-137`

*"This receiver can't run the Default Media Receiver — some software receivers don't support it.
Try a different Cast device."* "Default Media Receiver" is a Google Cast internal app name, and the
sentence asks the user to act on it. Everywhere else this app is exemplary about this — "Speaker
Sync" instead of "PTP helper" (`OnboardingViewController.swift:1419-1421`), the takeover strip's
explicit *"never 'PTP'/'bind'/'ports 319/320'"* rule (`PopoverController.swift:1148`).

**Recommendation:** "This receiver can't play a stream from Audiout — some software receivers
don't support it. Try a different Cast device."

---

## 2. "The UI never lies"

### P2 — Settings claims "Speakers reconnected" without checking
**Location:** `AudioutCore/Sources/AudioutSettingsUI/AudioSettingsViewController.swift:680-687`

```swift
await latency.apply(target)
…
applyStatusLabel.stringValue = wasStreaming ? "Speakers reconnected" : "Applied"
```

`LatencySettingModel.apply` is `@MainActor (Int) async -> Void` — it returns no success signal
(line 26) — and the backend it calls documents the re-add as *"best-effort, D4"*
(`NativeBackend.swift:6472`). AppDelegate's own comment concedes the same: *"a partial reconnect
failure must not lose the chosen setting"* (`AppDelegate.swift:1334`).

**Impact:** the user changes the buffer *because* they're having dropouts, the reconnect fails,
and the pane tells them their speakers came back. A positive factual claim about hardware the app
did not verify.

**Recommendation:** make `apply` return the reconnected/expected counts; say "Speakers
reconnected", "Some speakers didn't reconnect — check the mixer", or "Applied" accordingly.

### P2 — Unbounded optimistic volume echo on the shipping backend
**Location:** `AudioutCore/Sources/AudioutCore/NativeBackend.swift:2409-2416` (echo), `8360-8372` (push)

`applyLocal` writes the new level to the UI immediately, then `issueVolumePush` does
`try? await engine.setVolume(outputID, engineValue)` — the error is discarded and nothing
reconciles. Unlike `OwnToneBackend`, which explicitly says *"the next poll reconciles with
OwnTone's truth"* (`OwnToneBackend.swift:294`), the native backend has no poll loop by design
(`NativeBackend.swift:8398-8406`: *"the engine's completions and state-stream transitions ARE
ground truth"*).

**Impact:** a dropped `setVolume` leaves the slider showing a level the speaker never received,
with no bound and no correction. In a product whose positioning is "the mixer for your house",
the fader lying is the worst possible lie.

**Recommendation:** on a `setVolume` throw, re-emit the last confirmed level for that device (the
`volumePending`/`volumeInFlight` bookkeeping is already there to hang it on).

### P2 — Group mutations are applied to the model before persistence, with no rollback
**Location:** `AudioutCore/Sources/AudioutCore/GroupController.swift:558-566`, `628-633`

```swift
if let index = groups.firstIndex(...) { groups[index] = group } else { groups.append(group) }
try store.save(groups)
```

The in-memory array is mutated first; a throwing `save` leaves the change live in memory. The
editor's `saveOrReport` (`GroupEditorViewController.swift:681-691`) does the honest thing — it
re-renders from the model and alerts — but *the model already contains the failed change*, so the
pane repaints showing the edit as applied while the alert says it wasn't. The change then
disappears at next launch.

**Recommendation:** snapshot `groups`, mutate, save, and restore the snapshot in a `catch` before
rethrowing. Same for `deleteGroup`.

### P2 — Group-creation sheet swallows a failed save
**Location:** `AudioutCore/Sources/AudioutWindowUI/GroupCreationSheetController.swift:380-383`

```swift
guard let result = try? groupController.createGroup(...) else { return }
```

A bare `return`: the sheet stays open, nothing is reported, `onComplete` never fires. The Create
button appears to do nothing at all.

**Recommendation:** reuse `GroupEditorViewController.presentPersistFailureAlert`'s pattern — that
file already models this correctly.

### P2 — "Save Selected Devices as group" swallows a failed save
**Location:** `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:3190`

```swift
_ = try? controller.saveCurrentSetupAsGroup(name: name)
rebuild()
```

Failure is discarded and the popover rebuilds without the group, with no explanation.

### P3 — License check has no explicit timeout; the sheet is dead for up to a minute
**Location:** `AudioutCore/Sources/AudioutSettingsUI/LicenseSheetViewController.swift:189-195`;
`AudioutCore/Sources/AudioutCore/LicenseValidator.swift:53-56`

`registerTapped` disables the key field and Register button and shows "Checking…", then waits on
`LicenseValidator.validate`. The `URLRequest` sets no `timeoutIntervalForRequest`, so it inherits
`URLSession`'s 60 s default. Cancel does stay enabled (a real mitigation), and the late completion
is harmless because `finish()` nils `onComplete` — but "Checking…" can sit for a minute.

**Recommendation:** `request.timeoutIntervalForRequest = 10` in `LicenseValidator`. The soft-check
design already treats "no answer" as benign, so a short timeout costs nothing.

---

## 3. Data safety

### P1 — A corrupt store file silently discards user data, then overwrites it
**Location:** `AudioutCore/Sources/AudioutCore/GroupController.swift:144`;
`AudioutSharedUI/DeviceIcon.swift:114,118`; `NativeBackend.swift:1473,1476,1479,1483`;
`AppRoutingController.swift:58`; `ExcludedAppsController.swift:31`

Every store follows the same pair:

```swift
self.groups = loadPersisted ? ((try? store.load()) ?? []) : []   // corrupt file → silently []
…
try store.save(groups)                                            // atomic overwrite of that file
```

`GroupStore.load()` is careful and correct — a *newer-schema* file returns `[]` deliberately, and a
genuinely corrupt one **throws**, with the doc comment saying *"that's a real corruption we don't
want to hide"* (`GroupStore.swift:113-115`). But the one production caller hides it with `try?`,
and the next save writes over the file with an atomic replace. The evidence is gone.

**Impact:** a truncated write (power loss, disk full mid-write, an iCloud/backup restore glitch)
costs the user every saved group, every per-app route, every device EQ, every Bluetooth trim — with
no message, no recovery, and no file left to salvage. For a product whose value is "saved groups
you switch to in two clicks", this is the data-loss case that matters.

**Recommendation:** in each store's `load()`, on a decode failure rename the file to
`<name>.corrupt-<timestamp>.json` before returning empty, and surface one banner. ~6 lines in one
place if the stores share a helper.

### P2 — Write failures (disk full, permissions) are silently swallowed
**Location:** `GroupController.swift:221`, `AppRoutingController.swift:58`,
`NativeBackend.swift:9433`, `9595`, `9703-9704`, `ExcludedAppsController.swift:31`,
`DeviceIcon.swift:118`

All `try? store.save(...)`. Routing state, per-app routes, Bluetooth trims, dismissed alignment
prompts, excluded apps and device icons all fail to persist without a word. The one path that
*does* report (`GroupEditorViewController.saveOrReport`) proves the team's own standard here.

**Impact:** the user tunes their setup on a full disk, quits, and everything is back to defaults
next launch with no idea why.

**Positive:** the store layer itself is well built — every store (`GroupStore`, `AppRouteStore`,
`RoutingStore`, `BTTrimStore`, `DeviceEQStore`, `ExcludedAppsStore`, `DeviceIconStore`) uses a
versioned `Envelope`, tolerates a newer `schemaVersion` by returning empty rather than crashing,
writes with `options: .atomic`, injects its directory for tests, and clamps hostile values on
decode — `Group.init(from:)` clamps `masterVolume` with an explicit note that an unclamped `500`
would be "a 5× amplification into the user's speakers" (`GroupStore.swift:54-56`). A bad file
cannot crash launch. That half is done right.

---

## 4. Strings and copy

### P0 — The About pane ships placeholder copy and a placeholder source URL
**Location:** `AudioutCore/Sources/AudioutSettingsUI/AboutView.swift:52`, `55`, `205`, `270`

```swift
static let sourceCodePlaceholderURL = URL(string: "https://example.com/TODO-audiout-source")!
static let supportContactPlaceholder = "TODO(Alec): add a support email or contact link"
…
let supportBody = SettingsForm.label(AboutLinks.supportContactPlaceholder)   // line 205, rendered
@objc private func viewSourceCodeTapped() { openURL(AboutLinks.sourceCodePlaceholderURL) }  // 270
```

Under a section header reading "Support", the app displays the literal text
`TODO(Alec): add a support email or contact link`. The "View Source Code…" button opens
`example.com`. Both are honestly flagged in-code with `TODO(Alec)` comments, so this is a known
item rather than an oversight — but it is still what ships today.

**Impact:** a €30 paid binary tells its buyer to add a support email. And the GPL-2.0-or-later
source-availability obligation is discharged by a button that goes to an IANA reserved
documentation domain — the code's own comment says *"replace with the real public source-code URL
before charging money for the app"*.

**Recommendation:** blocking on release. Real support contact + real repo URL, or hide both rows
until they exist (`supportContactPlaceholder == nil` → no Support section).

### P2 — Three different names for the same control
**Location:** visible labels — `MainOutRowView.swift:120` (`NSTextField(labelWithString: "Main Audio")`),
`SidebarViewController.swift:790` (`text: "Main Audio"`), `MainOutDetailViewController.swift:39`
(`private static let title = "Main Audio"`). Stray strings — `MainOutRowView.swift:340`
(`accessibilityDescription: "Main Out"`), `MainOutRowView.swift:386`
(`accessibilityDescription: "Mute Audio Out"`), `PopoverController.swift:1359` and
`PopoverPanelViewController.swift:1260` (comments describing rendered text as "Audio Out").

`PRODUCT.md:49` states: *"Terminology in product: **'Main Out'** (master output), 'groups',
'per-app routing'."* The shipping UI says **Main Audio** everywhere the user can read it (the code
cites "Warm Signal v4 §Call-1" as the authority for the rename). Two image accessibility
descriptions in the same row still say "Main Out" and "Mute Audio Out" — both are shadowed by the
explicit `setAccessibilityLabel` calls at lines 616-627, so VoiceOver is currently consistent, but
they are live drift waiting to surface.

**Impact:** the product doc, the marketing site, the iPhone companion and the Mac app will not
agree on the name of the app's single most important control. One of these two sources is wrong
and both are being read by other work in flight.

**Recommendation:** settle it (PRODUCT.md updated to "Main Audio", or the UI reverted), then delete
the two stale accessibility descriptions.

### P3 — Mixed en-GB/en-US spelling in user copy
**Location:** `AudioutCore/Sources/AudioutSettingsUI/LicenseSheetViewController.swift:72`

*"This key isn't recognised."* — the only en-GB spelling in user-facing copy; everything else is
en-US ("Equalizer…", "color", "Authorization"). (`AppTetherColor.swift`'s "colour" is in comments
only.)

### P3 — Inconsistent System Settings path separator
**Location:** `NativeCaptureCoordinator.swift:2665-2668` uses `▸`
("System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording");
`GeneralSettingsViewController` and the onboarding copy use `›`
("System Settings › Privacy & Security › Accessibility"). macOS convention is `>` or `›`.

### P3 — Auto-generated group names can collide
**Location:** `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:3189`,
`AudioutWindowUI/GroupCreationSheetController.swift:381`

`"Group \(controller.groups.count + 1)"`. Delete "Group 1" of two and the next new group is named
"Group 2", duplicating the survivor. Dedup is by *member set*, not name, so both persist.

**Recommendation:** find the lowest unused index rather than `count + 1`.

### P3 — Permission-pane name may be wrong on the oldest supported OS
**Location:** `NativeCaptureCoordinator.swift:2665-2668`

The copy names "Screen & System Audio Recording", which is the macOS 15+ pane title; the app's
minimum is 14.2 (`scripts/make-app.sh:34`), where the pane is "Screen Recording". Currently
unreachable (this string is never rendered — see the P1 above), so fix it as part of wiring it up.
Needs live check on a 14.x machine.

**Positive findings for this hunt.** A full literal sweep of all six UI targets found: no
installed-base claims of any kind (no "users", "reviews", "trusted by", "join N"); no leftover old
app names in user-facing strings (the three `"AirPlayController"` hits are internal audio-tap
identifiers, not UI); no `print`/`NSLog` anywhere in the UI targets; no other TODO/placeholder copy;
and no raw error codes, `OSStatus` values, or `nil` leaking onto screen. Jargon discipline is
otherwise excellent and deliberate — "Speaker Sync" replaces "PTP helper" with a comment naming the
rule (`OnboardingViewController.swift:1417-1420`), and `PopoverController.swift:1146-1148` states
the takeover strip must never say "PTP"/"bind"/"ports 319/320".

---

## 5. Internationalization and formatting

### P2 — Permission-lost copy is a sentence assembled from fragments with hand-rolled grammar
**Location:** `AudioutCore/Sources/AudioutOnboardingUI/OnboardingViewController.swift:1399-1412`

Hand-rolled list joining (`"A and B"` / `"A, B, and C"`) plus manual pronoun agreement
(`"Flip \(isPlural ? "them" : "it") back on"`), then string concatenation into the final sentence.

**Impact:** unlocalizable without a rewrite, and the pattern is the model other copy will copy.
Even in English-only it is fragile — the code comment itself records that the pronoun bug shipped
once.

**Recommendation:** `ListFormatter` for the join; a full sentence per arity rather than a spliced
pronoun.

### P3 — Other sentences built from English fragments
**Location:** `AudioSettingsViewController.swift:636-644` (`bufferHintLine`: value + consequence
clause + warning clause concatenated); `GroupCreationSheetController.swift:321`
(`count == 1 ? "1 speaker selected" : "\(count) speakers selected"`);
`AboutInfo.versionLine` (`"Version \(version) (Build \(build))"`).

### P3 — Percentages formatted by raw interpolation
**Location:** `MainOutRowView.swift:302,605,616`; `DeviceRowView.swift:691,1982`;
`AppRowView.swift:263,688,1023`; `GroupRowView.swift:408`; `EQEditorView.swift:744`

All `"\(value)%"` / `"\(value) percent"`. PRODUCT.md's "bare numbers and units, not named presets"
stance is about *presets*, not about digit rendering — locale digit substitution and percent
placement still differ.

**Positive:** millisecond values *do* go through a locale-aware `NumberFormatter`
(`AudioSettingsViewController.swift:376-384`), with a comment explaining why. That's the pattern
the percent sites should adopt. No `DateFormatter` use anywhere, so no date-formatting exposure.

---

## 6. Long-running reality (24/7)

This hunt came back almost clean; the work here is already done.

### P3 — Every backend event writes to stderr in release, ungated
**Location:** `AudioutCore/Sources/AudioutApp/AppDelegate.swift:1526`, `1529`, `1566-1656`, `1732`

`apply(_ event:)` calls `log("event: \(describe(event))")` for every event *except* `.level` and
`.appLevel` (which are correctly gated behind `AIRPLAY_DEBUG_LEVELS` — `AppDelegate.swift:1536`),
with no release gate. `log` is a synchronous `write(2)` on the main actor
(`audioutEmergencyWriteStderr`, `AppDelegate.swift:22-34`).

**Impact:** small. Two notes: (a) `deviceUpdated` fires per volume tick, so a fader drag issues a
main-thread write per frame; (b) the lines carry speaker names, app bundle IDs and routed app names
(`describe` lines 1711-1714), which for a GUI-launched `.app` land in the system log where they
appear in Console and in any sysdiagnose the user sends to Apple. Not a leak of anything secret,
but not something a privacy-forward product ("no cloud in the audio or control path") should be
doing unasked.

**Recommendation:** gate the per-event log behind the existing `AIRPLAY_DEBUG_LEVELS` (or a new
`AUDIOUT_DEBUG_EVENTS`) the way `.level` already is.

**Positive findings — verified, no action needed:**
- **No notification-observer leaks.** Every `addObserver` in the UI targets is the selector-based
  form on `self` (zeroing-weak since 10.11, auto-unregistered on dealloc), and each site says so.
  The two block-based observers are both explicitly removed (`DemoPaneView.swift:131,207`;
  `OnboardingChrome.swift:147,166`).
- **No retain cycles in stored closures.** A sweep for `x.onSomething = {` without `[weak self]`
  across all six UI targets returned exactly two hits, both capturing no `self`
  (`AppSurfaceController.swift:217`, `OnboardingWindowController.swift:58`).
- **Every timer is invalidated and most are bounded.** `PopoverController` invalidates all Cast
  timers on teardown (4472-4474); `BTAlignmentWizardView` and `OnboardingViewController` invalidate
  in `deinit` (154, 213); the polls self-invalidate on success (483-501).
- **Meters are zero-CPU at rest.** `LevelMeterView` stops and releases its display link once the
  bar eases to zero (`LevelMeterView.swift:298-307`), and level events are dropped entirely while
  the panel is hidden (`PopoverController.swift:4508`, `4531`).
- **No unbounded UI state.** `devicesByID` is wholly replaced each snapshot (764-766);
  `liveRoutedAppNames` is filtered against it (795); rows, diagnosis panels, connection states, BT
  trims and blocked notes are all removed by id. `btAlignmentPromptQueue` dedups on insert (3840)
  and prunes vanished devices (3872). `AppTetherColor`'s static cache is keyed by bundle id and
  bounded by distinct apps seen.
- **The launch splash cannot hang.** `SurfaceSplashView` arms both a hold timer and a *ceiling*
  timer (`SurfaceSplashView.swift:158-166`) so the cover always leaves. `DiscoverySettleTracker`
  uses an epoch so a superseded timer can never settle late.
- **`AudioDiag` is a true no-op when unset** — no file handle, no allocation
  (`AudioDiag.swift:13-20`).

---

## 7. Release hygiene

### P2 — "Delete" is the default button on the delete-group confirmation, and the confirmation is skippable
**Location:** `AudioutCore/Sources/AudioutWindowUI/GroupEditorViewController.swift:844-856`

```swift
alert.addButton(withTitle: "Delete")     // first-added ⇒ default, bound to Return
alert.addButton(withTitle: "Cancel")
…
if let window = view.window { alert.beginSheetModal(...) } else { performDelete() }
```

Two problems. The destructive action is the default, so Return or Space destroys the group — the
opposite of the HIG rule the code comment invokes. And the `else` branch performs the delete
**without any confirmation at all** whenever the pane has no window. That is the same
`view.window != nil`-as-a-headless-proxy pattern that has bitten this repo before; using it to gate
a destructive confirmation is the highest-stakes place to use it.

**Recommendation:** add Cancel first (or set `alert.buttons[0].hasDestructiveAction = true` and make
Cancel the key equivalent), and make the no-window branch a test-only seam rather than a
production path.

### P3 — License endpoint is preference-overridable and no transport scheme is enforced
**Location:** `AudioutCore/Sources/AudioutCore/AppSettings.swift:401-406`, `365-380`;
`AudioutCore/Sources/AudioutCore/LicenseValidator.swift:53`; `scripts/make-app.sh:731`

`checkInURL`'s getter reads a `UserDefaults` string *before* falling back to the derived
`licenseServerURL + v1/checkin`. Nothing validates the scheme on `licenseServerURL`, `checkInURL`
or `SUFeedURL` (which carries `Authorization: Bearer <license key>` —
`AppDelegate.swift:1458`).

**Impact:** low — the override exists for tests, and an attacker who can write the app's preference
domain already has the user's account. But a plain `http://` value anywhere in that chain sends the
license key and install id in the clear, and there is no guard.

**Recommendation:** reject non-`https` URLs in `AppSettings.bundleURL`/`checkInURL`, and have
`make-app.sh` refuse a non-https `SPARKLE_FEED_URL`/`AUDIOUT_LICENSE_URL`.

**Positive findings — verified, no action needed:**
- **`makeBackend()` is correct.** `BackendKind.resolved` defaults to `.native`, treats mock as
  explicit opt-in only, and an unrecognised `AIRPLAY_BACKEND` value falls back to `.native` with one
  stderr warning rather than silently substituting fake speakers — with the reasoning written down
  (`OwnToneBackend.swift:808-834`). Matches the standing rule exactly.
- **No debug affordance is reachable by click.** There is no `#if DEBUG` in any UI target and no
  debug menu item; every diagnostic knob (`AIRPLAY_DEBUG_LEVELS`, `AIRPLAY_DEBUG_SETUP`,
  `AUDIOUT_TCC_DIAG`, `AUDIOUT_DEBUG_CAST_PROBE`, `AIRPLAY_AUDIO_DIAG`, `AUDIOUT_STATUS_LABEL`,
  `AUDIOUT_MOCK_CAST_LAG`) is env-var-gated and inert otherwise. Every `NSMenuItem` in the app is a
  real product affordance.
- **No assertion can crash a release build.** The only `fatalError` in all six UI targets is the
  boilerplate `init(coder:)` on views that are never loaded from a nib (60 sites, all identical).
  No `try!`, no `as!`, no `precondition` in UI code.
- **The crash-safety bootstrap is exemplary.** `main.swift:34` masks `SIGPIPE` at the first
  instruction; `main.swift:42-50` installs an uncaught-exception handler that logs to both stderr and
  `os.Logger` before the abort — for a dockless accessory app that would otherwise vanish from the
  menu bar without a trace. `audioutEmergencyWriteStderr` explicitly avoids `FileHandle.write`
  because it raises an uncatchable `NSException` on a dead pipe.
- **System Settings deep links degrade safely.** `SystemSettingsOpener.open` falls back to the
  Privacy & Security root when a specific anchor won't open, and `SetupModel` version-gates the
  macOS 26 `PrivacySecurity.extension` bundle-id rename with a testable seam
  (`SetupModel.swift:172-182`).
- **`AppSettings` is hardened throughout.** Every scalar clamps or folds an out-of-range/unknown
  stored value to a documented default, distinguishes "unset" from a legitimate stored `0` via
  `object(forKey:)`, and the connect-volume floor is deliberately above 0 to make the −30 dB
  "silent connect" trap unreachable through the setting.
- **The license check is genuinely soft.** `LicenseValidator` only ever writes state on a real 200;
  a transport error, non-200 or malformed body is "no answer", never "your key is bad"
  (`LicenseValidator.swift:87-99`). The unregistered note sits at the *lowest* precedence in the
  banner slot, so a purchase nag can never displace a warning about dead audio
  (`PopoverController.swift:1113-1128`).
- **The connection-failure presentation layer is well designed.** Copy lives on the model type so
  the row sublabel, diagnosis panel and Copy Details share one source of truth; the panel is a pure
  renderer with no backend or pasteboard access; it carries a real accessibility label composed from
  the same strings the screen draws. The only problem is what feeds it.

---

## Master list, severity-ordered

| # | Sev | Finding | Location |
|---|-----|---------|----------|
| 1 | **P0** | About pane renders `TODO(Alec): add a support email…` and "View Source Code" opens `example.com` | `AboutView.swift:52,55,205,270` |
| 2 | **P1** | Capture-engine failure has no user-visible state; `userMessage` wired to nothing; retries forever behind "Connected" rows | `NativeCaptureCoordinator.swift:2662`, `NativeBackend.swift:5026` |
| 3 | **P1** | Shipping backend flattens AirPlay failures to `.unknown`; diagnostics seam wired only to OwnTone | `NativeBackend.swift:6081,7929`, `OwnToneBackend.swift:886` |
| 4 | **P1** | Speaker vanishing off the network reports `.unknown` where `.vanished` copy already exists | `NativeBackend.swift:8186` |
| 5 | **P1** | No failure signal anywhere outside the popover — menu bar has only idle/streaming; no notifications | `MenuBarStatus.swift:28`, `StatusItemController.swift:117` |
| 6 | **P1** | Corrupt store file silently discards saved groups/routes/EQ/trims, then overwrites the file | `GroupController.swift:144` + 6 sites |
| 7 | **P2** | Settings claims "Speakers reconnected" without checking; reconnect is best-effort | `AudioSettingsViewController.swift:686` |
| 8 | **P2** | Unbounded optimistic volume echo on native backend (`try? await engine.setVolume`) | `NativeBackend.swift:2413,8363` |
| 9 | **P2** | Group model mutated before persistence, no rollback — alert says "didn't save", UI shows saved | `GroupController.swift:558,628` |
| 10 | **P2** | Group-creation sheet swallows a failed save; Create button appears dead | `GroupCreationSheetController.swift:380` |
| 11 | **P2** | "Save Selected Devices as group" swallows a failed save | `PopoverController.swift:3190` |
| 12 | **P2** | Disk-full / write failures silently swallowed across 7 `try? save` sites | `GroupController.swift:221` + 6 |
| 13 | **P2** | "Copy Details" permanently disabled on AirPlay failures (`detail` never set) | `ConnectionDiagnosisView.swift:102` |
| 14 | **P2** | Three names for one control: UI "Main Audio", PRODUCT.md "Main Out", strays "Audio Out" | `MainOutRowView.swift:120,340,386` |
| 15 | **P2** | Permission-lost copy assembled from fragments with hand-rolled list + pronoun agreement | `OnboardingViewController.swift:1399` |
| 16 | **P2** | Delete-group: destructive action is the default button; confirmation skipped when unhosted | `GroupEditorViewController.swift:845,855` |
| 17 | **P3** | "Default Media Receiver" — jargon carrying a decision | `ConnectionState.swift:136` |
| 18 | **P3** | License "Checking…" inherits URLSession's 60 s default; no explicit timeout | `LicenseValidator.swift:53` |
| 19 | **P3** | "recognised" — lone en-GB spelling in en-US copy | `LicenseSheetViewController.swift:72` |
| 20 | **P3** | `▸` vs `›` separator inconsistency in System Settings paths | `NativeCaptureCoordinator.swift:2665` |
| 21 | **P3** | `"Group \(count + 1)"` collides with an existing name after a delete | `PopoverController.swift:3189` |
| 22 | **P3** | TCC copy names the macOS 15+ pane title; minimum is 14.2 — needs live check | `NativeCaptureCoordinator.swift:2667` |
| 23 | **P3** | Sentences built from English fragments (`bufferHintLine`, plural, version line) | `AudioSettingsViewController.swift:636` |
| 24 | **P3** | Percentages via raw interpolation rather than a locale formatter | `MainOutRowView.swift:302` + 8 |
| 25 | **P3** | Every backend event logged to stderr in release, ungated; carries device/app names | `AppDelegate.swift:1526,1732` |
| 26 | **P3** | License endpoint preference-overridable; no https enforcement on license/appcast URLs | `AppSettings.swift:401`, `make-app.sh:731` |

---

## Positive findings (robustness already done right)

1. **`makeBackend()` resolution is exactly per the rule** — default `.native`, mock explicit-only,
   unknown env value warns and falls back rather than fabricating demo speakers.
   (`OwnToneBackend.swift:808-834`, `850-985`)
2. **Process-level crash safety at the first instruction** — `SIGPIPE` masked before anything opens a
   socket; uncaught-exception handler to stderr *and* `os.Logger`; a stderr writer that can't raise
   on a dead pipe. (`main.swift:34-50`, `AppDelegate.swift:22-34`)
3. **Persistence layer is well engineered** — versioned envelopes, newer-schema tolerance,
   `.atomic` writes, injectable directories, backward-compatible hand-written decoders, and hostile
   values clamped on the way in with the speaker-safety rationale written down.
   (`GroupStore.swift`, and six sibling stores)
4. **`AppSettings` folds every unknown/out-of-range stored value to a documented default** and
   distinguishes unset from a legitimate stored `0`; the connect-volume floor makes the −30 dB
   silent-connect trap unreachable through the UI. (`AppSettings.swift:127-305`)
5. **The connection-failure presentation layer** — copy on the model type as one source of truth, a
   pure-renderer panel with no backend/pasteboard access, an accessibility label composed from the
   same strings drawn. (`ConnectionState.swift:87-144`, `ConnectionDiagnosisView.swift`)
6. **Single note slot with explicit precedence** — a purchase nag can never displace a warning that
   audio is dead. (`PopoverController.swift:1113-1128`)
7. **The license check is genuinely soft and honestly worded** — only a real 200 mutates state;
   "couldn't verify" never reads as "not yours"; the key is saved even when the server is
   unreachable. (`LicenseValidator.swift:87-99`, `LicenseSheetViewController.swift:12-17`)
8. **`GroupEditorViewController.saveOrReport`** — the model for the rest of the app: report the
   throw, re-render from the model, plain-words alert, no swallowed failure.
   (`GroupEditorViewController.swift:675-703`)
9. **Zero-CPU-at-rest meters** and visibility-gated level dispatch. (`LevelMeterView.swift:298`,
   `PopoverController.swift:4508`)
10. **No observer leaks, no closure retain cycles, no unbounded UI state** — verified by sweep
    across all six UI targets.
11. **Bounded splash and settle logic** — a ceiling timer guarantees the launch cover always
    leaves; the settle tracker's epoch stops a superseded timer from settling late.
    (`SurfaceSplashView.swift:158-166`, `DiscoverySettleTracker.swift:59-66`)
12. **Release hygiene** — no `#if DEBUG` UI, no debug menu items, every knob env-gated, no
    `print`/`NSLog`, no `try!`/`as!`/`precondition`, `fatalError` only in unreachable `init(coder:)`.
13. **System Settings deep links degrade safely** and version-gate the macOS 26 bundle-id rename
    behind a testable seam. (`SystemSettingsOpener.swift:16-20`, `SetupModel.swift:172-182`)
14. **Jargon discipline is deliberate and documented** — "Speaker Sync" not "PTP helper", with the
    rule written at the call site. (`OnboardingViewController.swift:1417-1420`,
    `PopoverController.swift:1146-1148`)
15. **No installed-base claims, no stale app names, no debug strings in user copy** — a full literal
    sweep of all six UI targets came back clean on all three.
