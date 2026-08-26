# Impeccable audit — Settings surface (Audiout, macOS)

Scope: `AudioutCore/Sources/AudioutSettingsUI/` (General, Appearance, Audio, About window, License sheet, login-item control), plus the shared form kit and tokens it consumes from `AudioutCore/Sources/AudioutSharedUI/`. Read-only audit; nothing built or run.

Audience lens: the customer who just paid €30 and is pasting a license key, and the privacy-conscious reader parsing every telemetry-adjacent word.

---

## Score table

| # | Dimension | Score |
|---|---|---|
| 1 | Accessibility | 2 / 4 |
| 2 | Performance | 3 / 4 |
| 3 | Appearance & Theming | 3 / 4 |
| 4 | Platform Conformance (macOS) | 3 / 4 |
| 5 | States & Honesty | 1 / 4 |
| | **Total** | **12 / 20** |

Severity counts: **P0 × 2 · P1 × 8 · P2 × 11 · P3 × 7** (28 findings).

---

## Verdict

**The Settings chrome is good work. The money path is not shippable.**

Everything that isn't about being paid for — the sidebar/pane arrangement, the live-hint discipline, the fold idiom, the appearance tiles, the sizing-trap documentation — is careful, well-reasoned, and reads as one system. The panes are lazy, cheap to switch, and use semantic tokens almost everywhere.

The two surfaces a paying customer actually judges are the two weakest. **About ships an `example.com` placeholder as the GPL source link and a literal `TODO(Alec): add a support email or contact link` string as its Support section** — a €30 customer clicking "View Source Code…" lands on a reserved documentation domain, and the app's only support channel is a visible engineering TODO. **The License sheet hardcodes a key format (`AUDT-…`) that contradicts the key-generation spec of record (`AUDR-…`) and every test in the suite** — and it renders that format inside the error string that tells a customer their key is malformed. Neither can go out the door with money attached.

Underneath those, the license flow has three structural honesty problems: it never revalidates in-session (so "will try again next launch" strands anyone who registers offline on a menu-bar app that runs for weeks), it still shows "Buy Audiout…" to a registered customer inside the sheet, and it discloses the once-per-launch license check-in — which sends the key plus a stable install identifier — nowhere in the UI at all, on a product whose positioning is "no cloud."

Fix the P0s and the four license P1s and this surface goes from 12 to a comfortable 16–17. Nothing here is architectural; it is all copy, one guard, one focus call, and one hoisted loop.

---

# Findings

## P0

### P0-1 — About ships a placeholder source URL and a literal `TODO` as the Support section

**Location:** `AudioutCore/Sources/AudioutSettingsUI/AboutView.swift:52`, `:55`, rendered at `:205`, `:270`

```swift
static let sourceCodePlaceholderURL = URL(string: "https://example.com/TODO-audiout-source")!
static let supportContactPlaceholder = "TODO(Alec): add a support email or contact link"
```

**Impact.** Three separate failures in one window:

1. A paying customer clicking **View Source Code…** is sent to `example.com` — RFC 2606's reserved documentation domain. It resolves to an IANA placeholder page. From the customer's seat that is a broken product, not a placeholder.
2. The **Support** section displays the string `TODO(Alec): add a support email or contact link` verbatim. The customer's only in-app route to help is an engineering note addressed to the developer. Support is one of the two things PRODUCT.md says the €30 actually buys ("packaging, signing, notarising, updating, **supporting**") — the app currently offers no way to reach it.
3. GPL-2.0-or-later obliges making corresponding source available. The code comment already names this: *"replace with the real public source-code URL before charging money for the app (GPL-2.0-or-later source-availability obligation)."* Charging with the placeholder in place is a license-compliance exposure, not just a polish gap.

**Recommendation.** Blocker on any paid build. Replace both constants with the real repository URL and a real support address. Add a build-time guard so this cannot ship again: a test asserting neither string contains `example.com` or `TODO`, gated on a paid-build flag (the same `licenseServerURL != nil` signal the General pane already uses to decide whether the app is a sold build). If the repo is not public yet, the honest interim is to hide the button entirely — the same discipline `updatesButton.isHidden = onCheckForUpdates == nil` already applies one file over — rather than offering a link that cannot work.

---

### P0-2 — The license key format shown to customers contradicts the key-generation spec of record

**Location:** `AudioutCore/Sources/AudioutSettingsUI/LicenseSheetViewController.swift:73`, `:87`

```swift
case .invalid: return "That doesn’t look like an Audiout key (AUDT-XXXXX-XXXXX-XXXXX-XXXXX)."
...
keyField.placeholderString = "AUDT-XXXXX-XXXXX-XXXXX-XXXXX"
```

**The conflict, verified across four sources:**

| Source | Prefix |
|---|---|
| `AudioutSettingsUI/LicenseSheetViewController.swift:73,87` (the only user-visible strings) | `AUDT-` |
| `dev/notes/website-license-integration-spec.md:42` | `AUDT-` |
| `dev/notes/handoff-2026-08-23-audiout-launch.md:11` ("key prefix `AUDT-`") | `AUDT-` |
| `dev/notes/license-key-generation-scheme-2026-08-23.md` — the key-shape spec: *"literal `AUDR` prefix + 20 random Crockford-base32 chars"* | `AUDR-` |
| Every key in `AudioutCore/Tests/AudioutCoreTests/SettingsRootViewControllerTests.swift` (19 occurrences repo-wide) | `AUDR-` |

