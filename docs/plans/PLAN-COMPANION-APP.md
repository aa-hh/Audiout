# PLAN — Companion iPhone App

*2026-07-26. Planned on Fable at Alec's request; all ten open questions answered by
Alec this session; model assignments cost-checked (four effort downgrades applied,
all Opus assignments upheld). Builds on dev/notes/companion-app-research.md.
Status: awaiting Alec's approval to execute. Execution: /orchestrate picks this up.*

All paths relative to the repo root. Everything cited was verified in source during
planning: `GroupController` publishes nothing and exposes every needed command
(`GroupController.swift:274` setDeviceSelected→SelectionResult, `:351` retryConnection,
`:408` setMainOut, `:539` createGroup, `:507` saveGroup, `:577` deleteGroup, `:710`
setMemberVolume, `setMainOutMasterVolume` (a stateless set since the volume
decoupling — the drag brackets this plan originally cited are deleted), `:977-1008`
mute at all levels);
`AppRoutingController.onRoutesDidChange` is single-assignment, claimed at
`AppDelegate.swift:393`; `DeviceIconController.onChange` claimed at
`PopoverController.swift:242`, chain-wrapped at `MixerWindowController.swift:214-215`;
`NativeBackend.makeEventStream()` (`NativeBackend.swift:1060-1076`) is
per-caller-independent and replays the device snapshot; `DACPServer.swift` +
`DACPServerTests.swift:107-158` are the server/loopback templates; buffer apply path is
`AppDelegate.swift:1055-1062` (persist then async `applyStartBuffer`, audible ~3-5 s
gap); connect volume needs no push — `NativeBackend.connectVolumeSeed` reads
`AppSettings.connectVolume` live on next connect (`AudioSettingsViewController.swift:99-101`);
`docs/SPEC.md:30` still says "Mac only (no phone app)"; mock is explicit-opt-in-only
(`OwnToneBackend.swift:783-826`).

## Decisions (locked by Alec, 2026-07-26)

| # | Decision |
|---|---|
| D1 | Mac-side toggle: Settings › General checkbox. Default OFF while only the Mac side has merged; flipped ON (T22) in the release that ships with the phone app. Dev env override `AUDIOUTER_COMPANION` (explicit, never silent). |
| D2 | Trust: open to anyone on the same Wi-Fi, Sonos-style. `hello.clientName` carried from day one so per-phone approval can be added later with no wire change. |
| D3 | App name: decided later. Working name "AudiouterRemote" (rename-safe); T23 renames before App Store Connect setup. |
| D4 | Four tabs: Speakers / Apps / Groups / Connection+Settings (current Mac, switch Mac, demo mode, about, phone settings, remote Mac settings per D10). |
| D5 | Device icons: phone shows the Mac's custom SF Symbol icons, read-only. |
| D6 | iPhone-only at launch; iPad runs it in compatibility mode. |
| D7 | Minimum iOS 18. |
| D8 | Ship timing: Mac side (Phase 1) merges EARLY, default OFF, behind its own Mac-only live gate (T21). Phone work continues on a follow-up branch off merged main. |
| D9 | Status detail: full parity — per-speaker failure headline/suggestion + "Try again", local-fallback banner, takeover strip. |
| D10 | Remote Mac settings on the phone: connect volume + audio buffer ms ONLY. Sync offset, excluded apps, theme stay Mac-only. Buffer uses an explicit "Apply & Reconnect" button (audible gap), never a live control. |

Scope fixed earlier: native iPhone app, public App Store, full popover surface + groups
CRUD, live shared state, multiple clients, no VU meters, phone-native tab UI.

### D2 REVISED 2026-07-26 — per-phone approval (supersedes open-LAN)

Adversarial security review surfaced information D2 was not decided against: the
snapshot broadcasts the names of apps currently playing audio to every connected
peer. Sonos exposes speakers, not your running apps — so "open like Sonos" understates
what open-LAN means here. Alec's call: **add a one-time approval per phone.** The Mac
asks once ("Allow 'Alec's iPhone' to control?"), remembers the answer, and only
approved phones are welcomed.

Delivered as task T24 (below), after the review-fix wave. The wire already carries
`hello.clientName`; T24 adds a stable per-phone identity, an approvals store, the Mac
prompt, a revoke path in Settings, and an "awaiting approval" state on the phone.
The pending-pool seam introduced by the FIX-A cap work is where the gate slots in.

