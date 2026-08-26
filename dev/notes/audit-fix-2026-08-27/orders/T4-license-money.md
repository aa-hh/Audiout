# T4 — License / money path (Settings, License sheet, About)

**Branch:** `claude/fix-license-money` (create as a worktree from the current HEAD of `claude/macos-app-production-audit-5fcbf3`; that tree is clean — no uncommitted work to carry). Push the branch to origin immediately (`git push -u origin claude/fix-license-money`).

**Repo root (path has a space — always quote):** `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/xenodochial-ardinghelli-fa348b` — but do the work in the NEW worktree you create for the branch, per CLAUDE.md.

**Build/test rule (BINDING).** Every compile and every test run goes through the wrapper scripts, which route work to the remote test mule: `bash scripts/build.sh` and `bash scripts/run-tests.sh --filter <Suite>`, from the repo root. Bare swift-build / swift-test invocations are FORBIDDEN — they opt out of the mule, the machine-wide concurrency cap, and the unchanged-sources cache, and pin work to a Mac already running many agents. `AUDIOUT_BUILD_LOCAL=1` only if the mule is unreachable, and report that you used it. Traps: never pipe `run-tests.sh` through `| tail` (it eats the exit code); never kill or abandon an in-flight remote test run (orphaned legs pin the build lock — let it finish).

**Owned files (the only files you may modify):**
- `AudioutCore/Sources/AudioutSettingsUI/` — all files
- `AudioutCore/Sources/AudioutCore/LicenseValidator.swift`
- `AudioutCore/Sources/AudioutCore/AppSettings.swift`
- `AudioutCore/Sources/AudioutApp/AppDelegate.swift` — EXACTLY one added statement (step 14), nothing else
- `dev/notes/license-key-generation-scheme-2026-08-23.md` — one row + one note (step 16)
- Tests: `SettingsRootViewControllerTests.swift`, `AboutSectionTests.swift`, `LicenseValidatorTests.swift`, `AppSettingsTests.swift` (all under `AudioutCore/Tests/AudioutCoreTests/`)

**Do not touch:** `Tokens.swift` (another track owns it; it is making `secondaryLabel` mode-aware, which fixes the settings-wide contrast finding P1-5 globally — do NOT swap any `secondaryLabel`/`warning` token usages yourself; `AudioSettingsViewController.swift:592`'s `warning`→`warningText` is ALSO that track's). `scripts/make-app.sh` (T7 — the https refusal for `SPARKLE_FEED_URL`/`AUDIOUT_LICENSE_URL` lands there, not here). `PopoverController.swift`. `LicenseCheckIn.swift` (read-only for you; its copy and behavior are unchanged). No `audiout://` URL-scheme handler (audit P2-1 — website lane, out of scope). No snapshot regeneration.

**Collision note:** T7 will add one Touch Bar toggle row to `GeneralSettingsViewController`. When you edit the `paneView(rows:)` array (currently `GeneralSettingsViewController.swift:179-181`), keep it ONE row per line so their append merges cleanly.

**Formerly-open inputs — now resolved, treat as facts:**
1. **Key prefix is `AUDT`.** The deployed license worker (production and staging, verified 2026-08-27 from the deployed bundle: `var PREFIX = "AUDT"` in src/keys.ts) issues `AUDT-` keys. The app's UI strings were right; the spec doc and the test fixtures (`AUDR-`) are the stale side. The `.invalid` copy KEEPS its current wording (the server only answers `invalid` for keys genuinely malformed after full canonicalization, so the format claim is accurate) — but the format string moves into one shared constant (step 3).
2. **The server canonicalizes** (uppercases, strips everything but A-Z0-9, maps O→0 and I/L→1, on every key-taking endpoint — verified 2026-08-27). So NO client-side key normalization is added (audit P2-10 is dropped); the existing comment at `LicenseSheetViewController.swift:172-174` saying the server canonicalises is correct and stays. Audit P2-11 shrinks to single-line-mode + scrollable cell only (step 6).
3. **About values (audit P0-1, variant A):** support contact `support@audiout.app`; source URL `https://github.com/aa-hh/Audiout` (verified public 2026-08-27). Wire real values; keep the no-placeholder guard test.