The app has **no local format validation** — `.invalid` is purely the server's verdict, rendered with a locally hardcoded format hint. So if the deployed server at `license.audiout.app` issues `AUDR-` keys, the customer sees a placeholder that does not match the key in their receipt, and any server rejection tells them their key is the wrong *shape* when it is not.

**Impact.** The single most consequential string on the surface may be wrong, and the app states it with total confidence. A customer with a legitimately valid key who hits a transient server rejection is told their key is malformed and sent to re-check a receipt that is correct. This is the "flawless moment" failing in the exact way that produces a refund request.

**Recommendation.** Blocker. Verify against the live server before any paid build ships (**needs live check** — the license server lives in the private `aa-hh/audiout-license-server` repo, not this checkout; the deployed `/v1/validate` behaviour is not readable from here). Then: (a) settle the prefix in one place, (b) source the format hint from a single constant shared with the placeholder rather than two literals, and (c) soften the `.invalid` copy so it does not assert a shape the app cannot itself check — "Audiout couldn't read that as a key. Check it against your receipt, or paste it again." The receipt is the authority, not a string baked into the binary.

---

## P1

### P1-1 — The license check is never retried in-session; "will try again next launch" strands offline registrations

**Location:** `AudioutCore/Sources/AudioutApp/AppDelegate.swift:382` (the only `LicenseValidator.validate` call outside the sheet); status copy at `AudioutCore/Sources/AudioutSettingsUI/GeneralSettingsViewController.swift:198`

```swift
return "Couldn’t reach the license server — will try again next launch."
```

`validate` runs exactly twice in the app's life: once at launch, and once per Register click. There is no retry on network-reachability change, no periodic re-check, no "Check Again" affordance.