## Architecture (end state)

New dependency-free Swift package `AudiouterProtocol/` (repo-root sibling of
AudiouterCore — sibling, not a target, because AudiouterCore's manifest shells out to
`brew --prefix` and drags the AirPlayEngine graph; the iOS app must depend on a
Foundation-only graph). The Mac app grows `CompanionServer` (NWListener +
NWProtocolWebSocket, Bonjour `_audiouter._tcp`, TXT `{proto, name}`, DACPServer-style
serial-queue confinement), `CompanionSnapshotBuilder` (pure mapper over the existing
controllers), `CompanionCommandDispatcher` (MainActor, calls the exact controller
methods the popover calls), and a coalesced broadcaster wired at the AppDelegate
coordination layer — all provable with loopback WebSocket tests before any iOS code.
A new iOS 18 SwiftUI app under `ios/` consumes only `AudiouterProtocol`, discovers via
`NWBrowser`, connects via `NWConnection`+WebSocket, renders four tabs, handles
permission-denial/backgrounding/Wi-Fi honestly, ships a visible opt-in Demo system.

Server = source of truth. Full snapshot on connect, then coalesced (~50 ms)
full-snapshot broadcasts suppressed when `Equatable`-identical — a deliberate
simplification vs the research doc's snapshot+delta design (state is tiny; SwiftUI
diffs on render; the envelope leaves room for a `delta` message type later).

## Protocol sketch (T1 implements exactly this)

`AudiouterProtocol/Package.swift` platforms `[.macOS(.v14), .iOS(.v18)]`, zero deps.

**Constants** (`CompanionProto.swift`): `serviceType = "_audiouter._tcp"`,
`version = 1`, TXT keys `proto` / `name`. Client refuses TXT `proto` greater than its
own (refuse-forward, mirroring `AppRouteStore.swift:154`).

**Envelope:** every WebSocket text frame is JSON `{"v": Int, "type": String,
"payload": {…}}`. Unknown keys ignored; client ignores unknown server types; server
answers unknown commands with a failed `commandResult`, never crashes.

**Messages** (`CompanionMessage.swift`):
- client→server: `hello {clientName, protoVersion}` · `command {requestID, command}`
- server→client: `welcome {serverName, protoVersion, snapshot}` · `state {snapshot}` ·
  `commandResult {requestID, applied, refusalReason?, autoSwappedCurrentDevice}` ·
  `goodbye {reason}` (disabled / shutdown / proto mismatch)

**Snapshot** (`CompanionSnapshot.swift`) — full state, `Equatable`:

```
Snapshot { serverName, devices: [DeviceState], mainOut: MainOutState,
           mainOutMasterVolume: Int, mainOutMuted: Bool,
           groups: [GroupState], activeGroupID: String?,
           appRoutes: [AppRouteState], liveRoutedAppNames: [deviceID: [appName]],
           addableApps: [{bundleID, displayName}],
           localFallbackActive: Bool, takeoverStatus: String?,
           settings: { connectVolume, connectVolumeMin, connectVolumeMax,
                       startBufferMs, startBufferOptionsMs: [Int] } }
DeviceState { id, name, kind /* Device.Kind.rawValue */,
              iconSymbolName /* resolved, incl. Mac-side overrides */,
              isAvailable, supportsAirPlay2, isLocalDevice, volume,
              isMuted /* GroupController.isMuted — NOT Device.isMuted */,
              isSelected /* GroupController.isSpeakerSelected — NOT Device.isSelected */,
              isMainOutMember,
              connection: {state, failureHeadline?, failureSuggestion?} }
GroupState { id, name, memberIDs, memberVolumes, iconSymbolName?, isMuted }
AppRouteState { bundleID, displayName,
                destinationKind /* "noRedirect"|"currentDevice"|"device" */,
                deviceID?, volume, isRunning }
MainOutState { kind: "selected"|"group", groupID? }  // RoutingStore.State:31-51 idiom
```

Settings ranges/options ship in the snapshot so the Mac stays authoritative; a future
option change needs no phone update.

