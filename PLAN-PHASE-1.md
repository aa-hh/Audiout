# PLAN — Phase 1: the real AppKit app

Phase 0 proved the pipeline (capture → FIFO → OwnTone → AirPlay). Phase 1 turns
that into a usable product: a real `OwnToneBackend` driving OwnTone's JSON API, a
coordinator owning the capture→FIFO lifecycle, and a pure-AppKit app (menu-bar
extra first, full window second) built per SPEC §9, with saved groups/presets.
Everything is mock-first: the app runs against `MockBackend` by default and the
`AIRPLAY_BACKEND` env toggle selects the real path.

Grounded in: SPEC.md §3 (v1 vs v2 — per-app routing + EQ are **v2, out of scope
here**), §4 (security + "no OwnTone references in final product"), §9 (the UI
contract); PLAN-0e-0f.md (invariants); dev/notes/0e-taps-brief.md,
dev/notes/0f-pipe-brief.md (API briefs); the existing code
(`AudioutedCore/`, `dev/audiocap/`, `dev/owntone/`).

---

## A. End-state overview

A signed-or-ad-hoc `.app` menu-bar utility (LSUIElement, `NSStatusItem.button`
with an SF Symbol whose `variableValue` tracks master volume) opens a true
`NSMenu` of groups + ungrouped devices with per-row sliders/mute/solo, in-place
group expansion, and an in-menu group editor; a second `NSSplitViewController`
window gives the full sidebar+mixer with a unified toolbar and a presets
`NSPopUpButton`. The UI talks only to the `OutputBackend` protocol
(`AudioutedCore/Sources/AudioutedCore/OutputBackend.swift:31`),
so it is identical against `MockBackend` and the new real `OwnToneBackend`. The
real backend drives OwnTone's JSON API (:3689) for outputs list/select/volume +
queue/play/stop, subscribes to the :3688 websocket for push updates (re-GETting
on each notification), detects `outputs[].selected` zombie de-selection, and — via
a capture coordinator — owns the `audiocap`→FIFO lifecycle with config-follows-tap
rate reconciliation. Groups/presets persist to a JSON file in Application Support.
Mute/solo/group are app-side concepts layered over the backend's flat output set.

---

## B. OPEN QUESTIONS — needs confirmation

These are genuine forks I did **not** resolve by assumption. Each has a
recommendation the executor can default to if Alec doesn't weigh in.

**Q1 — App target: SwiftPM executable vs Xcode project.**
A menu-bar AppKit app needs an `Info.plist` (`LSUIElement=1`, bundle id,
`NSAudioCaptureUsageDescription` once capture is in-process), an app bundle
layout, and eventually an icon + signing. A bare SwiftPM executable produces a
loose binary with no `.app` wrapper (the 0e brief §5 shows the `-sectcreate`
plist hack, but that gives a plist, not a bundle — `LSUIElement`/status-item
behavior and `NSApplication.setActivationPolicy(.accessory)` still need a real
bundle).
- (a, **recommended**) **New SwiftPM executable target** `AudioutedApp`
  in `AudioutedCore/Package.swift`, run headlessly as an `.accessory`
  app via `NSApplication.shared.setActivationPolicy(.accessory)` in code (no
  `LSUIElement` plist needed for a menu-bar app that never wants a Dock icon),
  plus a small `make-app-bundle.sh` that wraps the built binary into a `.app`
  with an `Info.plist` for the TCC/signing story later. Keeps one build system,
  one `swift build`, links `AudioutedCore` directly, no `.xcodeproj` to
  maintain. Downside: bundle/signing is a hand-rolled script.
- (b) **Xcode project** (`.xcodeproj` / `.xcworkspace`) referencing the SPM
  package. Native `Info.plist`/asset-catalog/signing/`LSUIElement` UI, but adds
  a second build system, isn't scriptable from an agent shell as cleanly, and
  Xcode-project edits are hard to review line-by-line.
- Recommendation: (a) now; migrate to (b) only if signing/notarization friction
  demands it in Phase 2. `setActivationPolicy(.accessory)` gives the
  no-Dock-icon menu-bar behavior without a plist, so (a) is not blocked.

**Q2 — Capture integration: subprocess vs in-process library.**
The `audiocap` code (`dev/audiocap/`) targets `.macOS("14.4")`; the core targets
`.macOS(.v13)` (`AudioutedCore/Package.swift:6`, `dev/audiocap/Package.swift:9`).
The coordinator must own capture start/stop + rate reporting.
- (a, **recommended**) **Spawn `audiocap` as a subprocess** from the app
  (`Process`, `--pipe <fifo>`, parse the printed `pipe_sample_rate = N` line from
  stderr — main.swift:328 already emits exactly that). Keeps the 14.4-only tap
  code and its separate `NSAudioCaptureUsageDescription` TCC identity isolated
  from the app; the app bundle can stay `.macOS(.v13)`-ish and needn't itself
  hold the audio-capture entitlement in Phase 1; teardown = terminate the child
  (SIGINT → clean FIFO EOF, already handled main.swift:210-214). Downside: two
  binaries, IPC by stderr-scraping + exit codes, and a second TCC grant surface.