Also verified: the server returns HTTP 200 for all four verdicts and `/v1/checkin` always replies 204 — repeated validate/check-in calls are safe.

**House style for all new user-facing strings:** typographic apostrophe U+2019 (`isn’t`, `couldn’t`, `Audiout’s`), em dash `—`, en-US spelling.

---

## Verified facts (each checked 2026-08-27 in this tree)

- `LicenseSheetViewController.statusLine(for:)` is the one wording for the four server verdicts, shared with the pane — `AudioutSettingsUI/LicenseSheetViewController.swift:68-75`. `.unknown` says "recognised" (:72); `.invalid` hardcodes `AUDT-XXXXX-XXXXX-XXXXX-XXXXX` (:73), duplicated as the placeholder at :87.
- Sheet buttons' visibility is computed once in `loadView`: `buyButton.isHidden = settings.buyURL == nil` (:100), `removeButton.isHidden = (settings.licenseKey ?? "").isEmpty` (:110). `registerTapped` writes the key BEFORE validating (:185-186), so a rejected key is stored while Remove stays hidden.
- `removeTapped` (:160-165) clears the key and closes with no confirmation, despite the "Remove License…" ellipsis (:104).
- The sheet has no `viewDidAppear`, no `makeFirstResponder`, no `nextKeyView` chain (checked the whole file).
- Pane status copy for `status == nil` with a key: `"Couldn’t reach the license server — will try again next launch."` — `GeneralSettingsViewController.swift:198`. `refreshLicenseStatus()` (:209-231) is the pane's single display funnel and ends with `onLicenseChanged?()`. The `unregistered` predicate lives inline at :227.
- The pane never re-validates in-session: `LicenseValidator.validate` is called only at launch (`AppDelegate.swift:382`) and per Register click (`LicenseSheetViewController.swift:195`).
- The once-per-launch check-in POSTs `license_key` + `install_id` + `app_version` (`AudioutCore/LicenseCheckIn.swift:44-56`), fired at `AppDelegate.swift:375`; no disclosure string exists anywhere in `AudioutSettingsUI/` (grepped).
- `general.onLicenseChanged = { [weak self] in self?.applyLicenseState() }` — `AppDelegate.swift:1295`; `settings` is in scope there (used the same way at :1290).
- `AboutLinks.sourceCodePlaceholderURL` = `https://example.com/TODO-audiout-source`, `supportContactPlaceholder` = a literal TODO string — `AboutView.swift:52,55`; rendered at :205, opened at :270. Credits text view uses `Tokens.Font.caption` + `secondaryLabel` (:251-252). `AboutWindowController.show()` (:334-341) never calls `center()`; `init` (:319-326) never sets `isRestorable`.
- `setAccessibilityLabel` overriding self-describing titles: `GeneralSettingsViewController.swift:124` ("Enter License Key" on a button whose title flips at :223), :130 (buy), :153 (setup), :166 (updates); `LicenseSheetViewController.swift:99` (buy), :109 (remove), :123 (register); `AboutView.swift:186` (source code). Earned labels to KEEP: launchSwitch :94, reconnectSwitch :107, keyField "License key" `LicenseSheetViewController.swift:88`, and everything in the Audio/Appearance panes not named below.
- `LoginItemManaging` (`LoginItem.swift:9-20`) exposes only `isEnabled`/`setEnabled`; `SMAppService` `.requiresApproval` is unhandled — `register()` succeeds without throwing, `isEnabled` stays false, the switch silently reverts on next appear (`GeneralSettingsViewController.swift:292-304`, `276-278`). Conformers a protocol change would break: `SettingsRootViewControllerTests.swift:27`, `AboutSectionTests.swift:21`, `SettingsAccentAndHintsTests.swift:232`, `settings-snapshot/main.swift:42` — hence the protocol-extension defaults in step 12. The wrap pattern to copy: `PTPHelperService.swift:122-124` calls the static `SMAppService.openSystemSettingsLoginItems()`.
- `AudioSettingsViewController.rebuildList()` (:714-728) calls `makeExcludedRow` per excluded app; each row's `icon(for:)` (:803-815) enumerates `runningAppsProvider()` in full (`RunningApps.regularRunningApps` materializes `app.icon` for every running app). The picker at :827 makes its own single call — leave it.
- Duplicate "Advanced" AX labels: `AudioSettingsViewController.swift:405` (triangle) and :420 (title button).
- `ThemeTileButton.updateTrackingAreas` removes ALL tracking areas — `AppearanceSettingsViewController.swift:266-273`.
- `LicenseValidator` builds its `URLRequest` at `LicenseValidator.swift:53-56` with no timeout (URLSession default 60 s). Note: on `URLRequest` the property is `timeoutInterval` — the audit's `timeoutIntervalForRequest` is a `URLSessionConfiguration` property and does not exist on `URLRequest`.
- `AppSettings.bundleURL(forInfoDictionaryKey:)` (:378-380) and the stored-string path of `checkInURL` (:401-407) accept any scheme. `licenseServerURL` :365-367 and `buyURL` :374-376 both route through `bundleURL`. The init overrides (:74-78) are test seams — leave them unguarded.
- Test fixtures use the stale `AUDR` prefix (case-insensitive count): `SettingsRootViewControllerTests.swift` ×10, `LicenseValidatorTests.swift` ×5 (three lowercase `audr-…`), `AppSettingsTests.swift:290` ×1. `dev/notes/license-key-generation-scheme-2026-08-23.md:35` is the stale spec row. (`dev/notes/handoff-2026-08-23-license-key-backend.md` and `work-order-2026-08-23-license-soft-check.md` are historical records — leave them.)
- Verbatim status-string assertions to update: `SettingsRootViewControllerTests.swift:203` (recognised), :217/:235/:237 (couldn't-reach copy). :186, :192, :198, :208 stay as-is.
- About placeholder tests to replace: `AboutSectionTests.swift` — `supportContactIsAnUnmistakableTODOPlaceholder` (~:122), `sourceCodeLinkIsAnUnmistakablePlaceholderNotAnInventedRealURL` (~:127), `viewSourceCodeButtonOpensThePlaceholderURLThroughTheInjectedSeam` (~:135). The compactness bound `fittingSize.height < 450` (~:150) must NOT be raised — `NSStackView` detaches hidden arranged views, and every new pane row below starts hidden.
- `SettingsForm.hintLabel` sets `preferredMaxLayoutWidth = contentWidth - horizontalPadding * 2` (`SettingsForm.swift:60-68`); `paneView` pins every row to the column width (:194-196). This module's AGENTS.md sizing traps are load-bearing — set `translatesAutoresizingMaskIntoConstraints = false` on every new view, never measure a pane root for shrink.
- **Baseline (run in this tree via the wrappers, 2026-08-27, both exit 0):**
  - `bash scripts/run-tests.sh --filter SettingsRootViewControllerTests --filter AboutSectionTests --filter LicenseValidatorTests --filter LicenseCheckInTests --filter AppSettingsTests --filter SettingsAccentAndHintsTests` → "Test run with 94 tests in 7 suites passed"
  - `bash scripts/run-tests.sh --filter AudioSettingsLatencyTests --filter AudioSettingsWakeRestoreTests --filter PreviewPaletteTokenPinTests` → "Test run with 15 tests in 4 suites passed"

---

## Copy strings (use verbatim, including punctuation)

- S1 `.unknown` verdict: `This key isn’t recognized. Check it against your receipt.`
- S2 pane status, key stored + `status == nil`: `Not verified yet — Audiout couldn’t reach the license server. Your key is saved.`
- S3 check-in disclosure (pane): `Audiout checks in with the license server once per launch so we can spot a key shared across many machines. It sends your key, a random per-Mac id, and the app version — nothing else.`
- S4 remove confirmation — messageText: `Remove your license key?` · informativeText: `Audiout keeps working, but it will stop getting official updates until you enter a key again.` · buttons: `Remove` (destructive, NOT default), `Cancel` (default).
- S5 login-item approval hint: `macOS needs you to allow Audiout in Login Items.` · button title: `Open Login Items…`
- S6 About › Privacy body: `Discovery, routing, volume, and playback stay entirely on your network — none of it touches a server, even offline. Audiout’s only outside connections are about your license and updates: a check of your key, a once-per-launch check-in (your key, a random per-Mac id, and the app version — nothing else), and the update check when one runs. A build compiled from source makes none of these.`
- S7 About › Support body: `Questions or problems? Email support@audiout.app.`
- S8 Check Again button title: `Check Again`
- S9 `.invalid` verdict (unchanged wording, now interpolated): `That doesn’t look like an Audiout key (AUDT-XXXXX-XXXXX-XXXXX-XXXXX).`

---

## Steps

### Track A — the license path

**1. `AppSettings.swift` — shared `licenseUnregistered` predicate.** Next to `licenseStatus` (:344-347) add a public computed `licenseUnregistered: Bool`: true when `(licenseKey ?? "").isEmpty` OR `licenseStatus` is `.unknown`, `.invalid`, or `.revoked`. (Key stored with `nil` status is NOT unregistered — benefit of the doubt, matching the pane's existing predicate at `GeneralSettingsViewController.swift:227`.) Doc comment: callers compose it with `licenseServerURL != nil` themselves. Do NOT touch `AppDelegate.applyLicenseState`'s inline duplicate (:1455-1456) — outside your ownership; it stays consistent because both read the same two fields.

**2. `AppSettings.swift` — https-only license URLs (hardening 26).** In `bundleURL(forInfoDictionaryKey:)` (:378-380) return nil unless the parsed URL's scheme is exactly `"https"`. Apply the same guard to the STORED-string branch of `checkInURL`'s getter (:403) so a preference-planted `http://` endpoint is ignored and the getter falls through to the derived https URL. Leave the init overrides unguarded (test seam — say so in the guard's comment). Rationale for the comment: these URLs carry the license key (and `SUFeedURL` a bearer header) — never in the clear.

**3. `LicenseSheetViewController.swift` — one key-format constant (P0-2 as resolved).** Add `static let keyFormatHint = "AUDT-XXXXX-XXXXX-XXXXX-XXXXX"` on the type. `keyField.placeholderString` (:87) reads it; the `.invalid` case (:73) becomes the same sentence with the constant interpolated (net string identical to S9). While here: `.unknown` (:72) becomes S1 (hardening 19).

**4. `LicenseSheetViewController.swift` — `refreshButtons()` funnel (P1-4 + P2-3).** Add:
```swift
private func refreshButtons() {
    buyButton.isHidden = !(settings.buyURL != nil && settings.licenseUnregistered)
    removeButton.isHidden = (settings.licenseKey ?? "").isEmpty
}
```
Call it (a) at the end of `loadView`, replacing the two one-shot `isHidden` lines at :100 and :110; (b) in `registerTapped` immediately after `settings.licenseKey = text` (:186); (c) in the `.verified(let status)` non-active branch (:200-205) after the field/result updates. Result: a registered customer opening Change… never sees Buy; a rejected Register reveals Remove in-sheet.

**5. `LicenseSheetViewController.swift` — confirmed Remove (P1-3).** Split `removeTapped` (:160-165): extract the current body into `private func performRemove()`. `removeTapped` becomes: if `view.window` exists, present an `NSAlert` as a sheet with S4 — `addButton("Remove")` first then `addButton("Cancel")`; then `buttons[0].hasDestructiveAction = true`, `buttons[0].keyEquivalent = ""`, `buttons[1].keyEquivalent = "\r"`; on `.alertFirstButtonReturn` call `performRemove()`. With no window (headless tests), call `performRemove()` directly — this keeps `test_tapRemove` and every existing test meaning "confirmed remove". Also set `removeButton.hasDestructiveAction = true` in `loadView` (the destyling half of the finding; the button already sits across a spacer from Cancel — do not move it).

**6. `LicenseSheetViewController.swift` — field behavior (P1-7 + reduced P2-11).** In `loadView`: `keyField.usesSingleLineMode = true`; `keyField.cell?.isScrollable = true`; author the key-view loop `keyField → registerButton → cancelButton → buyButton → removeButton → keyField` via `nextKeyView`. Add:
```swift
public override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.makeFirstResponder(keyField)
}
```
(`viewDidAppear` never fires headlessly here — the pane only presents when a visible window hosts it, `GeneralSettingsViewController.swift:247-249`. If a test run proves otherwise, wrap the `makeFirstResponder` line in `guard !HeadlessRuntime.isActive`.) No field-editor substitution work — the server canonicalizes (resolved input 2).

**7. `LicenseSheetViewController.swift` — AX labels (P1-6, sheet half).** Delete the `setAccessibilityLabel` calls at :99 (buy), :109 (remove), :123 (register). KEEP :88 (`keyField`, "License key" — a bare field earns its label). Also reword the `.unreachable` comment at :207-209 ("will try again next launch" story) to match the new pane copy: the status line now says the key is saved and offers Check Again.

**8. `LicenseValidator.swift` — 10 s timeout (hardening 18).** After building the request (:53-56): `request.timeoutInterval = 10`. (NOT `timeoutIntervalForRequest` — that property does not exist on `URLRequest`.)

**9. `GeneralSettingsViewController.swift` — status honesty + Check Again + in-session retry (P1-1 + P2-4).**
- :198 becomes S2. Update the doc comment at :186-190 if it references the old cause claim.
- New `checkAgainButton = NSButton()`: title S8, `.rounded`, `.small`, target/action `checkAgainTapped`, hugging + compression `.required` horizontal (the `SettingsForm.row` control treatment, `SettingsForm.swift:142-144`), `translatesAutoresizingMaskIntoConstraints = false`. Compose a horizontal `NSStackView([licenseStatusHint, checkAgainButton])`, alignment `.firstBaseline`, spacing 8, and put THAT in the `paneView` rows array where `licenseStatusHint` sits today (:180).
- In `refreshLicenseStatus()`: `checkAgainButton.isHidden = !(serverConfigured && !key.isEmpty && status == nil)`; and set `licenseStatusHint.preferredMaxLayoutWidth` to `SettingsForm.contentWidth - SettingsForm.horizontalPadding * 2` minus 96 when the button is visible, minus 0 when hidden (the wrap-width trap: an oversized value computes intrinsic height at the wrong width — see `SettingsForm.hintLabel`'s doc comment).
- The retry (decision: surface-visible over `NWPathMonitor` — smaller, no monitor lifecycle in a session-long controller; the validator is idempotent and the server 200s every verdict, so repeated calls are safe):
```swift
private var revalidateInFlight = false

private func revalidate() {
    guard !revalidateInFlight,
          settings.licenseServerURL != nil,
          !(settings.licenseKey ?? "").isEmpty else { return }
    revalidateInFlight = true
    checkAgainButton.isEnabled = false
    let validator = licenseTransport.map { LicenseValidator(settings: settings, transport: $0) }
        ?? LicenseValidator(settings: settings)
    validator.validate { [weak self] _ in
        guard let self else { return }
        self.revalidateInFlight = false
        self.checkAgainButton.isEnabled = true
        self.refreshLicenseStatus()
    }
}
```
(The validator-construction line is copied from `LicenseSheetViewController.swift:193-194`.) `checkAgainTapped` calls `revalidate()`. In `viewWillAppear` (:271-274), after `syncFromLoginItem()`: if `settings.licenseStatus == nil`, call `revalidate()` (its guards make it a no-op without a server or key).

**10. `GeneralSettingsViewController.swift` — check-in disclosure (P1-2, pane half).** New `checkInDisclosureHint = SettingsForm.hintLabel(S3)` added to the rows array directly under the status row from step 9. In `refreshLicenseStatus()`: `checkInDisclosureHint.isHidden = !(serverConfigured && !key.isEmpty)` — disclosed exactly when a check-in can actually fire (`LicenseCheckIn.checkInIfNeeded` guards on key + endpoint).

**11. `GeneralSettingsViewController.swift` — AX labels + double-present guard (P1-6 pane half, P3-3).** Delete `setAccessibilityLabel` at :124, :130, :153, :166 (titles self-describe; :124's goes stale against the :223 title flip). KEEP :94 and :107 (switches). At the top of `enterLicenseTapped` (:237): `guard licenseSheet == nil else { return }`.

**12. `LoginItem.swift` + `GeneralSettingsViewController.swift` — `.requiresApproval` (P2-2).** Widen the seam: add to `LoginItemManaging` `var needsApproval: Bool { get }` and `func openSystemSettingsLoginItems()`, BOTH with default implementations in a `LoginItemManaging` extension (`false` / no-op) so the four existing conformers keep compiling untouched. `SMAppServiceLoginItem` implements them: `SMAppService.mainApp.status == .requiresApproval`, and the static `SMAppService.openSystemSettingsLoginItems()` (the `PTPHelperService.swift:122-124` wrap). In the pane: new hidden-by-default row under `launchRow` — horizontal stack of `SettingsForm.hintLabel(S5-hint)` and a `.small` `.rounded` button titled `Open Login Items…` whose action calls `loginItem.openSystemSettingsLoginItems()`. `syncFromLoginItem()` (:276-278) becomes the one funnel: sets the switch AND the approval row's `isHidden = !loginItem.needsApproval`. In `launchToggled` (:292-304), call `syncFromLoginItem()` on the SUCCESS path too — when the register lands in `.requiresApproval`, that reverts the switch and reveals the hint in one place.

**13. Test updates + additions — `SettingsRootViewControllerTests.swift`, `LicenseValidatorTests.swift`, `AppSettingsTests.swift`.**
String changes (verbatim): :203 → S1; :217, :235, :237 → S2. Fixtures: every `AUDR`→`AUDT` and `audr`→`audt` (10 in this file, 5 in `LicenseValidatorTests.swift`, 1 at `AppSettingsTests.swift:290`).
New pane hooks (follow the file's existing `test_` idiom, `_ = view` first): `test_checkAgainIsVisible`, `test_tapCheckAgain`, `test_checkInDisclosureText: String?` (nil when hidden), `test_loginApprovalHintIsVisible`, `test_tapOpenLoginItems`. New sheet hook: `test_buyIsVisible`.
`FakeLoginItem` (:27-39) gains `var approvalRequired = false` (backing `needsApproval`) and a counter-recording `openSystemSettingsLoginItems()`.
New tests (all in `SettingsRootViewControllerTests`, using the existing `makePaidBuildSettings`/`StubTransport`/`drainMainQueue` helpers):
- *Check Again revalidates in-session:* failing transport + registered key → status is S2 and `test_checkAgainIsVisible`; stub flips to `{"status":"active"}`; `test_tapCheckAgain`; drain → status is "Registered. Thank you for supporting Audiout." and Check Again hidden.
- *Surface-visible retry:* same setup, but call `general.viewWillAppear()` instead of the tap; drain → Registered.
- *Disclosure tracks the key:* unregistered → `test_checkInDisclosureText == nil`; after an active registration → equals S3; after `test_removeLicense()` → nil.
- *Rejected Register leaves an exit:* stub `{"status":"unknown"}`; open sheet via `test_tapEnterLicense`, type a key, register, drain → sheet still held, `test_resultText == S1`, and `test_removeIsVisible == true`.
- *Registered sheet is quiet:* after an active registration, `test_tapEnterLicense` → `test_buyIsVisible == false`.
- *requiresApproval reverts and explains:* `FakeLoginItem(enabled: false)` with `approvalRequired = true`; `test_toggleLaunchAtLogin(true)` → `test_launchAtLoginIsOn == false`, `test_loginApprovalHintIsVisible == true`; `test_tapOpenLoginItems` → fake's counter is 1.
`LicenseValidatorTests` request-shape test (~:84): add `#expect(request.timeoutInterval == 10)`.
`AppSettingsTests`: add (a) a `licenseUnregistered` truth-table test (empty key → true; key + nil status → false; key + each of unknown/invalid/revoked → true; key + active → false); (b) an https-guard test: settings with an https `licenseServerURL` override, then `settings.checkInURL = URL(string: "http://evil.example.com/checkin")!` → getter returns the DERIVED `https://…/v1/checkin`, not the stored http URL.

**14. `AppDelegate.swift:1295` — check-in on license change (P3-4; the ONE AppDelegate change).** Inside the existing `general.onLicenseChanged` closure, after `self?.applyLicenseState()`, add one statement that runs `LicenseCheckIn(settings: settings).checkInIfNeeded()` (adapt the capture — `settings` is reachable the same way :1290 reaches it). Accepted consequence, note in a one-line comment: the closure fires a few times around one registration, so the check-in may POST more than once; it is fire-and-forget, `/v1/checkin` always 204s, and the device-spread metric counts distinct install ids — duplicates are noise-free.

**15. — (removed; folded into step 3).**

**16. `dev/notes/license-key-generation-scheme-2026-08-23.md:35`.** Change the Key shape row's `AUDR` to `AUDT` and append a parenthetical note to that row: the deployed worker diverged from the original recommendation and issues `AUDT-` (verified from the deployed bundle 2026-08-27). Nothing else in the doc changes.

### Track B — About + pane hygiene (no dependency on Track A)

**17. `AboutView.swift` — real About values (P0-1 variant A).** Replace `AboutLinks` (:44-56): `static let sourceCodeURL = URL(string: "https://github.com/aa-hh/Audiout")!` and `static let supportEmail = "support@audiout.app"`; delete both `TODO(Alec)` comments (keep the one-line GPL source-availability rationale on the URL). In `loadView`: the Support body renders S7 (built by interpolating `supportEmail` so the constant stays the one place) and gets `isSelectable = true` so the address can be copied; `viewSourceCodeTapped` (:270) opens `AboutLinks.sourceCodeURL`; `test_supportContactText` (:283) returns the rendered S7.

**18. `AboutView.swift` — Privacy section (P1-2, About half).** Between the credits scroll view and the Support header, add a `Privacy` header in the exact style of the existing `Support` header (:200-203) with a caption body label styled like the Support body (:205-210) carrying S6. Expose `test_privacyText`.

**19. `AboutView.swift` — legible credits + window manners (P2-8, P2-9).** :251-252 → `creditsTextView.font = Tokens.Font.body`, `creditsTextView.textColor = Tokens.Color.label` (legal text is body text; the 200 pt scroll box at :266 stays). In `AboutWindowController.init` (:319-326): `window.isRestorable = false`. In `show()` (:334-341), after `setContentSize`: if the window is not already visible, `window?.center()` — before the `HeadlessRuntime` guard so sizing/centering stay headless-safe while ordering-front stays gated.

**20. `AboutView.swift` — AX label (P1-6, About slice).** Delete `sourceCodeButton.setAccessibilityLabel` (:186) — "View Source Code…" self-describes.

**21. `AboutSectionTests.swift`.** Replace the two placeholder-assertion tests (~:122-133) with one guard test: assert that `AboutLinks.sourceCodeURL.absoluteString`, the rendered support text, the privacy text, and `AboutCredits.thirdPartyNoticesText` each contain neither `"example.com"` nor `"TODO"`. (No build gating needed — the values are compile-time constants; this is the permanent regression fence the audit asked for.) Update the openURL-seam test (~:135-142) to expect `[URL(string: "https://github.com/aa-hh/Audiout")!]`. Add an assertion that `test_privacyText` equals S6. Do NOT raise the `< 450` compactness bound (~:150).

**22. `AudioSettingsViewController.swift` — hoist the running-apps snapshot (P1-8).** In `rebuildList()` (:714) take ONE snapshot before the loop:
```swift
let running = Dictionary(runningAppsProvider().map { ($0.bundleID, $0) },
                         uniquingKeysWith: { a, _ in a })
```
Thread it through `makeExcludedRow(_:running:)` into `icon(for:running:)` (:803), whose first branch becomes a dictionary lookup (`running[bundleID]?.icon`); the `NSRunningApplication` fallback (:808) and symbol fallback stay. The picker path (:827) keeps its own single call — untouched.

**23. `AudioSettingsViewController.swift` — one "Advanced" (P3-1).** At :420 replace `advancedTitle.setAccessibilityLabel("Advanced")` with `advancedTitle.setAccessibilityElement(false)` — the title is a click-target duplicate of the triangle (:405 keeps its label).

**24. `AppearanceSettingsViewController.swift` — own tracking area only (P3-2).** In `ThemeTileButton` (:266-273): keep the installed area in a `private var hoverTrackingArea: NSTrackingArea?`; `updateTrackingAreas` removes only that one (if any) before installing and storing the replacement — never `trackingAreas.forEach(removeTrackingArea)`.

---

## Out of scope — do not touch

- `Tokens.swift`, and ANY token swap toward `inkSecondary`/`warningText` (P1-5 and `AudioSettingsViewController.swift:592` belong to the tokens track).
- `scripts/make-app.sh` (T7), `PopoverController.swift`, `LicenseCheckIn.swift` internals, `dev/notes/` beyond the single row in step 16.
- No `audiout://register` handler, no client-side key normalization, no snapshot regeneration, no NWPathMonitor, no key-commit-deferral rework in `registerTapped` (the write-before-validate design stays; P2-3 is answered by `refreshButtons`), no renaming of existing `test_` hooks, no cleanup, no new abstractions, no error handling for impossible cases, no backwards-compat shims.
- Do not "fix" the theme tiles' absolute sRGB colors, the accent-blue selection ring (P3-6 is an ask for Alec, not a fix), or anything the sizing-trap comments protect.

## Verification

Run BOTH, in your session, after all steps — through the wrappers only (see the binding rule in the header), no `| tail`:

```bash
bash scripts/run-tests.sh --filter SettingsRootViewControllerTests --filter AboutSectionTests --filter LicenseValidatorTests --filter LicenseCheckInTests --filter AppSettingsTests --filter SettingsAccentAndHintsTests --filter AudioSettingsLatencyTests --filter AudioSettingsWakeRestoreTests --filter PreviewPaletteTokenPinTests
bash scripts/build.sh
```

Expected: every suite passes (baseline was 94 + 15 = 109 tests, all green, exit 0 — your run must show MORE than 109 tests, all passing, since the steps add tests) and the build exits 0. Done = these two commands ran in your session and passed; paste their final lines.

## Acceptance checklist

- [ ] `AUDT` appears in exactly one constant in `AudioutSettingsUI`; `grep -rni audr AudioutCore` finds nothing.
- [ ] About renders no string containing `TODO` or `example.com`; the guard test proves it and asserts the real URL/email.
- [ ] Registered state: sheet shows no Buy; rejected Register shows Remove in-sheet.
- [ ] Remove asks first (S4), Cancel is default, Remove is destructive-styled.
- [ ] Key stored + no verdict → S2 + visible Check Again; both retry paths (tap, appear) re-validate.
- [ ] S3 disclosure visible exactly when a key is stored on a server-configured build; About has the Privacy section (S6).
- [ ] The seven named `setAccessibilityLabel` deletions done; keyField/switch labels kept.
- [ ] One `runningAppsProvider()` call per `rebuildList()`.
- [ ] `AppDelegate.swift` diff is exactly one added statement (plus its comment).

## Execution plan

- **Track A** (steps 1–16): `AppSettings.swift`, `LicenseValidator.swift`, `LicenseSheetViewController.swift`, `GeneralSettingsViewController.swift`, `LoginItem.swift`, `AppDelegate.swift` (1 statement), `SettingsRootViewControllerTests.swift`, `LicenseValidatorTests.swift`, `AppSettingsTests.swift`, the dev/notes row. Model: **sonnet**, effort: **high** (stateful UI funnel + verbatim-string test discipline). Internally serial in the given order (steps 4 and 9 consume step 1's symbol).
- **Track B** (steps 17–24): `AboutView.swift`, `AudioSettingsViewController.swift`, `AppearanceSettingsViewController.swift`, `AboutSectionTests.swift`. Model: **sonnet**, effort: **medium**. **PARALLEL** with Track A — file sets fully disjoint.
- Branch is clean at fork; verification runs ONCE on the merged result of both tracks (the commands above).

## Executor rules (copy verbatim into the handoff prompt)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