**Impact.** A customer who registers while offline — on a plane, on a captive-portal hotel Wi-Fi, behind a corporate proxy — gets their key saved (correct, and well-reasoned in `LicenseSheetViewController`'s doc comment) but sees "Couldn't reach the license server" indefinitely. Audiout is a menu-bar app designed to run for weeks between launches; "next launch" can be a month away. The customer paid, entered their key, and the app will not confirm it until they think to quit and reopen — which nothing tells them to do. That reads as "my purchase didn't take."

Compounding it: the string asserts a *cause* it hasn't established. `status == nil` also covers "never asked yet" and "the user just changed the key and validation is still in flight," neither of which is a server that couldn't be reached.

**Recommendation.** Two small fixes, in order of value:
1. Add a **Check Again** button beside the status line whenever `status == nil` and a key is stored. One button, one existing call, and the dead end is gone.
2. Re-run `validate` on `NWPathMonitor` reachability regain (or, cheaper, on the surface becoming visible when `status == nil`). The validator is already idempotent and already leaves state untouched on failure, so a second call costs nothing.

Soften the copy to match what is actually known: *"Not verified yet — Audiout couldn't reach the license server. Your key is saved."* The last clause matters: it is true, it is reassuring, and the current string omits it entirely.

---

### P1-2 — The once-per-launch license check-in is disclosed nowhere in the UI

**Location:** `AudioutCore/Sources/AudioutCore/LicenseCheckIn.swift:44-56`, fired unconditionally at `AudioutCore/Sources/AudioutApp/AppDelegate.swift:375`. No corresponding string anywhere in `AudioutSettingsUI/`.

```swift
request.httpBody = try? JSONSerialization.data(withJSONObject: [
    "license_key": key,
    "install_id": settings.installID,
    "app_version": Self.appVersion,
])
```

Every launch, a registered build POSTs the license key plus a stable per-install UUID to `license.audiout.app`. PRODUCT.md is explicit that this stream **"is not anonymous and must never be described as such"** and that users are told about it — but the places it names are *"this document, the source."* Neither is the app.

**Impact.** For the privacy-conscious lens this is the finding. The product's stated differentiator is "no cloud" (precisely: no cloud in the audio or control path), and the Settings surface contains not one word about the network calls that do leave the LAN. A user who runs Little Snitch and sees Audiout reaching `license.audiout.app` on every launch has been given no prior notice by the app. The check-in being *unconsented by design* (Alec, 2026-08-24 — abuse detection, correctly not a toggle) makes disclosure **more** necessary, not less: an unavoidable data flow that is also undisclosed is the combination that reads as sneaky, and it is the one a hostile HN comment writes itself about.

There is also an EU angle worth one line: a stable install identifier tied to a purchase identifier is personal data under GDPR, and Alec is EU-based. Transparency (Art. 13) is satisfied by telling people, which is cheap; the current state does not tell them anywhere they will look.

**Recommendation.** One sentence, in two places, costing nothing:
- **General pane, under the License status line** when a key is stored: *"Audiout checks in with the license server once per launch so we can spot a key shared across many machines. It sends your key, a random per-Mac id, and the app version — nothing else."*
- **About window**, a short **Privacy** section beside Support, stating the same and confirming that discovery, routing, volume and playback never leave the network.

Both are plain speech on a decision-bearing subject, which is the correct voice per Brand Commitments. Write them now, before the opt-in feature telemetry (stream 1) is built, so the privacy story ships as one thing rather than as a retrofit.

---

### P1-3 — "Remove License…" is destructive, unconfirmed, and lies about its own ellipsis

**Location:** `AudioutCore/Sources/AudioutSettingsUI/LicenseSheetViewController.swift:104-110`, `:160-165`

```swift
removeButton.title = "Remove License…"
...
@objc private func removeTapped() {
    settings.licenseKey = nil
    finish()
}
```

**Impact.** Two failures at once.

*HIG:* an ellipsis on a macOS button is a promise that more input is needed before the action commits (Apple HIG, "Ellipsis character"). This one commits instantly. The user is told a confirmation is coming and it never arrives.

*Product:* the key is gone, `licenseStatus` is cleared with it (`AppSettings.licenseKey`'s setter), the popover's "please buy" nag re-arms within the same runloop turn, and the Sparkle authorization header is dropped. Recovery requires the customer to find the purchase email again. The button sits in the **same horizontal row as Cancel** at 8pt spacing with only a spacer separating the left pair from the right pair — a mis-click distance from a no-op. Nothing about a paying customer's session should be one stray click from "you are unregistered again."

**Recommendation.** Add the confirmation the ellipsis already promises: a standard `NSAlert` sheet — *"Remove your license key? Audiout keeps working, but it will stop getting official updates until you enter a key again."* — with **Remove** as the destructive-styled non-default button and **Cancel** as default. That copy is also the honest one: it states the real consequence (updates, downloads) and explicitly denies the feared one (the app stopping), which is the whole point of the non-blocking model.

Separately: move Remove out of Cancel's immediate neighbourhood, or give it `NSButton.bezelColor`/destructive styling so it never reads as a peer of Cancel.

---

### P1-4 — The License sheet offers "Buy Audiout…" to customers who have already bought

**Location:** `AudioutCore/Sources/AudioutSettingsUI/LicenseSheetViewController.swift:100`

```swift
buyButton.isHidden = settings.buyURL == nil
```

Compare the pane, which gets this exactly right at `GeneralSettingsViewController.swift:227-228`:

```swift
let unregistered = key.isEmpty || status == .unknown || status == .invalid || status == .revoked
buyButton.isHidden = !(serverConfigured && unregistered && settings.buyURL != nil)
```

**Impact.** A registered customer clicks **Change…** (to move a key to a new Mac, to re-paste after a reinstall) and is shown a **Buy Audiout…** button next to their working license. PRODUCT.md's binding rule is *"unregistered builds ask, registered builds are quiet."* This is the one surface where the registered build is not quiet — and it is loudest at exactly the moment the customer is handling the thing they paid for. It also undercuts the sheet's own explainer, which is otherwise a genuinely good piece of honest copy.

The same staleness applies to `removeButton.isHidden`, computed once in `loadView` from the pre-edit key: after a Register that the server rejects (the key IS written to `AppSettings` first, line 186), a bad key is now stored while **Remove License… stays hidden** — the sheet has put the user in a state it offers no way out of except Cancel-and-reopen.

**Recommendation.** Extract the pane's `unregistered` predicate into one shared place (it already shares `statusLine(for:)` across the two surfaces for exactly this reason — extend the same pattern), and give the sheet a small `refreshButtons()` that runs in `loadView` **and** after every `AppSettings` write inside `registerTapped`. Two lines, and both buttons stop lying about the current state.

---

### P1-5 — Every secondary string in Settings fails the project's own measured light-mode contrast floor

**Location:** `AudioutCore/Sources/AudioutSettingsUI/SettingsForm.swift:63` (`hintLabel`), `:76` (`sectionHeader`), `:92` (`readoutWell`), `:135` (row subtitle) — consumed by every pane. Also `AboutView.swift:168`, `:194`, `:202`, `:207`, `:252`.

The codebase measured this itself, in `AudioutCore/Sources/AudioutSharedUI/Tokens.swift:406-412`:

> *"Distinct from `secondaryLabel`, whose system `NSColor.secondaryLabelColor` alias measures **3.95:1 vs `panel` in light, under floor for body text**."*

`Tokens.Color.inkSecondary` (light `#5C574C` = 7.1:1) exists specifically as the authored replacement — and **no file in `AudioutCore/Sources` uses it for Settings**. Every hint line, subtitle, section header, readout, About credits block, and **the license status line itself** renders at the measured-failing token in Circuit light.

**Impact.** PRODUCT.md's Accessibility commitment is "WCAG-level contrast floors (4.5:1 text / 3:1 non-text) in both appearances… Contrast is measured, not eyeballed." It is measured, it fails, and the failing token is the one carrying the decision-bearing copy: *what your license status is*, *what the buffer change will cost you*, *what "Reconnect last speakers" will do on next launch*. The live-hint pattern is the surface's best idea and it is rendered in the least legible text on the pane. Visible in `dev/notes/settings-snapshots/settings-appearance-light.png` — the unselected "Light"/"Dark" tile labels are noticeably washed against the near-white canvas.

Dark passes comfortably; this is a light-appearance-only defect.

**Recommendation.** Point `SettingsForm.hintLabel`/`sectionHeader`/`readoutWell` and the `row(subtitle:)` label at `Tokens.Color.inkSecondary` instead of `Tokens.Color.secondaryLabel`. One token swap in one file fixes the whole surface, About included. Keep `secondaryLabel` for non-text uses (the `minus.circle.fill` tint, glyph tints) where the 3:1 floor applies.

Related, same class, separate line: `AudioSettingsViewController.swift:592` uses `Tokens.Color.warning` (`.systemOrange`) as **text** for the env-override note. `Tokens.Color.warningText` exists at `Tokens.swift:401` precisely because *"…in light, under the 4.5:1 text floor, so a text consumer needs an authored replacement."* Swap it.

---

### P1-6 — Accessibility labels override visible titles and go stale, breaking Voice Control

**Location:** `GeneralSettingsViewController.swift:124` vs `:223`; `LicenseSheetViewController.swift:109`, `:99`, `:123`

```swift
enterLicenseButton.setAccessibilityLabel("Enter License Key")   // set once, in loadView
...
enterLicenseButton.title = key.isEmpty ? "Enter License…" : "Change…"   // flips at runtime
```

**Impact.** Once a key is stored the button *reads* "Change…" and *announces* "Enter License Key." Two failures:

- **Voice Control** users say what they see. "Click Change" does not match the AX label and will not hit the button; the accessible name is the addressable name.
- **VoiceOver** users are told about a control that does not exist on screen, and are given no signal that a key is already stored — which the visible title is the only thing conveying.

Same pattern, less severe: `removeButton` announces "Remove the stored license key" for a button titled "Remove License…"; `buyButton` announces "Buy an Audiout license" for "Buy Audiout…"; `registerButton` announces "Register this license key" for "Register."

The general rule these all break: **an explicit accessibility label should only ever replace a title that isn't self-describing** (an icon-only button, a bare switch). For a button whose title is already a clear verb phrase, setting a different label actively removes function.

**Recommendation.** Delete the `setAccessibilityLabel` calls on every button whose title already describes it — `enterLicenseButton`, `buyButton`, `removeButton`, `registerButton`, `setupButton`, `updatesButton`, `sourceCodeButton`. AppKit derives the accessible name from the title, which then tracks the flip for free. Keep explicit labels only where they earn their place: `launchSwitch`, `reconnectSwitch`, `connectVolumeSlider`, `wakeRestorePopup`, `bufferPopup`, the excluded-row `minus.circle.fill` button, and the theme tiles (which correctly pair label + `.radioButton` role + value).

---

### P1-7 — The key field never takes focus, so the paste that matters needs a click first

**Location:** `AudioutCore/Sources/AudioutSettingsUI/LicenseSheetViewController.swift` — no `viewDidAppear`, no `makeFirstResponder`, no `preferredFirstResponder` anywhere in the file.

**Impact.** This is the audit's headline moment, and it opens wrong. The customer has their key on the clipboard. The sheet appears. They press ⌘V — and nothing happens, because no field is first responder and the paste goes to whatever the panel's responder chain resolves to. They must notice, click the field, then paste. It is a small thing that is felt precisely because everything around it (the sheet-behind-a-button convention, the honest explainer, the Register-only commit) was designed with care.

For keyboard and VoiceOver users it is worse than an annoyance: the sheet presents with focus nowhere useful, and reaching the field requires a Tab hunt through a sheet with no defined `nextKeyView` chain.

**Recommendation.**

```swift
public override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.makeFirstResponder(keyField)
}
```

Guard it with `HeadlessRuntime.isActive` if the headless harness objects. While in the file, set an explicit key-view loop (`keyField` → `registerButton` → `cancelButton` → …) so Tab order is authored rather than inferred from subview order, which currently puts **Buy Audiout…** ahead of the field.

---

### P1-8 — The excluded-apps list enumerates every running application once per row

**Location:** `AudioutCore/Sources/AudioutSettingsUI/AudioSettingsViewController.swift:805`, called from `:737` inside the `:719-721` loop; provider at `RunningApps.swift:34-43`

```swift
private func icon(for bundleID: String) -> NSImage? {
    if let running = runningAppsProvider().first(where: { $0.bundleID == bundleID }), ...
```

`rebuildList()` loops over excluded apps → each `makeExcludedRow` → each `icon(for:)` → a **full** `runningAppsProvider()` call, which maps `NSWorkspace.shared.runningApplications` and materialises `app.icon` for *every* running app. With 8 excluded apps and 40 running apps that is 320 icon fetches to draw 8 rows, and it repeats on every add and every remove.

`NSRunningApplication.icon` is not a free property read — it resolves through Icon Services and can be tens of milliseconds cold per app.

**Impact.** First open of the Audio pane, and every subsequent add/remove, does work proportional to (excluded × running) on the main thread. On a machine with a lot of apps open — which is the target user, since the feature exists to exclude some of them — this is a visible hitch on a pane that should be instant. It also degrades exactly as the user uses the feature more, which is the wrong direction.

**Recommendation.** Hoist one snapshot per rebuild:

```swift
private func rebuildList() {
    let running = Dictionary(runningAppsProvider().map { ($0.bundleID, $0) },
                             uniquingKeysWith: { a, _ in a })
    ...  // pass `running` down to makeExcludedRow / icon(for:running:)
}
```

One enumeration per rebuild instead of N, and the dictionary drops the linear `first(where:)` scan too. The `NSRunningApplication.runningApplications(withBundleIdentifier:)` fallback at `:808` then only runs for genuinely-unknown bundle ids, which is its intended job.

---

## P2

### P2-1 — No `audiout://register?key=…` handler, so one-click activation cannot work

**Location:** absent. No `CFBundleURLTypes` in `scripts/make-app.sh`, no `application(_:open:)`, no `kAEGetURL` handler anywhere in `AudioutCore/Sources` (verified by repo-wide grep).

`dev/notes/license-key-generation-scheme-2026-08-23.md`, Delivery row, specifies: *"success page fetches by transaction id and offers an `audiout://register?key=…` one-click link."* The website side may already be building against that.

**Impact.** The current purchase path is: buy in browser → find key in email or on the thanks page → select and copy → switch to Audiout → click the menu bar → Settings → General → Enter License… → click the field → paste → Register. Nine steps, one of them a manual text selection, for a customer who has already paid. The spec's one-click path removes six of them.

Secondary risk in the same flow: the surface panel is `hidesOnDeactivate = true` while unpinned (`ControlPanelWindowController.swift:289`). Clicking **Buy Audiout…** from inside the sheet opens the browser and deactivates the app, tucking the panel — sheet and all — away. AppKit restores it on return, but a sheet attached to a tucked panel is a configuration worth confirming on real hardware. **Needs live check.**

**Recommendation.** Add the URL type and a handler that opens the sheet pre-filled and auto-Registers. Small, and it converts the worst part of the purchase into the best part. Until it exists, tell the website owner the scheme is not implemented so the thanks page does not ship a link that dead-ends (this belongs to the website lane per the standing feedback — hand them the fact, not a fix).

### P2-2 — `SMAppService.requiresApproval` is unhandled; the switch silently reverts with no explanation

**Location:** `AudioutCore/Sources/AudioutSettingsUI/LoginItem.swift:29`, `GeneralSettingsViewController.swift:292-304`

```swift
public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
```

`SMAppService` has four states. When the user has previously disabled Audiout in System Settings → General → Login Items, `register()` **succeeds without throwing** but `status` becomes `.requiresApproval`, not `.enabled`.

**Impact.** The switch flips on (no throw → no `syncFromLoginItem()`), the app is not actually registered, and on the next `viewWillAppear` the switch silently flips back off. The user toggles it, it appears to work, and later it has un-toggled itself — with no message, ever. The type's own doc comment ("surfaces the failure rather than lying about the state") describes behaviour the code does not have for this state.

**Recommendation.** Widen the seam to return the state, not a bool, or add an `needsApproval` property. On `.requiresApproval` after a `register()`, revert the switch and show a one-line hint — *"macOS needs you to allow Audiout in Login Items."* — with a button calling `SMAppService.openSystemSettingsLoginItems()`. The app already has this exact pattern for the PTP helper (`AppDelegate.swift:512`, `openSystemSettingsLoginItems`), so it is a reuse, not a new idea.

### P2-3 — A rejected Register leaves a bad key stored with no in-sheet way to clear it

**Location:** `LicenseSheetViewController.swift:185-186` writes before validating; `:110` hides Remove based on the pre-edit key.

**Impact.** Type a wrong key → Register → server says `.unknown` → sheet stays open showing "This key isn't recognised", **and the key is now in `AppSettings`**. `Remove License…` is still hidden (it was computed from the empty pre-edit key). The pane behind now says "This key isn't recognised", the button has become "Change…", and `applyLicenseState` has installed `Authorization: Bearer <wrong key>` on the Sparkle feed. All recoverable, but only by closing and reopening the sheet — which nothing indicates.

**Recommendation.** Covered by P1-4's `refreshButtons()`. Additionally consider not committing the key until the verdict arrives, except on the `unreachable`/`noServer` paths where saving-unverified is the correct and well-argued behaviour.

### P2-4 — The status line asserts a cause it hasn't established

**Location:** `GeneralSettingsViewController.swift:196-199`

`status == nil` covers at least four situations — never validated, validation in flight, server unreachable, key just changed — and the copy claims one of them. See P1-1 for the fix; separated here because the copy is wrong even once the retry exists.

### P2-5 — Checked-in visual evidence predates the entire license surface and the app rename

**Location:** `dev/notes/settings-snapshots/*.png` — last regenerated `7583ea11`, **2026-08-12**. The license surface landed `62027f3d`, **2026-08-24**.

**Impact.** All six PNGs still read **"Audiouter"** and show no License row, no status line, and no "Check for Updates…". The highest-stakes UI on the surface — the one a €30 customer judges the product by — has **zero checked-in rendering in either appearance**, so no one has looked at it in dark or in Circuit light. The License row is also the widest-copy row on the pane (a ~140-character wrapping status line under a two-button control row), which is exactly the shape that has historically triggered this module's documented `preferredMaxLayoutWidth` and fitting-size traps.

**Recommendation.** Regenerate via the `settings-snapshot` target with a seeded `licenseServerURL`/`buyURL` override (`AppSettings.init` already takes both, and its doc comment says that override *"is the only way to exercise a build that HAS a license"*) and with each of the five license states seeded. Note the module's standing caveat that goldens are not regenerated on macOS 27 — so these are for human eyes, not for a golden diff.

### P2-6 — Two different treatments of the same "explanatory line under a control" in one pane

**Location:** `GeneralSettingsViewController.swift:96-99` vs `:108-112`

`launchRow` passes `subtitle:` into `SettingsForm.row` — a 2pt gap, inside the row container, visually bound to its switch. `reconnectRow` uses a separate `reconnectHint` stacked at the pane's 12pt spacing — visually detached, floating between two rows and belonging to neither. Both are visible in `settings-general-light.png`: "Open Audiout automatically…" hugs its switch; "Audiout starts on this Mac's speakers only." drifts.

**Impact.** The reader has to work out which control each line describes. The AGENTS.md rule is that consequential controls carry a **live** hint (correct — the reconnect line must be live, the launch line is static), but the two idioms now differ in *spacing* as well as in liveness, which turns a semantic distinction into a layout inconsistency the user reads as sloppiness. The License status line inherits the same detached treatment.

**Recommendation.** Give the live-hint form the same 2pt binding to its row that the static subtitle has — either by tightening the stack spacing around hint labels, or by letting `SettingsForm.row` accept a live hint label directly so both go through one code path and land at one distance.

### P2-7 — Hint lines are not programmatically linked to the controls they describe

**Location:** `SettingsForm.swift:60-68`; every `hintLabel` consumer.

**Impact.** VoiceOver reads a switch as "Reconnect last speakers when Audiout starts, off, switch" and stops. The consequence line — the thing the whole live-hint pattern exists to convey — is a separate static label the user only hears if they navigate past the control. The sighted user gets the design's best feature; the VoiceOver user does not.

**Recommendation.** Set the hint as the control's `accessibilityHelp` (VoiceOver reads it as the hint, after a pause) and re-set it in the same place the pane already rewrites `stringValue`. One extra line per rewrite site — `reconnectToggled`, `connectVolumeChanged`, `wakeRestoreChanged`, `updateBufferHintAndResolveTarget`, `applyAccentSelection`, `refreshLicenseStatus`. Optionally also wire `accessibilityLinkedUIElements` so the two are navigably associated.

### P2-8 — The credits block is 4,000+ characters of legal text at caption size in the failing secondary colour

**Location:** `AboutView.swift:251-252`, `:266`

```swift
creditsTextView.font = Tokens.Font.caption          // 11pt
creditsTextView.textColor = Tokens.Color.secondaryLabel   // 3.95:1 in light
...
scrollView.heightAnchor.constraint(equalToConstant: 200)
```

**Impact.** The GPL attribution and the full per-component third-party breakdown — content that exists to satisfy a licence obligation and must therefore be *readable* — is set at the smallest system size in the token the codebase measured as failing the text floor, inside a 200pt box. It is the least legible text in the app, and it is the text with a legal reason to be legible.

**Recommendation.** `Tokens.Font.body` (or at minimum keep caption but move to `inkSecondary`) and `Tokens.Color.label` for the credits body. Legal text is body text.

### P2-9 — The About window is never positioned

**Location:** `AboutView.swift:334-341` — `show()` calls `setContentSize` and `makeKeyAndOrderFront`, but never `center()` and sets no frame autosave name.

**Impact.** The window appears wherever AppKit's default cascade puts it — which, opened from a panel anchored under the menu bar on a large display, is frequently far from where the user is looking, and can land partly under the panel. Every subsequent open re-cascades. Standard About windows are centered (or at least remembered).

**Recommendation.** `window?.center()` before `makeKeyAndOrderFront`, once, on first show. Consider `window?.isRestorable = false` too — an About window has no state worth restoring.

### P2-10 — Interior whitespace and lookalike characters in a pasted key are not normalised locally

**Location:** `LicenseSheetViewController.swift:175`

```swift
let text = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
```

Leading/trailing trim is correct and covers the common receipt paste. Not covered: a key that wrapped across two lines in an email client (interior newline), non-breaking spaces from an HTML receipt, and the Crockford-base32 lookalikes the key-generation spec explicitly calls out — *"map O→0 and I/L→1 on entry"* — for a key a customer may read off a phone screen and type.

The code comment says the server canonicalises, which is the right division of labour, but **the server's actual behaviour is not readable from this checkout** (private repo). If it does not, a customer who typed `O` for `0` gets "This key isn't recognised" and no hint about why.

**Recommendation.** **Needs live check** against `/v1/validate`. If the server canonicalises, the comment is enough. If not, add the spec's own canonicalisation client-side before sending — uppercase, strip all whitespace and dashes, map `O→0` and `I`/`L`→`1`. It is four lines and it turns a support email into a successful registration.

### P2-11 — The key field inherits system smart-substitution behaviour

**Location:** `LicenseSheetViewController.swift:86-89` — the field is configured with a placeholder and an AX label only.

**Impact.** An `NSTextField`'s shared field editor inherits the user's system-wide "Smart quotes and dashes" and "Text replacement" settings. For a hyphen-grouped alphanumeric key this is a low-probability but high-cost failure: a text-replacement rule or a substitution silently rewrites a character and the customer is told their key is unrecognised, with no way to see what happened. Cost of prevention is one line; cost of occurrence is a support thread. **Needs live check** to confirm which substitutions actually fire for this format.

**Recommendation.** Set `keyField.usesSingleLineMode = true`, and on the field editor disable automatic dash/quote substitution and text replacement (via `controlTextDidBeginEditing` or an `NSTextView` subclass). Also worth `keyField.cell?.isScrollable = true` so a long key does not clip.

---

## P3

- **P3-1 — Duplicate "Advanced" accessible names.** `AudioSettingsViewController.swift:405` and `:420` both set `setAccessibilityLabel("Advanced")` on two adjacent controls (the triangle and the clickable title). VoiceOver announces two identical buttons in a row. Give the title button `setAccessibilityElement(false)` — it is a click-target duplicate of the triangle, not a second control.

- **P3-2 — `ThemeTileButton.updateTrackingAreas` removes every tracking area, including AppKit's own.** `AppearanceSettingsViewController.swift:268` — `trackingAreas.forEach(removeTrackingArea)` is broader than needed and can strip cursor/tooltip tracking AppKit installed. Track only the one this view owns (keep a stored reference and remove that).

- **P3-3 — No guard against double-presenting the License sheet.** `GeneralSettingsViewController.swift:237` constructs a fresh sheet on every click with no `guard licenseSheet == nil`. Unreachable in practice (the presented sheet covers the button) but the held reference is silently overwritten. One-line guard.

- **P3-4 — The check-in fires only at launch, so a fresh registration is not counted until the next launch.** `AppDelegate.swift:375` runs `checkInIfNeeded()` before any key can be entered in that session. Acknowledged as a deliberate ceiling in `LicenseCheckIn.swift`'s `razor:` comment; noting it because the device-spread metric is a stated Success Metric and it undercounts by one launch per install. Calling it again from `onLicenseChanged` would close the gap.

- **P3-5 — Two button sizes in one pane.** `GeneralSettingsViewController.swift:150/157/163` use `.small` for the footer strip while `:121/:127` use the default size for the License row. Deliberate ("a quiet button strip"), but the two strips sit ~12pt apart with a single hairline between them, so the size change reads as accidental rather than as hierarchy.

- **P3-6 — The theme-tile selection ring paints system accent blue on a fully warm surface.** `AppearanceSettingsViewController.swift:367` uses `Tokens.Color.accent`, whose own doc (`Tokens.swift:90-96`) warns it *"paints `#007AFF` onto a surface whose entire vocabulary is warm"* and directs engaged-chrome consumers to `engagedChrome`. Visible in both Appearance snapshots as the one cold element on the pane. Defensible — an appearance picker is where macOS users expect the accent ring, and the token's warning is scoped to the mixer — but it is the codebase's own guidance pointing the other way, so confirm it is a decision rather than a default. Per the standing feedback on secondary colours, this is an **ask**, not a fix.

- **P3-7 — `.rounded` bezel on wide buttons.** `NSButton.bezelStyle = .rounded` is the correct push-button bezel but AppKit renders it inconsistently past ~130pt width on some OS versions; "Check for Updates…" at `.small` is near that. Cosmetic; flag only if a live pass shows it.

---

## Systemic patterns

**1. The chrome was designed; the commerce was assembled.** Everything not touching money shows genuine care — the sizing traps are documented with probe evidence, the fold uses one clock, the preview palettes are pinned against tokens by a test so a re-tune fails loudly. The license and About surfaces have none of that rigour: placeholder constants that shipped, a key format contradicting its own spec, buttons whose visibility is computed once and never refreshed, no visual evidence, no retry. The gap is not skill, it is that the license work (2026-08-24) is twelve days newer than the last visual pass (2026-08-12) and has not yet been through the same loop. **Run the surface's existing quality loop over the license flow** and most of the P1s fall out on their own.

**2. Two tokens exist for every text colour, and Settings picked the wrong one both times.** `inkSecondary` (7.1:1) and `warningText` (4.9:1) were authored *specifically* because `secondaryLabel` (3.95:1) and `.systemOrange` fail the light-mode text floor — the rationale is written into `Tokens.swift`. Settings uses the failing tokens throughout. This is not a judgement call anyone made; it is a default nobody revisited when the authored replacements landed. A lint test asserting "no Settings text consumer reads `Tokens.Color.secondaryLabel`" would close it permanently.

**3. Accessibility labels are applied as a reflex rather than as a decision.** Nine buttons carry `setAccessibilityLabel` calls that *replace* a perfectly self-describing title, and one of those titles flips at runtime while its label does not. The intent is obviously good. The rule that would have prevented it: **only label what the visible UI doesn't already say.** Where the file follows that rule — the theme tiles' role + value contract, the excluded-row remove button's "Remove ⟨name⟩" — the result is genuinely excellent.

**4. Copy that describes the app is honest; copy that describes the network is silent.** The status lines, the explainer, the buffer hint, "Audiout is fully functional without a license" — these are strong, plain, non-manipulative writing that lands the Ardour model well. But every string about what leaves the machine is either absent (the check-in), overclaimed (the unreachable cause), or unverified (the key format). The voice rule is right and well-executed on the easy half; the hard half hasn't been written yet.

**5. State computed in `loadView` and never refreshed.** `buyButton.isHidden`, `removeButton.isHidden`, `updatesButton.isHidden`, and every `setAccessibilityLabel` are one-shot in a `loadView` that runs once per app launch, on controllers that live for the whole session. The pane got this right with `refreshLicenseStatus()` as a single funnel — *"one place that decides what the pane shows"* — and the sheet, written at the same time, got it wrong. The pane's pattern is the answer; it just needs applying one file over.

---

## Positive findings

**The sheet-behind-a-button convention is the right call, made for the right reason.** `LicenseSheetViewController`'s doc comment cites Sublime, Little Snitch and Panic and explains *why* — entry is a deliberate act, registered state collapses to a sentence. The pane correctly never shows an editable field. This is the convention a paying macOS customer expects, and it was researched rather than guessed.

**"Register commits, Cancel discards, and an unreachable server still saves the key."** This is the hardest judgement call in the whole flow and it is reasoned correctly and documented at `LicenseSheetViewController.swift:11-17`: *"'couldn't verify' must never read as 'not yours'."* Getting this backwards is the single most common way a soft license check betrays a customer, and it was avoided deliberately.

**`LicenseValidator` blocks nothing and fails silently by construction.** Only a real 200 ever changes stored state (`:92`); an unreachable server leaves the last known answer untouched; an answer about a key the user has since edited is discarded (`:68`). *"A user on a plane sees whatever they saw yesterday rather than being told their key went bad."* The offline story at the model layer is genuinely well built — the gap in P1-1 is a missing retry above it, not a flaw in this.

**A build with no license server hides the entire License surface.** `GeneralSettingsViewController.swift:209-212` — *"it has nothing to verify and nothing to sell, so it says nothing at all."* Someone who compiled from source, exercising their GPL right, is never shown a purchase prompt they cannot act on. That is the Ardour model implemented with actual respect, and the same discipline appears again on `updatesButton` (hidden, not disabled, when there is no updater) and on the Advanced section (absent, not dead, when the backend can't honour it). Three instances of the same principle: never offer a path that cannot work.

**The unregistered copy asks without nagging.** *"Audiout is fully functional without a license — buying one funds development and unlocks official downloads and updates"*, and the popover's *"Audiout is unregistered. Buying a license keeps it updated and funds the work of improving it."* Both state a fact once, both name what the money buys, neither implies the app will stop working, neither uses a deadline or a countdown. The popover note is also correctly ranked lowest-precedence behind real problems. This is the tone the business model needs.

**The live-hint pattern is the surface's best idea.** Rewriting the consequence line on every value change — "Connects at 35% — a moderate, comfortable start", "Buffer: 120 ms — … Changing this reconnects your active speakers", "Next launch reconnects the speakers you last used" — means no control is ever a mystery, the warning about the cost of a change arrives *before* the change, and the banding is on the value rather than the option index so a future re-tune stays honest. Fix its contrast (P1-5) and its VoiceOver linkage (P2-7) and it is exemplary.

**Theme tiles have a correct, tested accessibility contract.** `.radioButton` role plus a 0/1 accessibility value, with `test_isTileAccessibilitySelected` proving it — added specifically because *"without it, all three tiles announce identically and the current theme is never conveyed non-visually."* Someone found a real VoiceOver defect and closed it with a test.

**The preview palettes are pinned to the live tokens by test.** `PreviewPaletteTokenPinTests` exists because the `well` value *"sat stale through one retune already."* Absolute sRGB in the tiles is the correct choice (a tile depicts an appearance, it must not adopt one) and the drift risk it creates was identified and fenced rather than left to vigilance.

**Appearance-adaptive colours are drawn, not stamped.** `BorderedListView`, `ReadoutWellView` and the sidebar cells resolve their colours inside `draw(_:)` so they re-resolve under the current appearance with no manual appearance-change bookkeeping. That is the right AppKit answer and it is applied consistently.

**The sizing traps are documented with probe evidence, not folklore.** The `translatesAutoresizingMaskIntoConstraints` rule, the empty-container 500×500 fallback, the priority-501 root lock that makes `fittingSize` safe for growth but never for shrink (`hcons=[501:h==424]` while the column solved to 214), and the three `NSStackView` collapse approaches that were tried and failed. Each carries the measurement that established it. This is the module's real asset — it is why the next person will not re-ship the 116pt dead gap.

**The sheet is protected from the panel's click-out dismissal.** `ControlPanelWindowController.swift:751` includes `!hasAttachedSheet` in the resign-key conditions, with the reason stated: *"dismissing the host out from under a live sheet destroys the sheet mid-edit."* A half-typed license key cannot be destroyed by a stray click.

**Test hooks drive real AppKit dispatch.** `selectSection(at:)` goes through genuine outline-view selection rather than a direct pane swap, because *"a hook that called a delegate directly once let genuinely broken UI stay green across 78 tests."* `test_setLicenseKey` likewise opens the real sheet, types, and clicks Register — *"what tests prove is the one commit path users have."* The license status strings are asserted verbatim in `SettingsRootViewControllerTests.swift:186-237`, which is why the copy is consistent even where it is wrong.

**`SMAppService.mainApp` behind a protocol seam, with the system as source of truth.** The switch re-reads live state on every appear because *"the user can flip the login item in System Settings while our window is closed, and a stored bool would drift."* Correct modern API, correct source of truth, and testable without registering a real login item as a side effect. Only the `.requiresApproval` branch (P2-2) is missing.

**Panes are lazy, reused, and cheap to switch.** Section controllers are retained by `sections` and their views load once on first selection; `setContent` re-parents as a real child controller so the responder chain stays correct, and scrolls to top so a section always opens at its top. No standing timers, no work on pane switch, one shared fold clock. Aside from P1-8, the performance story is clean.

**The one-surface sidebar is a real source list with a one-way-door guard.** `canCollapse = false` because *"the sidebar is the only way to change section, and the surface has no sidebar toggle and no View menu to bring it back."* Someone thought about what happens after the user collapses it.

**`Cmd-,` works.** Both the menu-bar secondary menu and the app main menu carry a Settings item at the standard key equivalent (`AppDelegate.swift:1197`, `:1225`) — easy to omit in a menu-bar-only app with no Dock presence, and not omitted.