- (b) **Extract `TapEngine`/`PipeWriter`/`RingBuffer` into a library target**
  (`CaptureKit`, `.macOS("14.4")`) linked by the app. Cleaner data flow (levels,
  errors as Swift types, no scraping) and one process, BUT it **forces the whole
  app target to `.macOS(14.4)`** (the app links a 14.4 target), collapses the
  deliberate v13/v14.4 split the 0e brief and PLAN-0e-0f.md:41 call out, and
  moves the capture TCC identity into the app bundle.
- Recommendation: (a) for Phase 1 — it preserves the deployment-target split, the
  audiocap CLI stays independently testable via the verify scripts, and the app
  stays decoupled from the capture binary's rebuild-resets-TCC churn. Note: the
  *shipping* product (Phase 2, native sender) will likely go in-process (b); (a)
  is the right Phase-1 choice, not a permanent one. The app already only targets
  macOS 14.4+ machines in practice (taps require it), so the "app must be 13"
  concern is about the *library graph*, not the runtime floor — call this out to
  Alec.

**Q3 — Groups/presets persistence mechanism.**
Need to persist named groups (name + member device-ids + per-member volume
snapshot) and remember the active group.
- (a, **recommended**) **A versioned JSON file** at
  `~/Library/Application Support/Audiouted/groups.json`, loaded/saved via
  `Codable`. Human-readable, diffable, easy to seed in tests, survives app
  rebuilds, trivially migratable. Store the schema `version` for forward-compat.
- (b) `UserDefaults` (suite keyed). Zero file plumbing, but opaque, awkward for
  nested arrays, and tied to the bundle-id domain (which changes if we rename off
  "OwnTone"/bundle churn).
- (c) A plist file. Between the two; no real advantage over JSON here.
- Recommendation: (a). Keep the store in `AudioutedCore` (a `GroupStore`
  type) so it is UI-agnostic and unit-testable without AppKit.

**Q4 — Mute/solo semantics against OwnTone (no native mute/solo in the API).**
The `output` object (json-api.md:334-346) has `selected` + `volume` only — no
mute or solo. The `Device` model has `isMuted`/`isSoloed`
(`Device.swift:54-55`) and the mock honors them, but OwnTone can't.
- (a, **recommended**) **App-side mute/solo, realized via volume + selection.**
  Mute = remember prior volume, `PUT volume:0` (or deselect); unmute = restore.
  Solo = deselect/zero every non-soloed selected output for the duration. The
  backend keeps the app-level `isMuted`/`isSoloed` flags in its `Device`
  snapshots (so the UI stays a pure function of backend state) and maps them to
  OwnTone volume/selection under the hood. Matches the mock's observable
  behavior exactly.
- (b) Mute = deselect the output entirely (`outputs/set` without it). Simpler but
  loses the output's negotiated session; re-selecting re-handshakes (slow, and
  0f-pipe-brief.md notes zombie-session hazards on re-activation) — worse UX.
- Recommendation: (a), volume-based mute (restore prior volume), selection left
  intact, to avoid re-handshake churn. Confirm the "0 volume vs deselect"
  choice with Alec.

**Q5 — Menu-mutation-while-open: how much to gate on the research spike.**
SPEC §9 wants live insert/remove of `NSMenuItem`s for in-place group expansion,
"verify NSMenu tolerates mutation while open … fallback is `menuNeedsUpdate`"
(SPEC.md:324). This is the single riskiest UI unknown.
- (a, **recommended**) Do the research brief FIRST (T-R1), and have it pick
  between (i) live `insertItem/removeItem` on the open menu vs (ii) an
  `NSMenuDelegate.menuNeedsUpdate` full rebuild vs (iii) collapse-to-submenu.
  The menu-build task (T-U2) consumes the brief's verdict — it does NOT design
  the expansion mechanism speculatively.
- (b) Build live-mutation first, fall back if it breaks. Riskier — could waste
  the T-U2 effort.
- Recommendation: (a). Same brief-then-transcribe discipline Phase 0 used.

**Q6 — Master-volume model source of truth (SPEC §9 "master echoes average").**
The group master both *drives* members proportionally (ratio snapshot at drag
start) and *echoes* the members' average. Where does that arithmetic live?
- (a, **recommended**) In a UI-agnostic `GroupController`/mixer-model type in
  `AudioutedCore`, unit-tested (proportional scaling, clamp-at-100,
  average echo) with **no** AppKit, so both the menu slider and the window
  toolbar slider share one implementation and one test suite.
- (b) In each AppKit view controller. Duplicated logic, two places to get the
  clamp/ratio edge cases wrong, untestable without a UI host.
- Recommendation: (a).

**Q7 — OwnTone lifecycle ownership (does the app launch/manage OwnTone?).**
0f requires OwnTone running as root (PTP) + firewall-allowlisted + the pipe track
registered. In Phase 1 dev, is OwnTone (i) started by hand (current
`dev/owntone/start-owntone.sh`, admin dialog) and merely *connected to* by the
app, or (ii) spawned/supervised by the app?
- (a, **recommended**) Phase 1 app **connects to an already-running OwnTone**
  (started by the existing script); the backend health-checks `GET /api/config`
  on start and surfaces a clear "engine not reachable" state if it's down. Root +
  firewall are human/dev concerns (they were in Phase 0), and the native sender
  (Phase 2) replaces OwnTone-launching entirely — building supervision now is
  throwaway work for a component that "never ships" (SPEC.md:110).
