# P1 — Per-speaker connection status + failure diagnostics (design brief)

**IMPLEMENTED 2026-07-16, see SPEC §9.**

*2026-07-16. Approved by Alec. This is the single source of truth for the
connection-status build. Implementation agents: read this whole file, plus the
repo AGENTS.md and `AirPlayControllerCore/AGENTS.md`, before touching code.*

## 0. Problem + approved design (context)

Enabling an AirPlay speaker can silently fail: OwnTone's `PUT /api/outputs/set`
returns 204 **before** the speaker actually accepts the session, and a failed
activation just reverts `outputs[].selected` to `false` a moment later
(`dev/notes/p1-owntone-api-brief.md` §1/§4). Mid-stream, an output can also
silently deselect while the player still says "play" (the zombie case). Today
the only UI signal is `Device.isAvailable = false` (row greys out) — no
in-flight state, no explanation.

**Approved design (2026-07-16):**
- Per-device **connection state machine**: `off → connecting → connected`,
  `connecting → failed`, `connected → reconnecting → connected|failed`.
- **Honest toggle:** the row's `NSSwitch` only *rests* ON once the connection is
  verified. On failure it animates back OFF (via membership removal — see §7.3).
- **Status slot** in the device row between the `%` readout and the switch:
  spinner while connecting/reconnecting, **persistent green dot** while
  connected, orange warning triangle on failure. Plus a small **status sublabel**
  under the device name ("Connecting…", "Connected", "Reconnecting…",
  "Couldn't connect").
- **Inline diagnosis panel** (expands under the failed row, animated, like group
  expansion): one-line cause + one-line suggested action + "Try again" +
  "Copy details" buttons. Auto-expands once when a failure first appears;
  afterwards the warning icon toggles it.
- **Retry policy:** the backend's existing single automatic recovery attempt is
  covered by the "Connecting…"/"Reconnecting…" phase; after that, `failed` is a
  resting state and retry is manual ("Try again" button or toggling back on).
  No background auto-retry loops.
- **Diagnosis** ("why didn't it connect"): engine-log capture + Bonjour presence
  + TCP probe + auth flags, mapped to one plain-English cause + suggestion (§5).

## 1. State machine — semantics

State lives on `Device.connectionState` (a new field). **The backend owns it**
(both `MockBackend` and `OwnToneBackend`); the UI is a pure renderer. Membership
in the Selected Devices set stays where it is (`GroupController`), and routing
stays `setOutputSet`. No new `OutputBackend` protocol methods.

| State | Meaning | Entered when |
|---|---|---|
| `.off` | Not being routed to | Device not in the backend's expected-selected set (and not sticky-failed) |
| `.connecting` | Enable issued, not yet verified | Id newly appears in `setOutputSet` (including re-adding a `.failed` id = retry) |
| `.connected` | Selection verified stable | Confirm re-GET shows `selected:true` AND the next poll tick still shows it (stability window ≈ 1–2 s) |
| `.reconnecting` | Was connected, silently dropped, auto-recovery running | Zombie drop detected on a previously-`.connected` id |
| `.failed(ConnectionFailure)` | Enable/recovery exhausted | Selection reverted + one recovery attempt failed, or 10 s connecting timeout, or reconnect failed |

**Sticky-failed rules (important):**
- `.failed` **persists** when the id is later removed from the expected set —
  the popover removes set-membership as failure *cleanup* (§7.3), and that
  cleanup must not erase the warning.
- `.failed → .connecting` when the id re-appears in `setOutputSet` (retry).
- `.failed → .off` only when the device disappears entirely (`deviceRemoved`).
- On recovery failure the device **stays `isAvailable = true`** (it is on the
  network; the *session* failed). This CHANGES current behaviour, which marks it
  unavailable — update the existing tests that assert unavailable-on-recovery-
  failure. Engine-unreachable (connection refused) keeps the existing
  all-devices-unavailable behaviour, and additionally sets `.failed(.engineUnreachable)`
  is **not** used for that case — unreachable keeps `.off`/existing states; the
  greyed-out whole-list treatment already communicates it.

## 2. Core types (T1 — exact API)

New file `AirPlayControllerCore/Sources/AirPlayControllerCore/ConnectionState.swift`:

```swift
/// Live connection lifecycle of a device the app is (or was) routing to.
public enum ConnectionState: Equatable, Sendable {
    case off
    case connecting
    case connected
    case reconnecting
    case failed(ConnectionFailure)
}

/// Why an enable/stream failed, in user-presentable terms.
public struct ConnectionFailure: Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        case notResponding    // advertised but AirPlay service not answering
        case vanished         // no longer advertised on the network
        case refusedOrBusy    // refused/403 — often an exclusive session elsewhere
        case authRequired     // password / pairing needed (unsupported)
        case droppedMidStream // was connected, silently dropped, recovery failed
        case timedOut         // connecting never resolved within 10 s
        case unknown
    }
    public var cause: Cause
    /// Raw evidence (e.g. matched engine-log line). Backs "Copy details".
    public var detail: String?
    public init(cause: Cause, detail: String? = nil)
}
```

Presentation copy lives ON the type (single source of truth for UI):

```swift
extension ConnectionFailure {
    /// e.g. "Didn't respond" — short, sentence case, no terminal period.
    public var headline: String
    /// One sentence: what happened + what to do. Sentence case, ends with period.
    public var suggestion: String
}
```

| Cause | headline | suggestion |
|---|---|---|
| notResponding | `Didn't respond` | `The speaker is visible on the network but isn't answering AirPlay requests — it may be stuck or held by another app. Power-cycle it, then try again.` |
| vanished | `Not on the network` | `The speaker is no longer visible on the network. Check that it's powered on and on the same Wi-Fi, then try again.` |
| refusedOrBusy | `Connection refused` | `The speaker refused the connection — another device may hold an exclusive session. Stop playback from other apps or restart the speaker, then try again.` |
| authRequired | `Password required` | `This speaker requires a password or pairing, which isn't supported yet.` |
| droppedMidStream | `Connection dropped` | `The speaker dropped the stream and reconnecting failed. Check the speaker, then try again.` |
| timedOut | `Took too long` | `The connection attempt didn't complete. The speaker or network may be busy — try again.` |
| unknown | `Couldn't connect` | `The connection failed for an unknown reason. Try again, or check the speaker.` |

`Device` gains a **last** init parameter `connectionState: ConnectionState = .off`
and a `public var connectionState`. Keep `Equatable` derived (state changes must
flow through the existing diff/echo machinery as `deviceUpdated`).

Diagnosis seam (types only in T1; implementation is T3):

```swift
public struct DiagnosisContext: Sendable {
    public var deviceID: String
    public var deviceName: String
    public var requiresAuth: Bool       // OwnTone has_password || requires_auth || needs_auth_key
    public var priorCause: ConnectionFailure.Cause  // what the backend already inferred (e.g. .timedOut, .droppedMidStream, .unknown)
}
public protocol ConnectionDiagnosing: Sendable {
    /// Investigate a failure and return the best-evidence ConnectionFailure.
    /// Must complete within ~4 s (probes are bounded); never throws.
    func diagnose(_ context: DiagnosisContext) async -> ConnectionFailure
}
```

## 3. OwnToneBackend state emission (T2)

All state in a new `connectionStates: [String: ConnectionState]` dict on
`stateQueue`; folded into every snapshot in `mapOutput`/`merge` so `Device`
carries it and diffs emit `deviceUpdated` naturally.

