# Work order — app-side license soft check (2026-08-23)

Branch `claude/license-key-backend-cb2e78`, worktree
`.claude/worktrees/license-key-backend-cb2e78`. HEAD da337e3f already holds
the 054 pieces this builds on: `AppSettings.licenseKey / licenseCheckInConsent
/ installID / checkInURL`, `LicenseCheckIn.swift`, the License rows in
`GeneralSettingsViewController`, Sparkle wired in `AppDelegate`, and
`scripts/make-app.sh`'s `SPARKLE_FEED_URL`/`SPARKLE_ED_PUBLIC_KEY` gating.

The server this talks to is built and tested in
`~/Projects/Audiout License Server` (README there is the contract). Decided,
do not re-litigate: keys are opaque `AUDR-XXXXX-XXXXX-XXXXX-XXXXX`, validated
ONLY by the server; the app never blocks anything.

## Server contract used here

- `POST <server>/v1/validate` body `{"license_key": "..."}` → always 200,
  `{"status": "active"|"revoked"|"unknown"|"invalid", "key": "<canonical>", "max_major": 1}`
  (`key`/`max_major` only when status is active/revoked).
- `POST <server>/v1/checkin` body `{"license_key","install_id","app_version"}` → 204.
  This is exactly what `LicenseCheckIn` already sends.
- `GET <server>/appcast.xml` with header `Authorization: Bearer <key>` — the
  Sparkle feed. The same header rides along on the enclosure download.

## Tasks (all in this repo)

### T1 — `AppSettings` (AudioutCore/Sources/AudioutCore/AppSettings.swift)

1. Add `public var licenseServerURL: URL?` — read from
   `Bundle.main.object(forInfoDictionaryKey: "AudioutLicenseServerURL") as? String`,
   `URL(string:)`; nil when absent. A build run from source has no key in its
   Info.plist, so it has no server, no validation, no check-in and no buy
   prompt — it is the free build. Allow a test override: an initializer
   parameter `licenseServerURL: URL? = nil` stored on the struct, used when
   non-nil, else the bundle value. (Check `AppSettings.init` first and match
   its style; keep the existing `init(defaults:)` working unchanged.)
2. `checkInURL`: keep the stored-defaults override exactly as it is (tests use
   it), but fall back to `licenseServerURL?.appending(path: "v1/checkin")` when
   the stored value is unset. Rewrite its doc comment — the "absent by default,
   no code path sets it" claim and the "inert until a backend exists" razor
   comment in `LicenseCheckIn.swift` are now false; say what's true: the
   endpoint is derived from the bundle's license server, a source build has
   none.