- (b) App supervises OwnTone (spawn, root helper, firewall). Large, throwaway
  (SPEC §4: OwnTone never ships), and pulls the privileged/`SMAppService` work
  forward out of Phase 2.
- Recommendation: (a) — connect-only; treat OwnTone as an external dev fixture,
  exactly as Phase 0 did.

**Q8 — Level meters (`NSLevelIndicator`) data source for the real backend.**
`BackendEvent.level(id:rms:)` (OutputBackend.swift:20) feeds the meters; the mock
fabricates RMS. OwnTone's API exposes no per-output live RMS.
- (a, **recommended**) In Phase 1, the real backend derives a cheap level proxy
  from the capture side: `audiocap` already computes `peakSample`
  (main.swift:139) — have the capture coordinator emit a periodic RMS/peak for
  the whole stream and fan it to all selected/unmuted outputs (same value each).
  Honest-ish (it's the actual program level), cheap, and matches the "display
  only" contract (SPEC §9 level meter row).
- (b) Omit meters for the real backend in Phase 1 (static/hidden), add per-stream
  metering with the native sender in Phase 2.
- Recommendation: (a) — a single shared program-level meter; per-device metering
  waits for the native sender. Confirm Alec is fine with all selected devices
  showing the same meter in Phase 1.

---

## C. Task list

Legend: `model` = haiku 4.5 | sonnet 5 | opus 4.8 · `effort` = low/med/high/xhigh ·
`kind` per the required set. "USER-GATED" = needs Alec present (TCC dialog,
listening, sudo/firewall). Line anchors are to files as they exist today.

### Research briefs (feed the code tasks — brief-then-transcribe)

**T-R1 — NSMenu-while-open + NSMenuItem.view interaction brief**
- files: NEW `dev/notes/1-appkit-menu-brief.md`
- what: Pin, with doc citations, (1) whether an open `NSMenu` tolerates
  `insertItem(_:at:)`/`removeItem(_:)` live, or requires `NSMenuDelegate`
  `menuNeedsUpdate:`/`numberOfItems` rebuild; (2) `NSStatusItem` via `.button`
  only (SPEC §9 — never the deprecated `.view`/`.title`/`.image`), SF Symbol
  `variableValue` on the button image; (3) embedding an **editable**
  `NSTextField` in an `NSMenuItem.view` and its first-responder/keyboard behavior
  in a menu (the in-menu group-name editor); (4) custom-view rows owning slider
  drag + button clicks inside a menu. Recommend the primary + fallback mechanism.
- kind: docs · depends_on: none
- recommended_model: opus 4.8 — correctness-sensitive API-behavior research whose
  wrong call invalidates the whole menu build (T-U2/T-U3).
- recommended_effort: medium — focused reading of AppKit docs + known-good
  patterns; no code.
- verify: brief exists, cites `developer.apple.com/documentation/appkit/...`
  URLs, gives a primary + fallback for menu mutation and a verdict on the
  editable-field-in-menu question.

**T-R2 — OwnTone JSON+websocket integration brief**
- files: NEW `dev/notes/1-owntone-api-brief.md`
- what: Transcribe the exact request/response contract the real backend needs,
  grounded in `dev/owntone/install/usr/share/doc/owntone/docs/json-api.md`:
  `GET /api/outputs` (output object fields — id is a **string**, json-api.md:336;
  `selected`, `volume`, `type`, `format`; NO mute/solo → app-side per Q4),
  `PUT /api/outputs/{id}` `{"volume":0-100}` (0f-pipe-brief.md:128), `PUT
  /api/outputs/set` `{"outputs":[ids]}` (json-api.md:424), `GET/PUT /api/player`
  + `player/play|stop` (json-api.md:37, 92-123), queue clear/add
  (0f-pipe-brief.md:71-75), `GET /api/config` for `websocket_port`
  (json-api.md:2263), and the **:3688 websocket** protocol: connect, send
  `{"notify":[...]}` with `Sec-WebSocket-Protocol: notify`, receive
  event-**names** only (`outputs`/`player`/`volume`/`queue`, json-api.md:2470-2480)
  → the client MUST re-GET state on each notification (the message carries no
  payload). Document the invariants from 0f-pipe-brief.md: config-follows-tap
  rate, explicit queue→add→play (autostart no-ops), player suspends to `pause`
  (not stop) on EOF, and `outputs[].selected` zombie de-selection detection.
- kind: docs · depends_on: none
- recommended_model: sonnet 5 — documented API surface already largely captured
  in 0f-pipe-brief.md; consolidation + websocket-handshake precision, not novel.
- recommended_effort: medium.
- verify: brief lists every endpoint the backend calls with method+path+body+
  response code, and a websocket-message worked example.

### AudioutedCore (UI-agnostic, testable)

**T-C1 — Real `OwnToneBackend`: JSON API control + state**
- files: `AudioutedCore/Sources/AudioutedCore/OwnToneBackend.swift`
  (replace the stub body, keep the type name for now — see T-C4 rename),
  NEW `.../OwnToneClient.swift` (URLSession JSON client), NEW
  `.../OwnToneWebSocketMonitor.swift` (URLSessionWebSocketTask on :3688)
- what: Implement `OutputBackend` over OwnTone's API per T-R2: `start()` →
  `GET /api/config` health-check + `GET /api/outputs` → emit `deviceAdded` for
  each (map output→`Device`: id string, name, `type=="AirPlay"`→kind heuristics,
  `selected`→`isSelected`, `volume`); subscribe to :3688 websocket and on any
  `outputs`/`volume`/`player` notification re-GET and diff → emit
  `deviceUpdated`/`deviceRemoved`. `setVolume`→`PUT /api/outputs/{id}`;
  `setOutputSet`→`PUT /api/outputs/set`; `setMuted`/`setSoloed` app-side per Q4.
  Detect `selected` flipping false unexpectedly (zombie) and surface it. NO
  capture/FIFO here (that's T-C2). Poll fallback if the websocket drops.
- kind: backend · depends_on: T-R2
- recommended_model: opus 4.8 — networked state-machine with async event
  fan-out, websocket lifecycle, and the zombie-detection invariant; high blast
  radius (the whole real path).
- recommended_effort: high.
- verify: unit tests against a stubbed `URLProtocol` (canned `/api/outputs`
  JSON) assert the emitted `BackendEvent`s; manual run under `AIRPLAY_BACKEND=owntone`
  against the running OwnTone lists the fake shairport receiver (batched into
  T-V1). `swift test` green.

**T-C2 — Capture coordinator: audiocap→FIFO lifecycle + rate reconciliation**
- files: NEW `AudioutedCore/Sources/AudioutedCore/CaptureCoordinator.swift`
- what: Own the capture→playback lifecycle above the backend (Q2(a)
  subprocess model): spawn `audiocap --pipe <fifo>` (`Process`), parse the printed
  `pipe_sample_rate = N` from stderr (main.swift:328), enforce config-follows-tap
  (if OwnTone's `pipe_sample_rate` != N, surface a reconcile action — the app
  can't restart OwnTone silently per Q7; report it), then drive OwnTone playback
  explicitly (`queue/clear`→`queue/items/add?uris=library:track:{id}`→`player/play`,
  0f-pipe-brief.md:71-75). On stop: SIGINT the child (clean FIFO EOF) + `player/stop`
  (0f-pipe-brief.md:19). Exclude the shairport/receiver pid on the fake-receiver
  path (feedback-loop guard, PLAN-0e-0f.md:340) via `--exclude`. Emit a
  program-level meter for Q8(a). Handle child crash/EOF (suspend-to-pause) and
  zombie de-selection (from T-C1) with recovery.
- kind: backend · depends_on: T-C1, T-R2
- recommended_model: opus 4.8 — subprocess lifecycle + real-time-ish
  reconciliation + the hard-won 0f invariants; correctness-sensitive.
- recommended_effort: high.
- verify: unit test the stderr rate-parse + the explicit-playback command
  sequence (against a stubbed client); end-to-end audio verify is T-V1 (scripted).

**T-C3 — GroupStore + GroupController (persistence + proportional master math)**
- files: NEW `.../GroupStore.swift` (Codable JSON at Application Support, Q3(a)),
  NEW `.../GroupController.swift` (mixer model, Q6(a))
- what: `Group{ id, name, memberIDs:[String], memberVolumes:[String:Int] }`,
  versioned JSON load/save; "save current setup as group" captures the live
  selected set + volumes. `GroupController` implements SPEC §9 group semantics:
  one active group at a time (activating = `setOutputSet(members)`), proportional
  master (ratio snapshot at drag start, clamp at 100 via `Int.clampedToVolume`,
  Device.swift:88), and master-echoes-average. Pure model, no AppKit.
- kind: new-code · depends_on: none (uses existing `OutputBackend`/`Device` only)
- recommended_model: sonnet 5 — well-bounded model + file IO with clear rules;
  the proportional-scaling edge cases warrant care but aren't architectural.
- recommended_effort: medium.
- verify: NEW unit tests: round-trip persistence, proportional scale preserves
  ratios + clamps at 100, average-echo, activate→`setOutputSet` called with
  members. `swift test` green.

**T-C4 — Neutral backend naming seam (no new OwnTone-named PUBLIC API)**
- files: `AudioutedCore/Sources/AudioutedCore/OwnToneBackend.swift`
  (+ any new files from T-C1), `dev/README.md`
- what: SPEC §4 forbids new OwnTone-named public API. Introduce a neutral public
  protocol-facing name for the real backend (e.g. `NativeBackend` /
  `EngineBackend`) as the public symbol, keeping `OwnTone*` only on the
  private/internal JSON-client internals if at all. Keep `BackendKind.ownTone`
  the env value for now (PLAN-0e-0f.md Q5 kept it) OR add a neutral alias —
  flag as a sub-decision. Update `makeBackend` (OwnToneBackend.swift:76) and
  `dev/README.md` wording. This is a **naming/refactor** pass done AFTER T-C1
  lands so it renames real code, not a stub.
- kind: new-code (refactor) · depends_on: T-C1
- recommended_model: sonnet 5 — mechanical rename with public-API-surface care;
  must keep tests + the env toggle green.
- recommended_effort: low.
- verify: `swift test` green; `grep` shows no NEW public symbol containing
  "OwnTone" beyond the internal client; `AIRPLAY_BACKEND=owntone` still resolves.

### AppKit app (pure AppKit, SPEC §9)

**T-U1 — App target skeleton + backend wiring + status item**
- files: NEW `AudioutedApp/` executable target (Q1(a)) added to
  `AudioutedCore/Package.swift:14` (targets/products), NEW
  `.../AppDelegate.swift`, `.../main.swift`, NEW `make-app-bundle.sh`
- what: `NSApplication` + `AppDelegate`, `setActivationPolicy(.accessory)`
  (menu-bar-only, no Dock icon — Q1), create the status item via
  `NSStatusBar.system.statusItem(withLength:.variableLength)` and customize ONLY
  its `.button` (SPEC §9: never `.view`/`.title`/`.image`); button image =
  `NSImage(systemSymbolName:"speaker.wave.3.fill",variableValue:...)` tracking
  master volume. Instantiate the backend via `makeBackend()` (resolver already in
  place, OwnToneBackend.swift:76) and drive one `makeEventStream()` consumer that
  holds the app's device model. Empty menu placeholder (T-U2 fills it).
- kind: new-code · depends_on: T-R1 (status-item usage), T-C4 (final backend name;
  can start against `makeBackend()` before rename and absorb it)
- recommended_model: opus 4.8 — new app bootstrap + Package graph change +
  event-stream→UI plumbing that every later UI task builds on (high blast radius).
- recommended_effort: high.
- verify: `swift build` produces the executable; running it (mock default) shows
  the status item with a volume-reactive symbol; `swift test` still green.
- HOT FILE: `AudioutedCore/Package.swift` (shared with T-C* only via
  target additions — see waves).

**T-U2 — Menu: device + group rows, sliders/mute/solo, in-place expansion**
- files: NEW `AudioutedApp/Menu/` (`MenuController.swift`,
  `DeviceRowView.swift`, `GroupRowView.swift`), consumes T-R1's verdict
- what: Build the `NSMenu` per SPEC §9 "Groups in the menu": groups section (one
  row/group: chevron `NSButton` SF Symbol `chevron.right`/`.down`, name, numeric
  readout, group-master `NSSlider`), in-place chevron expansion inserting indented
  member rows using T-R1's chosen mechanism (live insert/remove OR
  `menuNeedsUpdate` rebuild), ungrouped-devices section below, actions section
  (separators + plain items). Device row = shared component (SPEC §9 "Device
  row"): `NSStackView` container, SF-Symbol icon w/ `variableValue`, horizontal
  continuous `NSSlider`, mute/solo `NSButton` `.accessoryBar`
  `.pushOnPushOff`, `NSLevelIndicator` `.discreteCapacity` display-only. Wire
  actions to `GroupController` (T-C3) + backend. Master-echoes-average +
  proportional drag via `GroupController`.
- kind: new-code · depends_on: T-R1, T-U1, T-C3
- recommended_model: opus 4.8 — the highest-risk UI: menu-mutation-while-open,
  custom `NSMenuItem.view` rows owning drag/click, the group interaction model.
- recommended_effort: xhigh.
- verify: manual (T-V2 batch): open menu, expand/collapse a group, drag master
  (members scale proportionally, clamp at 100), toggle mute/solo, activate a group
  (output set switches). Against mock (default), no speakers needed.

**T-U3 — In-menu group editor (name field + checkboxes, create/edit/delete)**
- files: NEW `AudioutedApp/Menu/GroupEditorView.swift`, edits
  `AudioutedApp/Menu/MenuController.swift` (swap-in-place editor mode)
- what: SPEC §9 "Group setup in the menu": "New group…" + per-row hover pencil
  enter an in-place editor swapping the menu content — back arrow + title,
  group-name `NSTextField` (placeholder example name, editable-in-menu per T-R1),
  "Speakers" list with `NSButton(checkboxWithTitle:)` per discovered device,
  Cancel/Save (+ "Delete group…" when editing). "Save current setup as group…"
  captures live set+volumes (via `GroupStore`, T-C3).
- kind: new-code · depends_on: T-R1 (editable field in menu), T-U2 (MenuController
  — HOT FILE shared with T-U2), T-C3 (GroupStore)
- recommended_model: opus 4.8 — editable `NSTextField` first-responder behavior
  inside a menu is the second-riskiest UI unknown; shares `MenuController.swift`.
- recommended_effort: high.
- verify: manual (T-V2 batch): create a group from checkboxes, name it, save;
  edit membership; delete; "save current setup" round-trips through GroupStore.

**T-U4 — Full window: NSSplitViewController sidebar + NSStackView mixer + toolbar + presets**
- files: NEW `AudioutedApp/Window/` (`MixerWindowController.swift`,
  `SidebarViewController.swift`, `MixerViewController.swift`,
  `ToolbarController.swift`)
- what: SPEC §9 "Full window": `NSWindow` `toolbarStyle=.unified` +
  `.fullSizeContentView`, `NSToolbar` hosting master `NSSlider` + presets
  `NSPopUpButton` (`pullsDown=false`); `NSSplitViewController` with
  `.sidebar(withViewController:)`; sidebar `NSOutlineView` source-list style
  (groups→member devices); mixer pane = `NSStackView` of the SAME device-row
  component as T-U2 (share it — extract to a reusable view). "Open mixer…" from
  the menu opens this window. Presets picker selects a group (activates it);
  save/rename are separate toolbar/menu actions (not mixed into the picker,
  SPEC §9). Balance/EQ are v2 — NOT built here.
- kind: new-code · depends_on: T-U1, T-C3, and the shared device-row from T-U2
- recommended_model: opus 4.8 — split-view + outline-view + unified-toolbar +
  reusing the row component; sizeable, several documented controls wired together.
- recommended_effort: high.
- verify: manual (T-V2 batch): open window from menu, sidebar lists groups+devices,
  mixer rows control volume/mute/solo, master slider + presets picker work; dark/
  light "just work" (no forced `NSAppearance`, SPEC §9).

### Verification (USER-GATED, batched, scripted PASS/FAIL — Phase-0 pattern)

**T-V1 — Real-path audio verification script (fake shairport receiver)**
- files: NEW `dev/verify-1-realpath.sh` (mirrors dev/verify-0f3-soak.sh pattern)
- what: One scripted, human-run check of the real backend + capture coordinator
  end-to-end against the fake shairport receiver (no speakers, per constraints):
  start OwnTone + `dev/fake-speakers.sh`, launch the app under
  `AIRPLAY_BACKEND=owntone`, activate a 1-device group, confirm receiver-side PCM
  is non-silent (receiver-side capture, the 0f pattern), volume PUT changes the
  wire level, `player/stop` on deactivate, and the shairport pid is excluded from
  capture (feedback-loop guard). Prints a PASS/FAIL verdict.
- kind: test · depends_on: T-C1, T-C2, T-U1 (app can drive the backend)
- recommended_model: sonnet 5 — scripted verification following the established
  verify-0f* pattern; the audio judgment is receiver-side + programmatic.
- recommended_effort: medium.
- verify: script emits PASS on non-silent receiver PCM + correct volume/stop
  behavior. USER-GATED (TCC dialog + OwnTone root/firewall + local listen).

**T-V2 — UI acceptance pass (mock backend, GUI session)**
- files: NEW `dev/notes/1-ui-acceptance.md` (checklist + results)
- what: A single batched human pass through the menu (T-U2/T-U3) and window
  (T-U4) against the DEFAULT mock backend (no speakers/TCC): the SPEC §9
  interaction checklist — expand/collapse, proportional master + clamp, master-
  echoes-average, mute/solo, group create/edit/delete/save-current, one-active-
  group switching, window sidebar+mixer+presets, dark/light. Records pass/fail per
  item so UI fixes are batched.
- kind: test · depends_on: T-U2, T-U3, T-U4
- recommended_model: sonnet 5 — structured manual acceptance authoring +
  triage; not code-heavy.
- recommended_effort: medium.
- verify: checklist file with every SPEC §9 menu/window behavior marked PASS/FAIL.
  USER-GATED (GUI session; agent shells can't drive the menu).

### Docs

**T-D1 — SPEC + README + memory updates for Phase 1 close-out**
- files: `SPEC.md` (§5 Phase-1 status, §9 note the menu-mutation verdict + the
  neutral backend name), `dev/README.md` (real backend now works; how to run the
  app), `AudioutedCore/MEMORY.md`-index pointer if warranted
- what: Fold Phase 1 results in: the resolved open questions, the app-target
  decision (Q1), capture-integration decision (Q2), persistence (Q3), the naming
  seam (T-C4), and pointers to the new briefs/scripts. HOT FILE `SPEC.md` — sole
  writer.
- kind: docs · depends_on: T-C1, T-C2, T-C3, T-U2, T-U3, T-U4, T-V1, T-V2, T-C4
- recommended_model: sonnet 5 — prose consolidation of verified results.
- recommended_effort: low.
- verify: SPEC §5/§9 reflect Phase-1 reality; no stale "stub"/OwnTone-naming
  claims contradicting T-C4.

---

## D. Parallelization — waves, hot files, critical path

**Hot files / shared resources (one writer at a time):**
- `AudioutedCore/Package.swift` — touched by T-U1 (add app target) and
  potentially T-C2/T-C3 (new files need target membership under the existing
  `AudioutedCore` target — actually only new *targets* touch it; new
  *files* in the existing target do NOT edit Package.swift). Net: **only T-U1
  edits Package.swift** for the app target. Serialize any other Package.swift
  edit behind T-U1.
- `AudioutedApp/Menu/MenuController.swift` — T-U2 creates it, T-U3 edits
  it. **Serialize T-U3 after T-U2.**
- `OwnToneBackend.swift` (+ new client/coordinator files) — the backend hot set,
  written by T-C1 (implement), referenced by T-C2 (coordinator), renamed by T-C4.
  **Serialize T-C4 last, after BOTH T-C1 and T-C2**, so the rename sweeps all
  references in one pass.
- The shared **device-row view** — created in T-U2, reused by T-U4. T-U4 must
  start after T-U2 defines it (or T-U2 extracts it first). **Serialize T-U4's
  row reuse after T-U2.**
- `SPEC.md` — only T-D1 writes it.
- OwnTone process + fake receiver — T-V1 only (single live user).

**Wave 1 (all parallel — research + independent core):**
- T-R1 (opus/med) · T-R2 (sonnet/med) · T-C3 (sonnet/med, GroupStore/Controller,
  depends on nothing but existing types).
- Critical-path seeds: T-R1 (→ all UI) and T-R2 (→ real backend).

**Wave 2 (parallel; each depends on a Wave-1 brief):**
- T-C1 (opus/high, needs T-R2) · T-U1 (opus/high, needs T-R1; can start against
  `makeBackend()` before T-C4 rename). These edit disjoint files
  (OwnToneBackend/client/websocket vs the new app target + Package.swift) → run
  concurrently.

**Wave 3:**
- T-C2 (opus/high, needs T-C1+T-R2) · T-U2 (opus/xhigh, needs T-R1+T-U1+T-C3).
  T-C2 creates `CaptureCoordinator.swift` (new file) and only *references*
  T-C1's backend symbols; T-U2 is on the app tree. Disjoint files → parallel.
- Then T-C4 (sonnet/low, the neutral rename) runs **last in the backend chain,
  after BOTH T-C1 and T-C2**, so its rename sweeps every reference (backend +
  coordinator + `makeBackend`) in one pass with no mid-flight symbol churn.
  Chain: T-C1 → T-C2 → T-C4; the backend/client files are the hot set (one owner
  at a time). T-U2 runs concurrently with this whole chain (different tree).

**Wave 4:**
- T-U3 (opus/high, **serialize after T-U2** — shares MenuController.swift) ·
  T-U4 (opus/high, needs T-U1+T-C3 + T-U2's shared row; if the row is extracted
  early it can overlap T-U3, else serialize its row-reuse after T-U2). T-U3 and
  T-U4 touch disjoint files (Menu/ vs Window/) → parallel with each other once
  both their deps (T-U2 for the row, T-U2 for MenuController) are satisfied.

**Wave 5 (verification — USER-GATED, batched):**
- T-V1 (sonnet/med, needs T-C1+T-C2+T-U1) can actually run once Wave-3 backend +
  T-U1 exist — pull it as early as the real path works, but it's a human gate so
  batch it. T-V2 (sonnet/med, needs T-U2+T-U3+T-U4). Run both in ONE Alec GUI/
  Terminal session to minimize TCC re-grants and context switches.

**Wave 6:**
- T-D1 (sonnet/low) — sole SPEC writer, after everything.

**Critical path:**
T-R1 → T-U1 → T-U2 → T-U3/T-U4 → T-V2 → T-D1
(parallel spine on the backend: T-R2 → T-C1 → T-C2 → T-V1, which merges into T-D1).
The two opus/xhigh–high nodes gating the schedule are **T-U2** (menu, the riskiest
UI) and **T-C1/T-C2** (the real backend). Everything in Wave 1 and T-C3/T-C4 is
slack relative to those.

---

## E. Test + docs / registry impact

- **New unit tests (in `AudioutedCoreTests`, keep the existing 10 green):**
  T-C1 (URLProtocol-stubbed backend → BackendEvent assertions), T-C2 (rate-parse +
  explicit-playback command order, stubbed client), T-C3 (persistence round-trip,
  proportional scaling/clamp, average-echo, activate→setOutputSet). No AppKit in
  any unit test (all model/backend logic lives in `AudioutedCore`).
- **Existing tests:** `MockBackendTests` (5) + `BackendKindResolutionTests` (5)
  must stay green through T-C4's rename and the resolver staying intact.
- **Scripted verifications:** T-V1 (`dev/verify-1-realpath.sh`, extends the
  verify-0f* family) and the T-V2 acceptance checklist — both human-run, PASS/FAIL.
- **Docs/registry:** `dev/README.md` (real backend + how to run the app),
  `SPEC.md` §5/§9 (T-D1), the two new briefs in `dev/notes/`, and the
  `AIRPLAY_BACKEND` toggle wording if T-C4 adds a neutral alias.
- **Package.swift:** one edit (T-U1) adds the `AudioutedApp` executable
  target/product. New files in the existing library target need NO Package.swift
  edit (SPM globs Sources/).

---

## F. Open risks / confirm during execution

1. **Menu mutation while open (Q5/T-R1).** The whole in-place expansion (T-U2)
   and the swap-in editor (T-U3) hinge on T-R1's verdict. If live mutation is
   unreliable, the fallback (`menuNeedsUpdate` rebuild) changes T-U2/T-U3's shape
   — keep those tasks flexible until T-R1 lands.
2. **Editable NSTextField inside an NSMenu (T-R1/T-U3).** First-responder /
   key-event routing for a text field hosted in a menu item view is genuinely
   uncertain; if it can't be made to work, the group-name editor may need to fall
   back to a small child window/sheet — flag early.
3. **audiocap TCC churn (Q2).** Subprocess model means the *app* doesn't hold the
   capture grant, but the `audiocap` binary's ad-hoc grant still resets on rebuild
   (PLAN-0e-0f.md:114). Batch T-V1 after audiocap is stable; expect a re-grant.
4. **Mute/solo mapping (Q4).** Volume-based mute must restore the exact prior
   volume and survive websocket-echoed updates without fighting the user; watch
   for feedback loops between the app's optimistic update and the backend echo.
5. **Zombie de-selection recovery (0f invariant).** T-C1/T-C2 must actually
   re-select an output that OwnTone silently drops while reporting `play`
   (0f-pipe-brief.md:85-89); easy to miss without a long soak — T-V1 should
   include a stall/resume step.
6. **No real speakers (constraint).** All Phase-1 verification is mock + fake
   shairport; true AirPlay-2 PTP sync / real per-device volume remain the
   PLAN-0e-0f.md "deferred real-hardware checkpoints" — Phase 1 "done" is
   explicitly the fake-receiver + mock bar, not real multi-room.
7. **Deployment-target split (Q2).** If Alec picks the in-process library (Q2(b)),
   the app target inherits `.macOS(14.4)` and Package.swift/target graph changes
   materially — re-scope T-C2 and T-U1 before starting.
8. **Naming vs env value (T-C4).** SPEC §4 bans new OwnTone-named *public* API but
   PLAN-0e-0f.md Q5 kept `AIRPLAY_BACKEND=owntone`. Confirm whether the env value
   also renames now or stays until the native sender lands (recommend: keep the
   env value, rename only public Swift symbols).

---

## RESOLVED DECISIONS (Alec, 2026-07-13) — authoritative, supersedes the open questions above

- **Q1 App target:** SwiftPM executable + `.accessory` activation policy + bundle
  script producing a real double-clickable `.app`. No Xcode project.
- **Q2 Capture integration: SUBPROCESS.** The app spawns the audiocap-derived
  helper binary (embedded in the .app bundle) and manages its lifecycle.
  Rationale: capture TCC grant survives app rebuilds (dev ergonomics), crash
  isolation, core stays macOS 13.
- **Q3 Persistence:** versioned JSON in Application Support.
- **Q4 Mute/solo:** volume-based at the protocol level (mute = volume 0 with
  prior value remembered; solo = mute others; unmute restores). Backend-agnostic.
- **Q5 Menu mutation:** research brief first (T-R1), build to its verdict.
- **Q6 Master math:** UI-agnostic GroupController in AudioutedCore, unit-tested.
- **Q7 OwnTone lifecycle:** connect-only; the app never supervises the server.
- **Q8 Meters: SKIPPED in Phase 1 entirely** (Alec's choice, differs from the
  plan's recommendation — no meter UI until per-device meters can be real in v2).
- **NEW (project-wide): the project is OPEN SOURCE, GPL-2.0-or-later** (Alec may
  redistribute). Affects headers/LICENSE files as tasks touch code.

## WAVE 1 RESULTS + LATE DECISIONS (2026-07-13)

- **T-R1 ✅** (dev/notes/p1-menu-brief.md): live NSMenu insert/remove WORKS (in-place
  expansion viable; fallback documented). Editable NSTextField in menus IMPOSSIBLE
  (no keyboard events) → **Alec decided: QUICK-CREATE in menu (auto-named from
  current setup), rename/membership editing in the main window** (SPEC §9 revised).
  T-U3 scope changes accordingly: menu gets a one-shot "Save current setup as
  group" action; the editor form moves into T-U4's window (edit pane).
- **T-R2 ✅** (dev/notes/p1-owntone-api-brief.md): **websocket push NEVER delivered
  events in live testing → POLL every 1s is primary** (contradicts plan assumption);
  `type` field is "AirPlay 1"/"AirPlay 2" (prefix-match); outputs/set can 204 while
  silently failing (re-GET to confirm); play-on-empty-queue 500s; pipe re-find via
  `expression=data_kind is pipe`. 7-item "don't assume" list in the brief.
- **T-C3 ✅**: GroupController + GroupStore + 20 tests (30 total green). No
  OutputBackend protocol changes needed. Mute×solo semantics: explicit mute is
  authoritative; silence-edge stash/restore.

## WAVE 2/3 RESULTS (2026-07-13)
- **T-C1 ✅** real OwnToneBackend: poll-primary (websocket best-effort), zombie recovery via re-select + coordinator replayHook, unreachable→unavailable+auto-recover. 8 tests. Names kept internal for T-C4 rename.
- **T-U1 ✅** app skeleton: AudioutedApp executable target, real .app bundle (LSUIElement, ad-hoc signed, launches/quits clean), status item, mock-first.
- **T-U2 ✅** the menu: pure-AppKit dropdown, LIVE in-place group expansion (no fallback needed), shared DeviceRowView, quick-create action. Menu factored into AudioutedMenuUI library target (testable). 45 tests + 28-check harness.
- **T-U3 ABSORBED**: quick-create landed in T-U2's menu; the group EDITOR (rename/membership) moves into T-U4's window. No separate T-U3.
- Remaining: T-C2 (capture coordinator), T-U4 (window + group editor), T-C4 (neutral rename), T-V1/T-V2 (verify, USER-GATED), T-D1 (docs).

## T-U5 ✅ (2026-07-13) group creation + dedup + Solo removal
Manual creation ("+" in sidebar → draft editor), multi-select-to-group (sidebar
NSOutlineView), dedup/identity (group(matchingMemberSet:), groupMatchingCurrentSelection,
syncActiveGroupToSelection, createGroup returns {group, alreadyExisted}), menu save-action
disabled when selection==a group. SOLO REMOVED everywhere (Device/OutputBackend/
GroupController/MockBackend/OwnToneBackend/DeviceRowView), mute kept. 81 tests green.

## T-U6 (NEXT) — POPOVER REBUILD + on/off routing model
Replace the NSMenu dropdown with a Control-Center-style NSPopover (SPEC §9 revised).
Implement the core routing model: per-speaker ON/OFF "send audio here" (primary) +
mute (secondary); audio → all ON speakers; groups = presets; active group derived
from on-set. Master on EVERY group; click-anywhere-row toggle WITH animation.
Reuses GroupController + DeviceRowView + GroupRowView; window UI must keep working.