Transition hooks (all exist today — add state changes, don't restructure):
- `setOutputSet`: ids newly in `expectedSelected` → `.connecting` (emit
  immediately via `applyLocal`); ids leaving → `.off` **unless currently
  `.failed`** (sticky). Start a per-id 10 s timeout (generation-token guarded)
  → if still `.connecting`/`.reconnecting` when it fires → enter failure flow.
- `confirmSelectionOrRecover`: ids confirmed selected stay `.connecting`; mark
  them "pending-stable"; on the NEXT `applyPoll` where they're still selected →
  `.connected`. Missing ids → recovery (state stays `.connecting`).
- Zombie detect in `applyPoll` (id was `.connected`, expected, now unselected,
  not recovering) → `.reconnecting` before `recoverZombies` runs.
- `recoverZombies` success → `.connected` (clear recovering, cancel timeout).
  Failure → **failure flow**, and (changed behaviour, §1) do NOT set
  `isAvailable = false`.
- **Failure flow:** set `.failed(ConnectionFailure(cause: priorCause))`
  immediately (priorCause: `.droppedMidStream` from reconnecting, `.timedOut`
  from timeout, else `.unknown`), emit, then fire-and-forget a `Task` calling
  the injected `diagnostics: ConnectionDiagnosing?` (new `public var`, nil
  default; wired in `makeBackend` by T7). When diagnosis returns, if the device
  is STILL `.failed`, replace with the diagnosed failure and emit again.
- `markUnreachable` / engine recovery: leave connectionStates alone except
  cancelling pending timeouts; unreachable presentation stays the existing
  greyed-unavailable treatment.
- Keep the latest raw auth flags per id (from `OwnToneOutput`) in an internal
  dict for `DiagnosisContext.requiresAuth`.

Tests (`OwnToneBackendTests`, stubbed `StubURLProtocol`): connecting emitted on
set; connected after confirm+stable poll; select-revert → failed with sticky
semantics across a follow-up `setOutputSet` that drops the id; re-adding a
failed id → connecting; zombie → reconnecting → connected on recovery;
reconnecting → failed(droppedMidStream) when recovery fails AND isAvailable
stays true (update the old assertions); timeout path with a never-confirming
stub; diagnosis replacement (inject a fake `ConnectionDiagnosing`).

## 4. Diagnostics service (T3)

New file `AirPlayControllerCore/Sources/AirPlayControllerCore/ConnectionDiagnostics.swift`.
`public struct NetworkConnectionDiagnostics: ConnectionDiagnosing` with
injectable probe seams so unit tests never touch the network:

```swift
public init(
    bonjour: @Sendable (_ deviceName: String) async -> BonjourPresence = ...,
    tcpProbe: @Sendable (_ endpoint: BonjourPresence.Endpoint) async -> TCPProbeResult = ...,
    logTail: @Sendable () -> String? = ...,   // last ~32 KB of the engine log, nil if unavailable
    now: @Sendable () -> Date = Date.init
)
```

Decision order (first hit wins):
1. `context.requiresAuth` → `.authRequired`.
2. **Engine log** (dev-only, best-effort): path from env `AIRPLAY_OWNTONE_LOG`,
   default `dev/owntone/log/owntone.log` relative to CWD; unreadable → skip.
   Scan the tail for lines containing the device name (case-insensitive),
   newest first. Patterns → causes: `No response from` → `.notResponding`;
   `403` → `.refusedOrBusy`; `auth`/`pair`/`password` → `.authRequired`;
   `failed to activate` (alone) → keep probing but retain the line as `detail`.
   The matched raw line(s) always become `ConnectionFailure.detail`.
3. **Bonjour presence** (`NWBrowser`, `_raop._tcp` + `_airplay._tcp`, bounded
   ~2 s): match `_airplay` instance name == device name, or `_raop` name
   suffix `"@\(deviceName)"`. Absent from both → `.vanished`.
4. **TCP probe** of the matched service endpoint (`NWConnection`, 3 s bound):
   `.ready` → `.notResponding` (reachable, but the session failed);
   refused → `.refusedOrBusy`; timeout → `.notResponding`.
5. Nothing conclusive → `context.priorCause` (or `.unknown`), keeping any
   log-line detail.

Real `NWBrowser`/`NWConnection` default closures live behind the seams; tests
drive the decision matrix purely with injected closures (every row above gets a
test). `import Network` (macOS 13 target — fine).

## 5. MockBackend failure scripting (T4)

Scripted per-device connect choreography so ALL states are buildable/demoable
offline (mock is the primary rig — real speakers currently unavailable):

```swift
public struct ConnectScript: Sendable {
    public enum Attempt: Sendable {
        case connect(after: TimeInterval)
        case fail(after: TimeInterval, ConnectionFailure)
        case connectThenDrop(connectAfter: TimeInterval, dropAfter: TimeInterval, recovers: Bool)
    }
    /// Nth enable of the device uses attempts[N-1]; the last entry repeats.
    public var attempts: [Attempt]
}
```

`MockBackend.init` gains `connectScripts: [String: ConnectScript] = [:]`.
**Un-scripted devices keep EXACT current synchronous behaviour** (one
`deviceUpdated` with `isSelected = true` — but now also
`connectionState = .connected` in that same event; deselect → `.off`) so the
existing test suite stays valid. Scripted devices: enable → `.connecting`
(selected stays false) → per attempt: `.connected` + `isSelected = true`, or
`.failed(f)` + `isSelected = false` (sticky per §1). `connectThenDrop`: connect,
then after `dropAfter` → `.reconnecting` (~1.5 s) → `recovers ? .connected :
.failed(droppedMidStream)`. Re-enable of a failed device = next attempt.
All timers on the mock's `queue`; everything deterministic given the script.

Env scenario knob (parsed in `MockBackend`, injectable environment dict):
`AIRPLAY_MOCK_SCENARIO=connection-demo` →
- `airport-mixer`: `[.fail(after: 1.5, .init(cause: .notResponding)), .connect(after: 1.0)]`
  (first enable fails → warning + panel; "Try again" succeeds — demos retry).
- `sonos-move-2`: `[.connect(after: 4.0)]` (long spinner).
- `office`: `[.connectThenDrop(connectAfter: 0.8, dropAfter: 8, recovers: false)]`
  (demos mid-stream drop → reconnecting → failed).
- everything else: `[.connect(after: 0.8)]`.
Factory: `static func connectionDemoScripts() -> [String: ConnectScript]` +
resolve-from-environment helper used by whoever constructs the mock.

## 6. Row UI (T5) — `DeviceRowView` + `PopoverColumnGrid`

- **Status slot**: fixed-width view column between the `%` readout and the
  ENABLED switch column. Add grid constants (`PopoverColumnGrid.statusWidth`
  ≈ 18, `readoutToStatus` ≈ 6); adjust `trailingControlCenterFromTrailing` /
  panel width if needed so nothing crowds (snapshot verifies). Contents by state:
  - `.connecting` / `.reconnecting`: `NSProgressIndicator`, `style = .spinning`,
    `controlSize = .small`, `isDisplayedWhenStopped = false`, animating.
  - `.connected`: `NSImageView`, SF Symbol `circle.fill` at ~8 pt,
    `contentTintColor = .systemGreen`.
  - `.failed`: borderless `NSButton` (imageOnly), SF Symbol
    `exclamationmark.triangle.fill` ~12 pt, tint `.systemOrange`; click →
    `delegate.deviceRow(_:didRequestDiagnosisFor:)` (new Delegate method with
    default no-op, same back-compat pattern as `didToggleEnabled`).
  - `.off`: empty.
- **Status sublabel**: name becomes a two-line vertical stack (name on top,
  status line under, `systemFont(ofSize: 10)`), centered in the unchanged
  38 pt row; sublabel hidden for `.off`. Text/color: "Connecting…"/"Reconnecting…"
  (`.secondaryLabelColor`), "Connected" (`.systemGreen`), "Couldn't connect"
  (`.systemOrange`). If 38 pt visually crowds (snapshot check), bump
  `rowHeight` to 42 — a constant change, allowed.
- The row renders `device.connectionState` passed via the existing
  `apply(_:selected:blocked:blockReason:)` (state is ON the Device — no new
  parameter). Switch state remains driven by membership (`selected`), never by
  connection state (§7.3 keeps them consistent).
- Accessibility label gains the state ("…, connecting", "…, connected",
  "…, couldn't connect"). Warning button label: "Show connection problem for
  \(name)".
- Test hooks: `test_statusKind` (enum: none/spinner/connectedDot/warning),
  `test_statusText: String?`, `test_tapWarning()`.
- The mixer window shares this row and gets the indicator for free; panel/
  retry wiring is popover-only for now (mixer follow-up is out of scope).

## 7. Popover integration (T6 panel view, T7 wiring)

### 7.1 `ConnectionDiagnosisView` (T6 — new file in AirPlayControllerPopoverUI)
Inset panel matching the mockup: warning-tinted rounded background
(`NSColor.systemOrange.withAlphaComponent(0.12)`, radius 7, inset to align with
the name column), containing: headline (`boldSystemFont(ofSize: 11)`), wrapping
suggestion body (`systemFont(ofSize: 11)`, `.secondaryLabelColor`), and a
buttons row: "Try again" + "Copy details" (`NSButton`, `bezelStyle = .rounded`,
`controlSize = .small`; Copy details `isEnabled` iff `failure.detail != nil`).
API: `apply(failure: ConnectionFailure, deviceName: String)`;
`var onRetry: (() -> Void)?`; `var onCopyDetails: (() -> Void)?` (host does the
pasteboard write). Self-sizing via Auto Layout (wrapping label widths pinned).
Accessibility + `test_headlineText` / `test_suggestionText` / `test_tapRetry()`
hooks.

### 7.2 Panel insert/remove (T7 — `PopoverPanelViewController`)
Add `insertRow(_ view: NSView, after sibling: NSView, animated: Bool)` and
`removeRow(_ view: NSView, animated: Bool)` using the same animation approach
as group expansion (see `GroupRowView`/panel expansion code).

### 7.3 `PopoverController` wiring (T7)
- Track `lastConnectionStates: [String: ConnectionState]`. In
  `update(devices:)`, detect transitions:
  - **→ `.failed`**: if the device is currently in the Selected Devices set,
    call `groupController.setDeviceSelected(id, false)` (honest-toggle cleanup;
    backend keeps `.failed` sticky per §1 so the warning survives the resulting
    `setOutputSet`). Auto-expand the diagnosis panel for that row ONCE per
    failure episode; afterwards the warning button toggles it.
  - **→ `.connected` / `.off`**: remove any shown panel for that id.
- `deviceRow(_:didRequestDiagnosisFor:)` toggles the panel.
- Panel `onRetry`: `groupController.setDeviceSelected(id, true)` (the toggle-on
  path IS the retry path), then refresh. `onCopyDetails`: write
  `failure.detail ?? headline+suggestion` to `NSPasteboard.general`.
- `rebuild()` re-creates panels for devices currently `.failed` with an open
  panel (persist open-panel ids in a `Set<String>`).
- Wire concrete diagnostics: in `makeBackend(_:)` (OwnToneBackend.swift), set
  `backend.diagnostics = NetworkConnectionDiagnostics()`; construct `MockBackend`
  with scenario scripts resolved from the environment.
- Test hooks: `test_diagnosisPanel(for id: String) -> ConnectionDiagnosisView?`,
  `test_tapRetry(for id:)`. Tests: failed transition removes membership +
  shows panel; retry re-adds; connected clears panel; sticky warning survives
  the cleanup `setOutputSet`.

## 8. Verification (T8) + docs

- Full `swift build` + `swift test` + `swift run popover-harness` +
  `swift run window-harness` green.
- popover-harness gains PASS/FAIL checks for the §7.3 flow using a scripted
  MockBackend (fail → toggle bounced + warning; retry → connected).
- `popover-snapshot`: new mode (env or arg) rendering a fleet with explicit
  states — one row per state + one open diagnosis panel — to
  `dev/notes/popover-snapshots/popover-connection-{light,dark}.png`; visually
  inspect the PNGs against §6/§7 (alignment, crowding, colors in both modes).
- Docs: SPEC.md §9 device-row table gains the status slot/sublabel/diagnosis
  panel rows + a short "Connection status & diagnostics (2026-07-16)" note
  (state machine, honest-toggle rule, sticky-failed, retry policy);
  `AirPlayControllerCore/AGENTS.md` updated if it describes the row anatomy or
  backend event semantics.

## 9. Task ownership / file map (do not cross)

| Task | Owns (edit) | Must not touch |
|---|---|---|
| T1 | `ConnectionState.swift` (new), `Device.swift`, `OutputBackend.swift` (docs only), new `ConnectionStateTests.swift` | backends, UI |
| T2 | `OwnToneBackend.swift`, `OwnToneClient.swift` (if needed), `OwnToneBackendTests.swift` | MockBackend, UI, ConnectionDiagnostics.swift |
| T3 | `ConnectionDiagnostics.swift` (new), `ConnectionDiagnosticsTests.swift` (new) | backends, UI |
| T4 | `MockBackend.swift`, `MockBackendTests.swift`, `mock-speakers-demo` (optional) | OwnToneBackend, UI |
| T5 | `DeviceRowView.swift`, `PopoverColumnGrid.swift`, row-focused tests | PopoverController, panel VC |
| T6 | `ConnectionDiagnosisView.swift` (new in PopoverUI) + its tests | everything else |
| T7 | `PopoverController.swift`, `PopoverPanelViewController.swift`, `makeBackend` in `OwnToneBackend.swift`, `AppDelegate.swift` (if wiring needed), `PopoverControllerTests.swift`, `popover-harness` | — (integration owns the seams) |
| T8 | `popover-snapshot`, SPEC.md, AGENTS.md files, PLAN notes | implementation files (report, don't fix) |

Build/test from `AirPlayControllerCore/`: `swift build`, `swift test`,
`swift run popover-harness`. Never launch the real OwnTone server; never touch
`dev/owntone/` state. GPL headers: match neighbouring files (SharedUI/PopoverUI
files carry the SPDX header; core files currently don't — follow the directory's
existing convention).