**Commands** (`CompanionCommand.swift`) — all 1:1 with existing paths
(`beginMainOutDrag`/`endMainOutDrag` were later DELETED with the Mac's volume
decoupling — Main is a stored gain, so `setMainOutMasterVolume` is a plain
stateless set and no drag bracket exists):
`setDeviceSelected(id, selected)` · `retryConnection(id)` · `setMainOut(MainOutState)` ·
`setDeviceVolume(id, v)` · `setDeviceMuted(id, muted)` ·
`setMainOutMasterVolume(v)` · `setMainOutMuted(muted)` ·
`createGroup(name, memberIDs, iconSymbolName?)` · `updateGroup(GroupState)` ·
`deleteGroup(id)` · `setGroupMuted(id, muted)` · `addAppRoute(bundleID, displayName)` ·
`removeAppRoute(bundleID)` · `setAppDestination(bundleID, kind, deviceID?)` ·
`setAppVolume(bundleID, v)` · `setConnectVolume(v)` · `setStartBufferMs(ms)`.

Buffer semantics: `applied` = accepted-and-started; apply causes an audible ~3-5 s gap
(stream teardown/re-establish per `OutputBackend.swift:345-359`), hence the phone's
explicit Apply & Reconnect button (D10).

## Task list

Model/effort final (cost-check applied: T3, T4, T12, T16 effort high→medium; all
other assignments upheld, including the three Opus tasks).

### Phase 1 — protocol + Mac server (mergeable unit: T1-T9 + T21, gate = T21 + Alec go-ahead)

**T1 — `AudiouterProtocol` package** · new-code · deps: — · **sonnet 5, medium**
Files: NEW `AudiouterProtocol/{Package.swift, Sources/AudiouterProtocol/{CompanionProto,CompanionMessage,CompanionSnapshot,CompanionCommand}.swift, Tests/AudiouterProtocolTests/CompanionMessageTests.swift, AGENTS.md}`; EDIT `AudiouterCore/Package.swift:120-126` (path dep) + `:137-146` (target dep).
Implements the protocol sketch exactly. Verify: `cd AudiouterProtocol && swift test`
(round-trip every message/command/snapshot permutation, unknown-key tolerance,
refuse-forward); AudiouterCore still builds.

**T2 — Change hooks on pure-model controllers** · backend · deps: — · **sonnet 5, high**
Files: `GroupController.swift` (HOT), `ExcludedAppsController.swift`, tests in
`GroupControllerTests.swift` + `ExcludedAppsTests.swift`.
Add single-assignment `onStateDidChange: (() -> Void)?` to GroupController, fired after
every public mutation that actually changed pure-model state — fire sites:
setDeviceSelected both branches (:289-292/:312-314), setMainOut (:411), saveGroup
(:514), deleteGroup (:581), activateGroup (:609), deactivateGroup (:629),
setMuted/applySilence edge (:981), syncActiveGroupToSelection when changed (:490-495),
ensureDefaultSelection (:169). NOT on no-op early returns; NOT on pure-backend-write
paths (setMemberVolume, setMainOutMasterVolume) — those echo back as
`deviceUpdated` events. Same `onChange` on ExcludedAppsController (exclude/remove;
`git grep` all mutation call sites first — risk R3). Verify: fire-on-change +
no-fire-on-no-op tests per method.

**T3 — `CompanionSnapshotBuilder`** · new-code · deps: T1 · **sonnet 5, medium**
Files: NEW `AudiouterCore/Sources/AudiouterCore/CompanionSnapshotBuilder.swift` + tests.
Pure `static build(...)` over (devices, groupController, appRouting,
excludedBundleIDs, iconFor closure — injected because DeviceIconController lives in
AppKit-importing AudiouterSharedUI and Core stays AppKit-free, addableApps,
runningRouted, liveRoutedAppNames, localFallbackActive, takeoverStatus, serverName,
settings values+options). Traps encoded as tests: `DeviceState.isSelected` from
`isSpeakerSelected(_:)` never `Device.isSelected`; `isMainOutMember` from
`isMainOutMember(_:)`; `isMuted` from `GroupController.isMuted(_:)` never
`Device.isMuted`; excluded apps absent from `addableApps` and `appRoutes`.