3. Add `public enum LicenseStatus: String { case active, revoked, unknown, invalid }`
   (raw values = the server's strings) and
   `public var licenseStatus: LicenseStatus?` stored under key
   `"license.status"` (nil = never verified / no key). Setting `licenseKey` to
   nil must also clear `licenseStatus` (one setter does both).
4. `public var licenseMaxMajor: Int?` stored under `"license.maxMajor"`
   (0/absent → nil).

### T2 — `LicenseValidator` (new file AudioutCore/Sources/AudioutCore/LicenseValidator.swift)

Same shape as `LicenseCheckIn`: `public struct LicenseValidator` with
`init(settings: AppSettings, transport: @escaping Transport = LicenseValidator.defaultTransport)`
where `Transport = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void`
(default = `URLSession.shared.dataTask(...).resume()`).

`public func validate(completion: @escaping (Result) -> Void)` where
`public enum Result { case verified(LicenseStatus), unreachable, noServer, noKey }`:
- no `licenseServerURL` → `.noServer`, no request.
- no/empty `licenseKey` → `.noKey`, no request.
- POST JSON `{"license_key": key}` to `<server>/v1/validate`, `Content-Type: application/json`.
- On a 200 with a parsable `status` string that maps to `LicenseStatus`:
  write `settings.licenseStatus`, and when the response carries `key` write it
  back to `settings.licenseKey` (the server's canonical form), `max_major` →
  `settings.licenseMaxMajor`; complete `.verified(status)`.
- Any error / non-200 / unparsable body → `.unreachable`, settings untouched
  (last known state stands — the check is soft).
- Completion always on the main queue.

### T3 — General settings (AudioutCore/Sources/AudioutSettingsUI/GeneralSettingsViewController.swift)

1. `commitLicenseKey()` — after persisting, if the key is non-empty run
   `LicenseValidator(settings:).validate` and refresh the row's status line;
   if the key was cleared, refresh immediately. Inject the validator's
   transport through a new `public var licenseTransport: LicenseValidator.Transport?`
   (nil = default) so tests can stub it — same pattern as `onRunSetupAgain`.
2. Add a status line under the License key row: a `SettingsForm.hintLabel()`
   named `licenseStatusHint`, placed right after `licenseKeyRow` in the
   `paneView(rows:)` list. Copy, by state (all plain words, no jargon):
   - no server (`licenseServerURL == nil`): hint hidden (`isHidden = true`) —
     nothing to verify in a source build.
   - key empty: `"Unregistered. Buy a license to support Audiout and get updates."`
   - `.active`: `"Registered. Thank you."`
   - `.revoked`: `"This key was refunded or revoked. It no longer gets updates."`
   - `.unknown`: `"This key isn't recognised. Check it against your receipt."`
   - `.invalid`: `"That doesn't look like an Audiout key (AUDR-XXXXX-XXXXX-XXXXX-XXXXX)."`
   - key present, status nil (never reached the server): `"Couldn't reach the license server — will try again next launch."`
3. Add a "Buy Audiout…" `NSButton` (`.rounded`, `.small`, like
   `updatesButton`) to the footer strip, visible only when
   `licenseServerURL != nil` AND the key is empty or status ∈ {unknown,
   invalid, revoked}. It opens `AudioutBuyURL` from Info.plist via
   `NSWorkspace.shared.open`; when that key is absent the button is hidden
   too. Re-evaluate visibility whenever the status line is refreshed.
4. Test seams, same style as the existing `test_*` block:
   `test_licenseStatusText: String?` (nil when hidden),
   `test_buyButtonIsVisible: Bool`.

### T4 — Popover note (AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift ~line 982 onward)

Add a FOURTH, LOWEST-precedence note to the existing note-slot resolver
(`resolvedSystemAirPlayNote`): `private var unregisteredNoteActive = false`
+ `public func setUnregisteredNoteActive(_ active: Bool)` (idempotent, same
shape as `setSystemAirPlayNoteActive`) + `public var onBuyAudiout: (() -> Void)?`.
When active and nothing above it is: text
`"Audiout is unregistered. Buying a license keeps it updated."`, action
`Action(title: "Buy…", accessibilityLabel: "Buy an Audiout license", handler: onBuyAudiout)`,
severity `.info`. Update the PRECEDENCE comment block to list it last.
Register the new text as a `static let unregisteredNoteText`.

### T5 — AppDelegate (AudioutCore/Sources/AudioutApp/AppDelegate.swift)

1. Launch (next to the existing `LicenseCheckIn(...).checkInIfNeeded()` call,
   ~line 370): run `LicenseValidator(settings:).validate { _ in self.applyLicenseState() }`,
   then call `applyLicenseState()` once synchronously too (last known state
   before the network answers).
2. `applyLicenseState()`: computes `unregistered = settings.licenseServerURL != nil
   && (key empty || status ∈ {unknown, invalid, revoked})` and pushes
   `popoverController.setUnregisteredNoteActive(unregistered)`; ALSO sets
   `updaterController?.updater.httpHeaders = ["Authorization": "Bearer \(key)"]`
   when a key is present (nil dictionary when not). Call it again after the
   General pane commits a key — add `public var onLicenseChanged: (() -> Void)?`
   on `GeneralSettingsViewController`, fired at the end of every status
   refresh, wired in `openSettings` next to `onRunSetupAgain`.
3. `popoverController.onBuyAudiout` opens `AudioutBuyURL` (same helper as
   T3.3 — put one `static func buyURL() -> URL?` on `AppSettings` reading the
   plist key, used by both).

### T6 — scripts/make-app.sh (next to the Sparkle block ~line 668)

New optional env `AUDIOUT_LICENSE_URL` → `plutil -insert AudioutLicenseServerURL`,
and `AUDIOUT_BUY_URL` → `plutil -insert AudioutBuyURL`. Independent of the
Sparkle pair. When `AUDIOUT_LICENSE_URL` is set and `SPARKLE_FEED_URL` is
NOT, default `SPARKLE_FEED_URL` to `"$AUDIOUT_LICENSE_URL/appcast.xml"`
(the key check on `SPARKLE_ED_PUBLIC_KEY` still applies). Echo what was
written, like the neighbouring blocks.

Update `docs/RELEASE.md`'s env-var table / "the owner's actions" for the two new
vars and the R2 upload step described in the server README (`releases/...zip`,
`releases/latest-vN.json`, `appcast-vN.xml`) — replace the "appcast lives on
the website" step if present.

### T7 — PRODUCT.md line 58

Replace "The key is validated by an open-source signature check (no secrets in
the app) and additionally gates" with "The key is an opaque random string the
license server looks up (`/v1/validate`; offline, the app keeps its last known
answer) and it gates".

### T8 — Tests (Swift Testing, AudioutCore/Tests/AudioutCoreTests)

- `AppSettingsTests`: `licenseServerURL` nil by default and honours the init
  override; `checkInURL` derives from it; `licenseStatus` round-trips and is
  cleared with the key; `licenseMaxMajor` round-trips.
- New `LicenseValidatorTests` (model on `LicenseCheckInTests`): no server → no
  request; no key → no request; a stubbed 200 `{"status":"active","key":"AUDR-…","max_major":1}`
  writes status/key/max_major; stubbed error leaves settings untouched and
  completes `.unreachable`; a stubbed 200 `{"status":"unknown"}` sets status
  without touching the key.
- `GeneralSettingsViewController` tests (find the existing License tests — grep
  `test_setLicenseKey`): status text per state with a stubbed transport; buy
  button hidden with no server, visible when unregistered, hidden when active.
- `PopoverControllerTests`: the unregistered note shows/clears, has an action
  button, and loses the slot to `setSystemAirPlayNoteActive(true)`, returning
  when that clears (model on `systemAirPlayNoteShowsAndClears`, ~line 2678).

## Rules

- Read `AGENTS.md` at the repo root and the `AGENTS.md` in every folder you
  edit BEFORE editing there.
- Build with `bash scripts/build.sh`; tests with
  `bash scripts/run-tests.sh --filter "AppSettingsTests|LicenseValidatorTests|LicenseCheckInTests|GeneralSettings|SettingsRootViewControllerTests|PopoverControllerTests"`.
  NEVER bare `swift build`/`swift test`.
- `AboutSectionTests` has a General-pane height threshold (450) — if the new
  hint/button pushes past it, raise it and say so in the commit.
- No commit: leave the work uncommitted and report. Do not touch any other
  worktree. Do not regenerate snapshot goldens.
- Report: files changed, test command + the exact pass/fail line, anything
  you could not do.