**T4 — `CompanionCommandDispatcher`** · new-code · deps: T1 · **sonnet 5, medium**
Files: NEW `CompanionCommandDispatcher.swift` + tests.
MainActor; holds GroupController + AppRoutingController + injected closures
(`setLocalPlaybackVolume` mirroring `AppDelegate.swift:416-420`, `isExcluded`,
`applyStartBuffer` implementing the `:1055-1062` persist+async-apply path, plus
AppSettings access for connectVolume — clamped write, no push needed, seed reads live).
`execute(_:) -> (applied, refusalReason?, autoSwap)`: maps all 18 commands to the exact
existing methods; round-trips SelectionResult (:203-217); maps
`GroupError.emptyMembership` (:508) to a refusal string; refuses addAppRoute for
excluded bundles and `.device` destinations for unknown device IDs; validates
setStartBufferMs against options; setAppVolume also calls setLocalPlaybackVolume for
`.currentDevice` routes; unknown command → applied:false. Verify: one test per command incl. refusal cases,
MockBackend-backed real controllers, temp-dir stores.

**T5 — `CompanionServer`** · new-code · deps: T1 · **opus 4.8, high**
Files: NEW `CompanionServer.swift` + `CompanionServerTests.swift`.
DACPServer-structured: private serial queue owning listener/clients,
start(name:)/stop() with the startLocked/stopLocked deadlock-avoidance pattern
(`DACPServer.swift:108-182`), ephemeral port, `NWListener.Service(name:, type:,
txtRecord: {proto, name})`, NWProtocolWebSocket in the parameter stack. Per-connection:
10 s handshake timeout (idle pattern :196-229), goodbye on proto>version, client cap
(16), message-size cap, malformed frame closes offender only. API: `onCommand`
(server-queue; wiring hops to main), `broadcast(Data)` caching latest for
welcome-replay to new clients, `onClientCountChanged` (drag safety). `accept(_:)`
internal for tests; loopback binds only (firewall lesson,
`DACPServerTests.swift:66-78`). Verify: loopback WebSocket clients —
handshake→welcome-with-snapshot, command round-trip, broadcast to two clients,
proto-refuse, idle cancel, stop() cancels all; zero firewall prompts.

**T6 — Settings toggle plumbing** · new-code · deps: D1/D8 · **sonnet 5, low**
Files: `AppSettings.swift` (new key `companion.allowRemoteControl`, **default OFF**),
`AudiouterSettingsUI/GeneralSettingsViewController.swift` (checkbox + change callback),
`AudioSettingsViewController.swift` (new `onSettingChanged` callback fired from
`connectVolumeChanged` and the buffer-apply closure — so Mac-side settings edits
trigger broadcasts; cleaner than adding hooks to AppSettings), tests in
`AppSettingsTests.swift`. Env override `AUDIOUTER_COMPANION` (explicit opt-in/out,
`AIRPLAY_BACKEND` knob style). AppDelegate reaction lands in T7 (file-disjointness).

**T7 — AppDelegate wiring** · backend · deps: T2-T6 · **opus 4.8, high**
Files: `AudiouterCore/Sources/AudiouterApp/AppDelegate.swift` ONLY (HOT — sole owner
in its wave).
(1) Instantiate/start CompanionServer per T6 setting+env with
`Host.current().localizedName`; stop/start on setting change. (2) Broadcast triggers →
one ~50 ms main-queue coalescer: tail of `apply(event:)` (:1315-1327);
`groupController.onStateDidChange`; EXTEND the existing onRoutesDidChange closure at
:393 (single-assignment — never reassign); `excludedApps.onChange`; chain-wrap
`deviceIconController.onChange` AFTER popover configuration using the
previousIconChange idiom (`MixerWindowController.swift:214-215`; popover assigns at
`PopoverController.swift:242` — order matters, risk R2); the Audio-pane
`onSettingChanged`; existing NSWorkspace launch/terminate observers (:447-472) for
addableApps/isRunning freshness. (3) Coalescer rebuilds via CompanionSnapshotBuilder
on main (icons from `deviceIconController.symbolName(for:)`, addable apps from
`PopoverController.defaultRunningAppsProvider()` minus excluded/routed,
liveRoutedAppNames from routedAppNamesByDeviceID, fallback/takeover cached from
apply(event:), settings from AppSettings), suppresses identical snapshots, JSON →
`server.broadcast`. (4) Command path: `server.onCommand` → main hop →
dispatcher.execute → reply + immediate uncoalesced broadcast. (5) Drag safety:
OBSOLETE — the drag bracket was deleted with the volume decoupling; a disconnecting
client only drops its rate-limiter bucket. (6) Server stops
in the terminate path next to `backend.stop()`. Verify: full suite via
`scripts/run-tests.sh`; manual `AIRPLAY_BACKEND=mock` + websocat poke.

**T8 — Mac end-to-end integration test** · test · deps: T3, T4, T5 · **sonnet 5, medium**
Files: NEW `CompanionEndToEndTests.swift`. MockBackend + real controllers (temp
stores) + real builder/dispatcher/server wired AppDelegate-style without AppKit; two
loopback WebSocket clients. Asserts: snapshot-on-connect; A's setDeviceSelected
reaches B as state; refusal round-trips; Mac-originated mutation broadcasts; group
CRUD round-trips. Deliberately bypasses T7/AppKit.

**T9 — Docs ride the branch** · docs · deps: T7 · **haiku 4.5, low**
Files: `docs/SPEC.md:30` (reverse "Mac only"; short companion subsection), root
`AGENTS.md:39-54` folder map (+AudiouterProtocol/, +ios/), `AudiouterCore/AGENTS.md`
Map rows (server/builder/dispatcher) + Rules bullet for the two snapshot traps.
Guard 2 verifies every named symbol.

**T21 — Mac-only live gate (checklist doc, then Alec runs it)** · docs · deps: T7, T8 · **haiku 4.5, low**
Files: NEW `dev/notes/companion-mac-live-gate.md`. Checkbox+env on/off behavior;
websocat/loopback poke against the real app (mock backend); snapshot-vs-popover spot
check; **macOS Application Firewall prompt check** (risk R4 — per-launch prompt =
shipping blocker); `strings` binary-identity check (multiple-app-copies trap).
**This gate + Alec's explicit go-ahead = the Phase-1 merge.** Main is merge-only.

### Phase 2 — iPhone app (branch off merged main)

**T10 — iOS Xcode scaffold** · new-code · deps: T1 · **sonnet 5, medium**
Files: NEW `ios/AudiouterRemote/` (working name per D3): xcodeproj with
**File-System-Synchronized (buildable-folder) groups** — pbxproj is touched here and
never again, which is what makes Wave C parallel-safe; app entry + RootView + 4-tab
skeleton; Info.plist `NSLocalNetworkUsageDescription` ("Audiouter uses the local
network to find and control the Audiouter app on your Mac.") +
`NSBonjourServices=["_audiouter._tcp"]`; local package dep on `../../AudiouterProtocol`
ONLY (never AudiouterCore — brew-manifest trap); iOS 18 target, iPhone-only + iPad
compatibility (D6/D7); NEW `ios/AGENTS.md` documenting the xcodebuild command;
`.gitignore` additions. During T10, read `.githooks/pre-commit` to confirm the repo
guards are indifferent to `ios/` (risk R7). Verify: simulator build succeeds; trivial
protocol round-trip test proves the package links.

**T11 — iOS networking layer** · new-code · deps: T10 · **opus 4.8, high**
Files: NEW `ios/…/Networking/{MacBrowser,MacConnection,ConnectionController}.swift`.
MacBrowser: `NWBrowser(.bonjourWithTXTRecord(...))` (plain .bonjour returns nil
metadata), publishes [DiscoveredMac(name, endpoint, protoVersion)], marks
proto>version incompatible; `.failed` → cancel + capped-exponential recreate mirroring
`NativeDiscovery.swift:657-711`; **denial detection**: `.waiting` with `dns(-65570)`
persisting >~3 s → `permissionSuspected` (no status API exists; this heuristic is the
only handle). MacConnection: `NWConnection(to: .service(…))` directly, WebSocket
options, `prohibitedInterfaceTypes=[.cellular]`, hello-on-ready, decode loop, ping
keepalive (~15 s, fail after 2 misses). ConnectionController: owns both +
`NWPathMonitor(requiredInterfaceType: .wifi)`; scenePhase: background = expected drop
(no error UI), foreground = eager reconnect to last Mac with capped backoff;
snapshot-on-welcome makes reconnect seamless. Verify: unit tests for backoff/state
transitions with injected events; simulator discovers a host Mac running mock backend
(simulator shares the Mac's network — no permission prompt in sim). First simulator
run also proves cross-stack WebSocket interop (risk R5).

**T12 — Session model + command sending** · new-code · deps: T11 · **sonnet 5, medium**
Files: NEW `ios/…/Model/{MacSessionProtocol,RemoteSession,CommandSender}.swift`.
`MacSessionProtocol` (snapshot publisher + typed command methods) implemented by both
live and demo sessions — UI depends only on this. RemoteSession (@Observable): latest
Snapshot; requestID correlation → toasts for refusalReason/autoSwap; slider policy:
local echo while dragging, ≤20 Hz coalesced sends, always send release value; the Main
Out slider is the same shape as every other slider (no drag bracket — Main is a
stateless set since the volume decoupling); no phone-side persistence of
routing state. Any shared UI components (colors, toast view) are created HERE or T13 —
Wave C tasks may not create shared files. Verify: scripted fake-transport tests:
cadence, release-value guarantee, correlation, toast surfacing.

**T13 — Demo system** · new-code · deps: T12 · **sonnet 5, medium**
Files: NEW `ios/…/Model/DemoMacSession.swift`. In-memory simulated fleet (Mac +
HomePod + Sonos pair, MockBackend-shaped) applying commands with the visually
significant semantics (selection floor/auto-swap, proportional master, mute stash,
group CRUD, settings). Reachable ONLY from the labeled "Demo system" row (T17a);
"Demo" badge while active; never a fallback (house rule). Runs first in Wave C.

**T14 — Speakers tab** · new-code · deps: T12, T13 · **sonnet 5, medium**
Files: NEW `ios/…/UI/Speakers/{SpeakersView,DeviceRowView,MainOutPicker,StatusBanners}.swift`.
Connection header; Main Out picker (Selected Speakers + groups); master slider + mute;
device rows (icon per D5, availability dimming, select toggle, volume, mute, full
status detail per D9: failure headline / Try again / suggestion, plus local-fallback
banner + takeover strip). Stock SwiftUI + SF Symbols + system colors.

**T15 — Apps tab** · new-code · deps: T12, T13 · **sonnet 5, medium**
Files: NEW `ios/…/UI/Apps/{AppsView,AppRouteRowView,AddAppSheet}.swift`.
Route rows (destination menu: No redirect / This Mac / each speaker; volume; offline
badge from isRunning), swipe-to-remove, add-app sheet from snapshot addableApps.

**T16 — Groups tab + editor** · new-code · deps: T12, T13 · **sonnet 5, medium**
Files: NEW `ios/…/UI/Groups/{GroupsView,GroupEditorView,GroupIconPicker}.swift`.
List (icon, name, member count, active indicator, "Set as output"); create/edit
(rename, member multi-select — empty membership disabled client-side AND refused
server-side, curated SF Symbol grid); delete with confirmation (server falls Main Out
back per `GroupController.swift:577-582`). Member volumes captured at creation, not
phone-edited in v1.

**T17a — Connection half of tab 4** · new-code · deps: T11, T13 · **sonnet 5, medium**
Files: NEW `ios/…/UI/Connect/{MacListView,EmptyStateView,PermissionDeniedView}.swift`.
Mac list + switch, auto-connect to last-used (first launch with exactly one Mac:
auto-connect); "No Mac found" empty state with help (review requirement);
permissionSuspected → explanation + `UIApplication.openSettingsURLString` deep-link;
not-on-Wi-Fi state; incompatible-version row; labeled Demo system row.

**T17b — Settings half of tab 4** · new-code · deps: T12 · **sonnet 5, medium**
Files: NEW `ios/…/UI/Connect/{RemoteSettingsView,AboutView}.swift`.
Connect-volume slider (range from snapshot); buffer picker (options from snapshot)
with explicit **Apply & Reconnect** button + audible-gap warning — never live (D10);
phone's own minimal settings; about.

**T18 — iOS tests + simulator smoke** · test · deps: T14-T17b · **sonnet 5, medium**
Files: `ios/…Tests/` additions only. Consolidate unit tests (session, demo, denial
state machine); scripted simulator-MCP smoke: build → sim → host Mac on mock backend →
discover, connect, toggle speaker, create group, change connect volume, kill Mac app →
empty state → relaunch → reconnect+resync.

### Phase 3 — release prep + gates

**T19 — App Store submission kit** · docs · deps: D6 (content-independent of code) · **sonnet 5, low**
Files: NEW `docs/companion-app-store.md`. Review notes (companion for free Mac host,
no account/backend, with/without-host behavior, demo-mode pointer); demo-video shot
list (discovery → connect → control, iPhone + Mac visible, <60 s); screenshot list
(iPhone-only); App Privacy (no data collected); export compliance (exempt); age
rating; ASC execution delegated to the lance operator later (needs a pushed branch).

**T20 — Full live-test checklist (Mac + iPhone, real Wi-Fi)** · docs · deps: all · **sonnet 5, low**
Files: NEW `dev/notes/companion-live-test-checklist.md`. Fresh install → Local Network
prompt wording → real-Mac discovery (Developer-ID build; strings binary check) →
snapshot vs popover → two-way sync (phone↔popover↔Groups window) → multi-client →
slider feel → refusal toast → backgrounding + resync → checkbox off ⇒
disconnected+goodbye → Wi-Fi drop → permission-deny path (incl. iOS re-grant
may-need-reboot caveat; fresh installs only) → demo mode entry/exit → settings
round-trip (phone connect-volume → Mac pane; phone Apply & Reconnect → gap + resume).
Every mechanism exactly once. Mac-only items live in T21, not here.

**T22 — Flip checkbox default OFF→ON** · new-code · deps: phone release ready · **haiku 4.5, low**
Files: `AppSettings.swift` + test. Rides the phone-app release branch only (D1/D8).

**T23 — Pre-ASC rename** · new-code · deps: name decided (D3); blocks T19's ASC handoff · **sonnet 5, low**
Folder/scheme/display name/bundle id from working name to the chosen one.
pbxproj-touching → not haiku.

## Waves, contention, critical path

Hot files: `AudiouterCore/Package.swift` (T1 only) · `GroupController.swift` (T2 only)
· `AppDelegate.swift` (T7 only — T6 deliberately split off it) · `project.pbxproj`
(T10 only, then synchronized folders) · SPEC/AGENTS (T9 only). No two same-wave tasks
share a file.

- **A1:** T1
- **A2 (∥6):** T2, T3, T4, T5, T6, T10
- **A3 (∥):** T7 (sole AppDelegate owner), T8, T21-doc, T11
- **A4 — PHASE-1 MERGE GATE:** T9 → Alec runs T21 → merge T1-T9+T21 to main **only on
  his explicit go-ahead**. iOS continues on a follow-up branch off merged main.
- **B (∥):** T12, T19
- **C (∥, T13 first):** T13 → T14, T15, T16, T17a, T17b concurrently (shared UI files
  only from T12/T13)
- **D:** T18 → T20 → Alec full live test → release branch adds T22 + T23 → merge on
  go-ahead → ASC handoff (lance).
- **Critical path:** T1 → T10 → T11 → T12 → T16 → T18 → T20. Mac track exits the
  critical path at A4.
- Worktree discipline: parallel agents in ONE worktree clobber each other — per wave,
  separate worktrees off the feature branch (or serialized commits), and build+test
  the combined tree at each wave boundary.

## recommended_execution

**agents** — wave-by-wave watched parallel agents, with two hard human gates (A4:
Alec's Mac-only live test + merge approval; end of D: full live test + merge
approval). Rationale: 4-6 heterogeneous judgment-heavy tasks per wave (T5/T7/T11/T16
especially), mid-course corrections likely, and Alec's standing preference for
visibility over workflow ceremony; no wave is a uniform 8+-task mechanical fan-out.

## Test + guard impact

New Mac tests: CompanionMessageTests (new package), CompanionSnapshotBuilderTests,
CompanionCommandDispatcherTests, CompanionServerTests, CompanionEndToEndTests, plus
additions to GroupControllerTests / ExcludedAppsTests / AppSettingsTests. All
swift-testing, `IsolatedSuite` where defaults/temp-dirs are touched, **loopback binds
only**. No audio-playback tests in the routine suite. Guard 4 does NOT see
`AudiouterProtocol/Tests` or iOS tests — run `swift test` in AudiouterProtocol/ and
xcodebuild-test in ios/ explicitly at each wave boundary (documented in both new
AGENTS.md files).

## Open risks (execution must confirm)

1. **R1 — concurrent master drags share one state slot** — **MOOT.** The volume
   decoupling deleted `dragRatios` and the whole drag-bracket machinery from
   `GroupController`: Main Out is now its own stored gain and
   `setMainOutMasterVolume` is stateless, so there is no shared drag state for a
   phone and the Mac to fight over, and nothing for a vanished client to strand.
2. **R2 — onChange chaining order** (popover assigns, mixer window chain-wraps): T7
   chains after popover configuration; if fragile, fall back to broadcasting from the
   popover's repaint path.
3. **R3 — ExcludedAppsController mutation call sites**: T2 greps all before finishing.
4. **R4 — new always-on listener vs macOS Application Firewall**: DACP binds only
   during streaming; companion binds at launch (when enabled). Developer-ID-signed
   should auto-allow — confirm in T21; a per-launch prompt = shipping blocker.
5. **R5 — cross-stack WebSocket interop** (Mac NWListener ↔ iOS NWConnection): low
   risk, proven in first T11 simulator run.
6. **R6 — iOS 18 Local Network desync bugs**: denial-then-grant may need reboot; never
   treat one packet as proof of grant; QA fresh installs only (T20).
7. **R7 — Xcode project + SwiftPM coexistence**: confirm repo guards indifferent to
   `ios/` by reading `.githooks/pre-commit` during T10.
8. **Research-vs-code delta (flagged, deliberate):** full-snapshot broadcasts replace
   the research doc's snapshot+delta design; envelope keeps deltas possible later.

## Post-review additions (2026-07-26)

Four adversarial reviews (Opus 4.8, one per lens: concurrency/lifecycle,
protocol/state, hostile-LAN, iOS networking) ran against the Phase-1 + T11/T12 code.
Verdicts: three of four said "not safe to gate/ship as-is". Findings were fixed in a
five-batch wave (FIX-A server, FIX-B1 dispatcher, FIX-B2 wiring+snapshot, FIX-C
settings honesty, FIX-D iOS). Highlights, for the record:

- **P0/P1 — unbounded persisted state.** A LAN peer could append groups/app-routes
  without limit; each write rewrites the whole file synchronously on the main thread,
  and the damage survives relaunch. Fixed with caps + validation at the dispatcher.
- **P1 — socket exhaustion.** Cap-refused connections were held in a second, uncapped
  pool; a connect-flood could exhaust process-wide file descriptors, taking down
  AirPlay/PTP/DACP with it. Fixed with a bounded pool + rate limiting.
- **P1 — pre-upgrade connections consumed client slots** (proven experimentally by the
  iOS reviewer): the phone's own address-resolve probe burned a slot for the full
  handshake deadline, so reconnect storms self-DoS'd the 16-client cap.
- **P1 — no post-handshake liveness either direction.** A vanished phone held its slot
  (and latched an orphaned Main Out drag) forever; a wedged Mac left the phone showing
  a healthy UI whose every command silently did nothing.
- **P1 — phone-set audio buffer never broadcast its new value** (found independently
  by two reviewers): "applied" with the old value still displayed, self-healing only
  when speakers happened to be streaming.
- **P1 — the Settings checkbox could lie**: with the dev env override set it showed
  OFF while the server ran, and unticking did nothing. Would have shipped to everyone
  if T22's default-flip were implemented via LSEnvironment.
- **P1 — no terminal-failure classification on the phone**: a version-mismatched or
  disabled Mac was redialed every 30s forever, flapping the UI.

Reviewers also explicitly cleared: no deadlocks on any quit path, the coalescer is
race-free, exactly-one-disconnect-signal holds, every app mutation path reaches a
broadcast trigger, the snapshot mapping traps are correct in every branch, and no code
injection reachable via attacker-supplied strings.

**T24 — per-phone approval (new, from D2 REVISED).** Depends on the fix wave landing.
Scope: stable per-phone identity persisted on the phone and sent in `hello`; an
approvals store on the Mac (`{schemaVersion, payload}` idiom, alongside the other
stores); an approval gate at the pending-pool promotion point in `CompanionServer`; a
Mac prompt naming the phone; an "awaiting approval on your Mac" state on the phone
(long-lived, non-error); a revoke/manage list in Settings › General; and tests both
sides incl. approval-persists-across-relaunch and denial-is-remembered. Ships with the
phone app, not before. Model: opus 4.8 / high (spans both sides + a new trust
boundary); the iOS half may be sonnet 5 / medium once the Mac contract is fixed.
