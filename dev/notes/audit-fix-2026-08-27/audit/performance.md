# Audiout — macOS UI performance audit

Read-only sweep of `AudioutApp`, `AudioutPopoverUI`, `AudioutWindowUI`, `AudioutSettingsUI`,
`AudioutOnboardingUI`, `AudioutSharedUI`, and the main-thread edges of `AudioutCore`.
All line numbers are from the worktree at
`/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/xenodochial-ardinghelli-fa348b`.

Impacts are labelled **measured** or **reasoned**. Nothing here was profiled — no build or test
was run — so every impact claim is reasoned from the call graph unless it says otherwise.

---

## Verdict

This UI layer is unusually disciplined for its size. The things that normally kill a live-audio
menu-bar app are already right: metering is gated on surface visibility down to the RMS pass
itself, the level meter's display link stops at rest, the rail pulse fires from a model diff and
never from a draw, the EQ processor hands the audio thread a `try()`-mailbox that allocates and
frees nothing, and the popover deliberately does no rebuild while hidden — with the audit note
explaining the storm that taught it. There is no synchronous network, no disk read, and no
Bonjour resolution reachable from a UI paint.

What is wrong is a different shape: **the main thread reaches down into the backend's serial
queues to read facts that could be pushed to it.** `PopoverController.update(devices:)` and
`rebuild()` — the popover-open path — both funnel through `deviceSections()`, which calls
`btLastUsedProvider`, which is `stateQueue.sync` on `NativeBackend`. That queue has 84 `.sync`
sites, folds Bluetooth enumerations, replays route tables, and runs synchronous CoreAudio HAL
reads. A menu-bar click can therefore park the main thread behind whatever the backend happens to
be doing. That is the one P0. Two smaller siblings (`captureControlQueue.sync` for the Sync
drawer's range, `backend.devices` from `GroupController`) are the same mistake at lower blast
radius, and two of them are already in the repo's own STABILITY ledger, unresolved.

Below that sits a band of steady-state waste that matters specifically because this app runs 24/7
in venues: a 120 Hz `Timer` driving a full Auto Layout solve twice per display frame during every
fold; a Touch Bar hook that invalidates and re-creates a run-loop timer up to 25 Hz × N devices
whenever audio is audible; per-app meter events that skip the coalescer the device meters use
(the code says so itself); one app-wide `.mouseMoved` monitor *per mounted row*; and no
`occlusionState` handling anywhere, so a pinned-but-covered surface keeps every meter's display
link and the connecting ring's infinite pulse alive.

Audio-adjacency is close to clean. The one real contact point is `emitLevel`, which does a
`stateQueue.async` — a heap-allocating dispatch enqueue — on the tap's IOProc thread, per buffer.
It is gated on metering, which is what keeps it from being a P1.

None of these are architectural. The P0 is a provider swap, the biggest P1s are a timer source
change and a hoisted `if`.

**Counts — P0: 1 · P1: 6 · P2: 11 · P3: 7 (25 findings).**

---

## Hunt 1 — Main-thread hazards

### P0-1 · Popover open blocks on the backend's serial state queue

**Location**
- `AudioutPopoverUI/PopoverController.swift:1514` and `:1523` — `deviceSections()` → `orderedBluetoothDevices(in:)`
- `AudioutPopoverUI/PopoverController.swift:1673-1675` — `orderedBluetoothDevices` calls `btLastUsedProvider?()`
- `AudioutApp/AppDelegate.swift:564-566` — the provider is wired to the backend
- `AudioutCore/NativeBackend.swift:7632-7634`:
  ```swift
  public func lastUsedDatesForBTDevices() -> [String: Date] {
      stateQueue.sync { btLastUsed }
  }
  ```
- `AudioutCore/NativeBackend.swift:514` — `private let stateQueue = DispatchQueue(label: "NativeBackend.state")`

**Impact (reasoned).** `deviceSections()` is on both hot paths: `rebuild()` calls it at
`PopoverController.swift:1339`, and `update(devices:)` calls it *twice* per backend event
(`:892` for `expectedSubsections`, `:893` via `renderedDeviceOrder()` → `:1533` → `deviceSections()`).
Each call blocks the main thread on `stateQueue`. That queue is where the backend folds Bluetooth
snapshots (`:1739`), replays effective route tables on every `commitKnownDevice`, converges devices,
and reads Core Audio synchronously — `currentOutputDeviceName()` (`:6230-6290`) issues up to four
`AudioObjectGetPropertyData` calls, which are IPC to `coreaudiod`. If the queue is mid-block when
the user clicks the menu bar, the popover open waits for it. The repo's own memory records a
`coreaudiod` storm, so a slow HAL read is not hypothetical here.

Needs live check for the measured stall distribution; the *reachability* is proven by the call
chain above.

**Recommendation.** `btLastUsed` needs no queue. Guard it with a lock and read it lock-free the
way the sibling BT accessors already do — `btSyncTrim(forDevice:)` at `NativeBackend.swift:9440-9442`
is `btTrimLock.withLock { ... }`, exactly the right shape. Alternatively, push the recency map to
the main actor on each BT snapshot (the backend already emits device events there) and let the
popover read a plain stored property. Either removes every `.sync` from the open path.

### P1-2 · Sync drawer's trim range blocks on the capture-control queue

**Location** `AudioutCore/NativeBackend.swift:9608-9612`
```swift
public func btUsableTrimRangeMs(forDevice id: String) -> ClosedRange<Double> {
    captureControlQueue.sync {
        btSink?.usableTrimRangeMs(forDeviceUID: id) ?? (-BTSyncTrim.rangeMs...BTSyncTrim.rangeMs)
    }
}
```
Called from `AudioutPopoverUI/PopoverController.swift:2431` (`btTrimRange(for:)`), which
`reconcileSyncDrawer` runs whenever the drawer mounts or the device's usable range must be re-read.

**Impact (reasoned).** `captureControlQueue` (`NativeBackend.swift:707`) is the tap-rebuild queue.
A tap rebuild is a multi-hundred-millisecond operation. Opening the Sync drawer while one is in
flight freezes the surface for its duration. Narrower than P0-1 (drawer-only, not every open) but
the queue behind it is slower.

**Recommendation.** Cache the usable range alongside the trim under `btTrimLock` and refresh it
from the sink whenever the sink changes, rather than reading through on demand.

### P1-3 · `GroupController` reads devices through `stateQueue.sync` on click paths

**Location**
- `AudioutCore/GroupController.swift:228` — `public var devices: [Device] { backend.devices }`
- `AudioutCore/GroupController.swift:230-233` — `private func device(_ id: String)`, carrying the ledger marker
- `AudioutCore/GroupController.swift:272` — `localDeviceID`
- `AudioutCore/GroupController.swift:189` — `backend.devices.first(where: \.isLocalDevice)`
- `AudioutCore/NativeBackend.swift:1600-1603` — `public var devices: [Device] { stateQueue.sync { ... } }`

Already ledgered: `// STABILITY(C8): main thread blocks on the state queue for slow work`.

**Impact (reasoned).** These fire from user actions, not from paint — `setDeviceSelected`,
`ensureDefaultSelection`, auto-swap. Same queue as P0-1, so the same worst case, but only on a
click rather than on every event and every open. Good news for the paint path: the per-row
predicates the repaint actually uses (`isSpeakerSelected` `:276`, `isMainOutMember` `:822`,
`isMuted` `:890-892`) are in-memory set lookups, and `AppDelegate`/`PopoverController` render from
their own `devicesByID` snapshots — so no `.sync` is hit per row.

**Recommendation.** Have `GroupController` hold the last device snapshot pushed to it (the same
one `AppDelegate.repaintFromCurrentState` already builds at `AppDelegate.swift:1673`) instead of
reading through to the backend.

### P1-4 · Routing persistence writes to disk synchronously on the main thread

**Location** `AudioutCore/GroupController.swift:217-222` — `persistRouting()` → `try? routingStore.save(state)`,
carrying `// STABILITY(D4): UI-thread stalls and stuck-drag state`.

**Impact (reasoned).** Every selection change (a checkbox toggle, an auto-swap, a group activation)
serialises and writes JSON on the main thread. Small file, but it is a filesystem round-trip inside
a gesture, and the ledger already attributes UI stalls to it.

**Recommendation.** Coalesce and write off-main; the store is already the only writer.

### P2-5 · Unconditional blocking `write(2)` to stderr on the MainActor for every backend event

**Location**
- `AudioutApp/AppDelegate.swift:21-35` — `audioutEmergencyWriteStderr` is a raw `write(2)` loop
- `AudioutApp/AppDelegate.swift:1732-1734` — `log(_:)` calls it unconditionally
- `AudioutApp/AppDelegate.swift:1522-1658` — `apply(_:)` calls `log("event: \(describe(event))")`
  for `deviceAdded`, `deviceUpdated`, `deviceRemoved`, `systemVolumeChanged`, `routedApps`,
  `routedAppRunning`, `remoteTransport`, `localFallbackActive`, `systemDefaultIsAirPlayActive`,
  `streamHealth`, `takeoverStatus`, `routingBlockedNeedsDefault`,
  `systemVolumeOwnershipChanged`, `btFirstMixAlignmentPrompt`
- `AudioutApp/AppDelegate.swift:1693-1730` — `describe(_:)` builds a formatted `String` per event

**Impact (reasoned).** There is no level or env gate. The interpolation is eager, so the `String`
is built whether or not anyone reads it, and the write is a blocking syscall on the MainActor. Idle
is quiet (`applyLocal` at `NativeBackend.swift:8377-8386` guards `device != before`, so unchanged
devices emit nothing), but a fader drag emits one `deviceUpdated` per step and connection churn
arrives in bursts. `.level`/`.appLevel` correctly bypass this — only the debug-gated 1 Hz line at
`:1536` logs them.

**Recommendation.** Route `log(_:)` to `os.Logger` (async, ring-buffered, free when nobody is
reading) and keep `audioutEmergencyWriteStderr` for exactly what its doc comment describes — the
uncaught-exception path in `main.swift:48`. Or gate it on an env var like `debugLevels` at `:235`.

### P2-6 · `SMAppService.status` polled on the main thread every 1.5 s during onboarding

**Location**
- `AudioutOnboardingUI/OnboardingViewController.swift:495-504` — `startPTPHelperPoll()`
- `AudioutCore/SetupModel.swift:896-901` — `refreshPTPHelperStatus()` reads `ptpHelper.status`
- `AudioutCore/PTPHelperService.swift:47-50` — documented as "Read fresh, not cached"
- `AudioutSettingsUI/GeneralSettingsViewController.swift:291` — the ledger marker naming this
  exact cost: *"SMAppService register/status round-trips launchd XPC synchronously on the main thread"*

**Impact (reasoned).** An XPC round-trip to launchd, on the main thread, at 1.5 s intervals for as
long as the setup window sits open on an unapproved helper. The sibling poll
(`startRemoteControlPoll`, `:481-490`) is fine — `AXIsProcessTrusted()` is a cheap in-process read.
Both self-invalidate on grant, which is correct.

**Recommendation.** Move the status read to a background queue and hop back with the result; the
poll is a 1.5 s cadence, so the extra hop costs nothing.

### P3-7 · Sparkle updater started before the status item exists

**Location** `AudioutApp/AppDelegate.swift:366-370` — `SPUStandardUpdaterController(startingUpdater: true, ...)`,
26 lines ahead of `statusItemController = StatusItemController()` at `:408`.

**Impact (reasoned).** Starting the updater reads defaults and arms a scheduled check before the
menu-bar icon can appear. Paid builds only (gated on `SUFeedURL`), so it does not affect a
from-source build at all.

**Recommendation.** Move it below the status item, or into a `Task { @MainActor }` after launch settles.

---

## Hunt 2 — Redraw economy

### P1-8 · `FoldAnimator` runs a 120 Hz `Timer` that forces two Auto Layout solves per frame

**Location**
- `AudioutSharedUI/FoldAnimator.swift:101-105`:
  ```swift
  let ticker = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.advance(to: CACurrentMediaTime()) }
  }
  RunLoop.main.add(ticker, forMode: .common)
  ```
- `AudioutSharedUI/FoldAnimator.swift:136-140` — each tick calls `follower.foldAnimatorDidTick()`
- `AudioutPopoverUI/PopoverPanelViewController.swift:465-467` → `publishContentSize(fittingSizeSettled(), ...)`
- `AudioutPopoverUI/PopoverPanelViewController.swift:411-417`:
  ```swift
  func fittingSizeSettled() -> NSSize {
      _ = view
      view.layoutSubtreeIfNeeded()
      return contentContainer.fittingSize
  }
  ```

**Impact (reasoned).** `layoutSubtreeIfNeeded()` solves the whole popover tree; `fittingSize` is a
*second, separate* constraint solve on the content column. Both run 120 times a second for the
fold's duration, on a display that is usually 60 Hz — so half the solves are discarded before the
next frame is drawn. On a panel with a dozen device rows (each a deep view with a halo ring, meter,
fader, feed pill and stack views), that is the single most expensive repeating operation in the UI.
The `Timer` also sets no `tolerance`, so it demands precise wake-ups (see P3-18).

**Recommendation.** Drive it from `NSView.displayLink(target:selector:)` — the idiom `LevelMeterView`
already uses at `LevelMeterView.swift:283-286` — so ticks are vsync-aligned and the work happens
exactly once per presented frame. The `.common`-mode requirement (a fold started by a held
mouse-down) is satisfied by adding the link to `RunLoop.main` in `.common` rather than `.default`.
The one-clock invariant this class exists to protect is untouched by the change of clock *source*.

### P2-9 · Rail overlay fully re-resolves and re-strokes on every layout pass

**Location**
- `AudioutPopoverUI/PopoverPanelViewController.swift:1516-1522`:
  ```swift
  final class RailStackView: NSStackView {
      weak var railOverlay: BusRailOverlayView?
      override func layout() {
          super.layout()
          railOverlay?.needsDisplay = true
      }
  }
  ```
- `AudioutSharedUI/BusRailOverlayView.swift:166-171` — `draw(_ dirtyRect:)` ignores `dirtyRect` entirely
- `AudioutSharedUI/BusRailOverlayView.swift:176-216` — `resolvePlan()` walks every device row,
  converts each `railNodeBounds` into overlay space, sorts the stops, and re-resolves the clip bands
- `AudioutSharedUI/BusRailOverlayView.swift:283-...` — `wireRuns(for:)` rebuilds every `NSBezierPath`

**Impact (reasoned).** The invalidation is unconditional: any layout pass at all — a label width
change, a row `apply`, a fold tick — re-runs the full geometry resolution and re-strokes the whole
wire. During a fold this compounds directly with P1-8 (120 layout passes/sec → 120 full rail
redraws/sec). The class doc justifies the per-frame resolve *during a collapse*, which is right;
what is not paid for is the same cost on every unrelated layout.

**Recommendation.** Memoise the resolved `RailPlan` (it is already a pure function of a plain-value
`RailPlan.Input`) and skip the `needsDisplay` when the newly resolved input equals the last one.
`RailPlan.Input` is already the natural equality key.

### P2-10 · EQ response curve repaints the whole scope per band change

**Location** `AudioutSharedUI/EQResponseCurveView.swift:248-283` — `draw(_ dirtyRect:)` ignores
`dirtyRect` and runs `drawRuler` (three `NSAttributedString` draws), `drawGrid`, and `drawTrace`.

**Impact (reasoned).** A continuous EQ fader drag produces a new `DeviceEQ` per step, so this runs
at roughly display rate for the length of the drag, re-laying out and re-drawing static text every
frame. The dynamic part is the trace; the ruler and grid never change.

**Recommendation.** Put the ruler and grid on their own `CALayer` (or a cached `NSImage`) drawn once
per bounds change, and let `draw` repaint only the trace. The change-guard and `cachedPlan`
memoisation at `:236-244` are already correct and should stay.

### P3-11 · A subview property is mutated inside `draw(_:)`

**Location** `AudioutSharedUI/DeviceRowView.swift:2789` — `nameLabel.textColor = rowTextColor`,
immediately before `super.draw(dirtyRect)`.

**Impact (reasoned).** Setting a control's property during the enclosing view's display pass can
re-dirty the subview from inside the pass. Harmless in practice today, but it is the kind of thing
that turns into a second display cycle per frame under a future change.

**Recommendation.** Move it into `apply(...)` where the other row state is pushed.

### P2-12 · No occlusion handling anywhere in the UI

**Location** Absence. A grep for `occlusionState`, `didChangeOcclusionState`, and
`NSApplication.didHideNotification` across `AudioutPopoverUI`, `AudioutSharedUI`, `AudioutWindowUI`
and `AudioutApp` returns nothing. The only visibility gate is `hostIsShown` /
`isEffectivelyShown` (`PopoverController.swift:1206`, set by `surfaceDidShow`/`surfaceDidHide` at
`:4422` / `:4465`), which means "the surface was ordered in", not "pixels are reaching a human".

**Impact (reasoned).** The surface is pinnable and the venue case leaves it open all day. Pinned and
fully covered by another window, or with the app hidden, the app still: computes RMS in the tap
(`meteringActive` stays true), pushes ~25 Hz × N level events through the whole main-actor chain,
runs one `CADisplayLink` per non-silent meter, and keeps `HaloRingView`'s
`repeatCount = .infinity` breathing group alive for every connecting device
(`HaloRingView.swift:341-345`). That is continuous CPU and GPU for nothing, 24/7, on battery.

**Recommendation.** Fold `window.occlusionState.contains(.visible)` and
`NSApp.isHidden` into `isEffectivelyShown`, and re-run the existing
`onMeteringActiveChange` / `resetLevel()` path on the transition. The machinery to stop everything
already exists — `surfaceDidHide` does exactly the right work at `:4465-4494`; it just needs a
second trigger.

---

## Hunt 3 — Discovery / state churn

### P1-13 · Hidden-surface events pay for structural diffs nobody reads

**Location** `AudioutPopoverUI/PopoverController.swift:892-896`
```swift
let expectedSubsections = deviceSections().filter { rendersHeader($0) }.map(\.title)
let deviceSetChanged = Set(renderedDeviceOrder().map(\.id)) != Set(deviceRowsByID.keys)
    || expectedSubsections != renderedSubsectionTitles
if isEffectivelyShown {
    if routesChanged || deviceSetChanged || validTargetsChanged || mainOutMembersChanged {
```

**Impact (reasoned).** `expectedSubsections` and `deviceSetChanged` are computed *outside* the
visibility gate and read *only* inside it. Computing them costs two full `deviceSections()` runs
(`renderedDeviceOrder()` at `:1533` calls it again), each of which sorts `orderedDevices()`, runs
five filter passes, **and takes a `stateQueue.sync` via `orderedBluetoothDevices`** — so this is
also two instances of P0-1 per hidden backend event. During a volume-key repeat with the surface
closed, that is two blocking queue hops per key repeat, for a result that is discarded.

**Recommendation.** Move `:892-894` inside the `if isEffectivelyShown` block. One-line hoist; it
removes the wasted diffs and half the P0-1 exposure at the same time.

### P2-14 · `rebuild()` tears down and re-allocates the whole view tree

**Location**
- `AudioutPopoverUI/PopoverController.swift:1260-1306` — `rebuild()` clears `deviceRowsByID`,
  `appRowsByBundleID`, every panel, then `panel.clearRows()`
- `AudioutPopoverUI/PopoverPanelViewController.swift:472-487` — `clearRows()` removes and
  un-parents every arranged subview
- `AudioutPopoverUI/PopoverController.swift:2075` — `DeviceRowView(device:...)` allocated fresh
- `AudioutPopoverUI/PopoverController.swift:2932` — `AppRowView(showsMeter: true)` allocated fresh
- Triggered at `:896` by `routesChanged || deviceSetChanged || validTargetsChanged || mainOutMembersChanged`

**Impact (reasoned).** `DeviceRowView` is a 3149-line view carrying a halo ring, a level meter with
its own display link, a fader with a custom cell, a feed pill, a route-armed dot and its own event
monitor. Every rebuild destroys and re-creates one per device plus one per routed app. The trigger
set includes `validTargetsChanged`, which flips on a *mere availability change* — so a Wi-Fi blip
or a receiver going quiet rebuilds the entire panel, resetting every meter's ballistics and
churning every row's event monitor (see P2-15). `deviceSetChanged` is correctly compared against
what *should render* rather than the whole fleet (the comment at `:884-891` explains why), which
already prevents the worst case; the remaining cost is the teardown itself.

**Recommendation.** Reuse rows keyed by device id — `deviceRowsByID` is already the right index.
Mount and unmount only the delta, and re-`apply` the survivors. The rest of `rebuild()`'s intent
restoration (diagnosis panels, sync drawer, BT wizard) is already written to survive a teardown, so
this is contained.

### P2-15 · Every mounted row installs its own app-wide `.mouseMoved` monitor

**Location**
- `AudioutSharedUI/DeviceRowView.swift:2741-2751` (with the `STABILITY(D4)` marker at `:2743`)
- `AudioutSharedUI/AppRowView.swift:794-800`
- `AudioutPopoverUI/GroupRowView.swift:354-360`
- Handler: `DeviceRowView.swift:2713-2722` — `refreshHoverFromPointer()`, two coordinate
  conversions plus two change-guarded setters
- Installed/removed per `viewDidMoveToWindow` (`:2729-2739`), i.e. churned on every rebuild

**Impact (reasoned).** With ~10 device rows and a few app rows mounted, a single pointer move runs
~15 separate monitor closures. Mouse-move events arrive at the pointer's report rate — 100 Hz for a
plain mouse, far higher for a gaming mouse — so moving the pointer across the surface costs
1500+ closure invocations per second, each doing coordinate math on the main thread. The individual
cost is small; the multiplication is the problem, and it grows linearly with the fleet. The ledger
marker explicitly asks for a multiplicity fix rather than a pattern change, which is the right call.

**Recommendation.** One monitor owned by `PopoverPanelViewController` (or `PopoverController`) that
fans out to the mounted rows. That also removes the install/remove churn from every rebuild.

---

## Hunt 4 — Timers & wake-ups

### P1-16 · Touch Bar hook re-creates a run-loop timer on every meter tick

**Location**
- `AudioutApp/AppDelegate.swift:1545` — `touchBarFullBar.noteAudioLevel(rms)`, called
  unconditionally for every `.level` event
- `AudioutApp/TouchBarFullBar.swift:106-117`:
  ```swift
  func noteAudioLevel(_ rms: Float) {
      guard rms > 0.002 else { return }
      silenceTimer?.invalidate()
      silenceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { ... }
      setPlaying(true)
  }
  ```
- `AudioutApp/AppDelegate.swift:291-308` — `touchBarFullBar` is `lazy`, and this call is what
  forces it into existence

**Impact (reasoned).** Device `.level` events arrive at ~25 Hz per device (see the coalescer at
`NativeBackend.swift:8636`). With six selected speakers and audio playing, that is ~150
invalidate-plus-allocate-plus-schedule cycles per second against the main run loop's timer heap —
each one a `Timer` object, a run-loop source removal and a re-insertion. The only thing the
function actually needs is "was audio audible recently", a boolean that changes at most twice a
minute. It also runs on Macs with no Touch Bar, and it instantiates the whole `TouchBarFullBar`
to do so.

**Recommendation.** Store a `lastAudibleAt: CFTimeInterval` and drive `setPlaying(false)` from a
single repeating 1 s timer that only exists while `isPlaying`. Failing that, only reschedule when
the new deadline is more than ~0.5 s past the current one.

### P2-17 · Per-app meter events skip the coalescer the device meters use

**Location**
- `AudioutCore/NativeBackend.swift:8774-8776` — the code names it:
  *"The `.appLevel` itself is emitted directly, not through the D3 coalescer, which is per-device
  `.level` only — app-level coalescing is a tracked follow-up."*
- Three emit sources, all per captured buffer:
  `NativeBackend.swift:1583-1585` (`routeMixer.onAppLevel`),
  `:1592-1595` (`meteringCapture.onBuffer`),
  `:2059-2061` (`localPlaybackEngine.onAppLevel`)
- Contrast with the device path: `levelEmitIntervalNanos = 40_000_000` (`:8636`) and the
  leading/trailing sampler at `:8820-8851`

**Impact (reasoned).** At the 352-frame AirPlay chunk and 44.1 kHz, a buffer is ~8 ms, so each
routed app emits at ~125 Hz against the device path's 25 Hz. Each event costs a `stateQueue.async`
from an IOProc or mixer thread, an `AsyncStream` yield, an `await MainActor.run`
(`AppDelegate.swift:1516`), and a row `setLevel`. Three routed apps is ~375 main-actor hops/sec
where the device path would produce 75.

**Recommendation.** Reuse `scheduleLevelEmit`'s leading/trailing sampler, keyed by bundle ID. The
function is already generic over an id string.

### P3-18 · `FoldAnimator`'s timer sets no tolerance

**Location** `AudioutSharedUI/FoldAnimator.swift:101` — `Timer(timeInterval: 1.0 / 120.0, repeats: true)`.

**Impact (reasoned).** A zero-tolerance timer forces the kernel to wake the process precisely every
8.3 ms, defeating timer coalescing for the fold's duration. Bounded by
`Tokens.Motion.collapseRevealDuration`, so it is a per-gesture cost, not a steady-state one.

**Recommendation.** Superseded by P1-8 (a display link has no tolerance question). If the timer is
kept, set `ticker.tolerance = 1.0 / 240.0`.

### P3-19 · Onboarding's status polls run while the window merely sits open

**Location** `AudioutOnboardingUI/OnboardingViewController.swift:481-504` — two 1.5 s repeating timers.

**Impact (reasoned).** Both self-invalidate the moment the permission is granted, which is correct
and well done. They do keep running indefinitely if the user leaves the setup window open without
ever granting. The Accessibility poll is cheap; the PTP one is P2-6.

**Recommendation.** Stop both when the window resigns key, restart on `appDidBecomeActive` (which
already exists at `:466-477`).

---

## Hunt 5 — Launch path

### P2-20 · Two synchronous disk reads run before `NSApplicationMain`

**Location** `AudioutApp/main.swift:62` constructs `AppDelegate()`, whose **stored** (non-lazy)
properties all initialise at that point — before the run loop starts and therefore before the
status item can appear:
- `AudioutApp/AppDelegate.swift:72` — `let backend: OutputBackend = makeBackend(resolver:)`
- `AudioutApp/AppDelegate.swift:100` — `let settings = AppSettings()`
- `AudioutApp/AppDelegate.swift:124` — `let permissionProviders = PermissionMode.resolved().makeProviders()`
- `AudioutApp/AppDelegate.swift:193` — `let permissionObserver = PermissionStateObserver()` (registers a `CFNotificationCenter` observer)
- `AudioutApp/AppDelegate.swift:~218` — `let deviceIconController = DeviceIconController(loadPersisted: true)` — **synchronous `store.load()`**, `DeviceIcon.swift:112-115`
- `AudioutApp/AppDelegate.swift:~225` — `let excludedApps = ExcludedAppsController(store: ExcludedAppsStore())` — **synchronous store load**

**Impact (reasoned).** Two Application Support reads on a cold page cache, ahead of first pixel.
Small files, so tens of milliseconds at worst — but this is a menu-bar app whose entire launch
budget is "how fast does the icon appear", and neither store is read until well after the status
item exists (`AppDelegate.swift:408`).

**Recommendation.** Make `deviceIconController` and `excludedApps` `lazy var`. Nothing touches them
before `applicationDidFinishLaunching` wires the popover at `:507`.

### Positive on this hunt
The two network calls in `applicationDidFinishLaunching` are genuinely non-blocking:
`LicenseCheckIn.checkInIfNeeded()` ends in `URLSession.shared.dataTask(with:).resume()`
(`LicenseCheckIn.swift:65-67`) and `LicenseValidator.validate` parses off-main and hops back
(`LicenseValidator.swift:58-84`). The status item is created at `:408`, ahead of `GroupController`,
`AppRoutingController`, `PopoverController` and the ~30 backend capability hooks that follow it —
the ordering is deliberate and correct (the comment at `:401` says so).

---

## Hunt 6 — Memory over time

### P2-24 · An always-on telemetry write sits in the per-row render path

**Location** `AudioutPopoverUI/PopoverController.swift:2231-2240`
```swift
// Live diagnosis (2026-08-23): the raise fires but the pixels never move — log what the render actually hands the row.
if device.isCast, castVolumePendingIDs.contains(device.id) {
    Telemetry.log(.cast, "cast_pending_render", [ ... four interpolated fields ... ])
}
```
`Telemetry` is always-on in production (`AudioutCore/Telemetry.swift:110-117` — `enabled` is false
only under `HeadlessRuntime.isActive`), and `log` formats its JSON line **on the caller's thread**
(`:57-67`).

**Impact (reasoned).** `applySelectionState` runs once per device row per repaint, and repaints
happen on every backend event. For a Cast device with a pending volume, this builds a dictionary
and a JSON string on the main thread every time, and hands it to the writer queue for a disk append.
It is a dated live-diagnosis instrument, not a design decision. The file itself is size-bounded and
rotated, so disk growth is capped; the cost is CPU and I/O churn.

**Recommendation.** Remove it, or gate it behind an env flag. The `cast` category's separate 1 Hz
media-status sampling is a deliberate design choice and can stay.

### P3-22 · `AppTetherColor`'s static cache never evicts, and the lock spans icon sampling

**Location** `AudioutSharedUI/AppTetherColor.swift:62-69`, `:515-516`
```swift
public static func color(forBundleID bundleID: String, icon: NSImage?) -> NSColor {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    if let cached = cache[bundleID] { return cached }
    let color = makeColor(deriveTone(from: icon))
    cache[bundleID] = color
    return color
}
```

**Impact (reasoned).** The dictionary is bounded in practice by the number of distinct bundle IDs
ever routed, so unbounded growth is theoretical. The sharper edge is that `cacheLock` is held
across `deriveTone(from: icon)`, which samples the icon bitmap — an expensive operation inside a
mutual-exclusion region. `clearCache()` exists at `:114-117` but is described as a test seam.

**Recommendation.** Compute outside the lock and take it only for the read and the insert (a
duplicate computation on a race is harmless — the function is documented as deterministic).

### P3-23 · `btTrimsByID` session cache has no prune path

**Location** `AudioutPopoverUI/PopoverController.swift:334`, written at `:2278` and `:2440`.

**Impact (reasoned).** Bounded by distinct Bluetooth device ids seen in a session. Noted for
completeness rather than concern. Its siblings are pruned properly: `liveRoutedAppNames` is
filtered against the snapshot at `:795`, `offlineBundleIDs` is intersected with live routes at
`:1303-1304`, `energizePendingIDs` is re-filtered at `:1831`, and `openDiagnosisIDs` is cleaned at
`:2777-2778`.

---

## Hunt 7 — Audio adjacency

### P2-25 · The tap's IOProc thread performs a dispatch enqueue per buffer

**Location**
- `AudioutCore/NativeCaptureCoordinator.swift:1621-1622`:
  ```swift
  if snapshot.meteringActive, let onLevel {
      onLevel(Self.rmsOfS16LE(pcm))
  }
  ```
  with the contract at `:479-485`: *"Called from the tap's IOProc delivery thread — keep the
  handler cheap and lock-light."*
- `AudioutCore/NativeBackend.swift:2024` installs the handler:
  `self.captureCoordinator?.onLevel = { [weak self] rms in self?.emitLevel(rms) }`
- `AudioutCore/NativeBackend.swift:8758-8767` — `emitLevel` opens with `stateQueue.async { ... }`

**Impact (reasoned).** `DispatchQueue.async` allocates a heap block and enqueues it. Doing that on
the real-time audio thread is exactly what the handler's own contract asks callers not to do. It
also creates a priority-inversion surface: `stateQueue` is a default-QoS serial queue
(`NativeBackend.swift:514`), and the real-time thread enqueuing onto it will boost the queue rather
than block, but the allocation itself is unbounded-latency in principle. What keeps this off the P1
list is the `meteringActive` gate — with the surface closed, the RMS is not even computed, let
alone enqueued (this is the T-GATE, and it is the right design).

**Recommendation.** Have the audio thread store the RMS into an atomic (or a single-writer
`Float` slot) and let the existing 40 ms coalescer read it on `stateQueue`. That removes the
per-buffer allocation entirely while keeping the same emit cadence.

### P3-26 · The volume-key `CGEventTap` callback runs on the main run loop

**Location** `AudioutApp/VolumeKeyInterceptor.swift:114-134`, with an explicit ceiling note:
```
// razor: the main run loop. A tap whose callback is starved gets disabled
// by macOS, which `reenableIfDisabled` recovers from; if the main thread
// ever blocks badly enough for that to be routine, the upgrade path is a
// dedicated thread with its own run loop.
```

**Impact (reasoned).** Correctly scoped (only `NX_SYSDEFINED`, not `.keyDown` — the comment at
`:111-113` explains why that matters) and the ceiling is already documented with its upgrade path.
It is listed here because it *couples* every other finding in this report: any main-thread stall —
P0-1's queue block, P1-8's 120 Hz layout, P1-16's timer churn — is also a window in which macOS may
disable this tap and the user's volume keys stop working. That coupling raises the practical cost
of the main-thread findings above their individual severity.

**Recommendation.** No change on its own merits. Treat it as the reason to fix P0-1 and P1-8.

---

## Severity-ordered master list

| # | Sev | Finding | Primary location |
|---|-----|---------|------------------|
| 1 | **P0** | Popover open path blocks on `NativeBackend.stateQueue` via the BT recency provider | `PopoverController.swift:1523`, `1673`; `NativeBackend.swift:7632` |
| 2 | **P1** | Sync drawer's trim range blocks on `captureControlQueue` (the tap-rebuild queue) | `NativeBackend.swift:9608`; `PopoverController.swift:2431` |
| 3 | **P1** | `GroupController` reads devices through `stateQueue.sync` on click paths (ledgered C8) | `GroupController.swift:228-233`; `NativeBackend.swift:1600` |
| 4 | **P1** | Routing persisted to disk synchronously on the main thread per selection change (ledgered D4) | `GroupController.swift:217-222` |
| 5 | **P1** | `FoldAnimator` 120 Hz `Timer` → two full Auto Layout solves per frame, twice per display refresh | `FoldAnimator.swift:101`; `PopoverPanelViewController.swift:411`, `465` |
| 6 | **P1** | Hidden-surface events compute structural diffs nobody reads (and take two `stateQueue.sync` doing it) | `PopoverController.swift:892-896` |
| 7 | **P1** | Touch Bar hook invalidates + re-creates a run-loop timer up to 25 Hz × N devices | `AppDelegate.swift:1545`; `TouchBarFullBar.swift:106-117` |
| 8 | **P2** | Unconditional blocking `write(2)` + eager string build on MainActor per backend event | `AppDelegate.swift:21-35`, `1522-1658`, `1732` |
| 9 | **P2** | `SMAppService.status` (launchd XPC) polled on main every 1.5 s during onboarding | `OnboardingViewController.swift:497`; `SetupModel.swift:896` |
| 10 | **P2** | Rail overlay fully re-resolves + re-strokes on every layout pass, `dirtyRect` ignored | `PopoverPanelViewController.swift:1518-1521`; `BusRailOverlayView.swift:166`, `176` |
| 11 | **P2** | EQ response curve repaints ground + ruler text + grid on every band change | `EQResponseCurveView.swift:248-283` |
| 12 | **P2** | No `occlusionState` / `isHidden` gate — pinned-but-covered surface keeps meters and the infinite halo pulse alive | absent across all UI targets; `PopoverController.swift:1206` |
| 13 | **P2** | `rebuild()` tears down and re-allocates every row; an availability flap triggers it | `PopoverController.swift:1260`, `2075`, `2932` |
| 14 | **P2** | One app-wide `.mouseMoved` monitor **per row**, churned on every rebuild (ledgered D4) | `DeviceRowView.swift:2741`; `AppRowView.swift:794`; `GroupRowView.swift:354` |
| 15 | **P2** | `.appLevel` skips the 40 ms coalescer the device meters use (~125 Hz per routed app) | `NativeBackend.swift:8774-8776`, `1583`, `2059` |
| 16 | **P2** | Two synchronous store loads run before `NSApplicationMain` | `main.swift:62`; `AppDelegate.swift` stored properties |
| 17 | **P2** | Always-on telemetry write in the per-row render path (dated live diagnostic) | `PopoverController.swift:2231-2240` |
| 18 | **P2** | IOProc thread does `stateQueue.async` (heap alloc) per captured buffer | `NativeCaptureCoordinator.swift:1621`; `NativeBackend.swift:2024`, `8758` |
| 19 | **P3** | Sparkle updater started before the status item exists | `AppDelegate.swift:366-370` |
| 20 | **P3** | Subview property mutated inside `draw(_:)` | `DeviceRowView.swift:2789` |
| 21 | **P3** | Fold timer sets no `tolerance` (precise 8.3 ms wake-ups) | `FoldAnimator.swift:101` |
| 22 | **P3** | Onboarding polls keep running while the window merely sits open | `OnboardingViewController.swift:481-504` |
| 23 | **P3** | `AppTetherColor` cache never evicts; lock held across icon sampling | `AppTetherColor.swift:62-69`, `515` |
| 24 | **P3** | `btTrimsByID` session cache has no prune path | `PopoverController.swift:334` |
| 25 | **P3** | Volume-key `CGEventTap` callback on the main run loop (documented ceiling; couples every main-thread stall to dead volume keys) | `VolumeKeyInterceptor.swift:114-134` |

---

## Positive findings — patterns already done right

1. **`LevelMeterView` is the reference implementation.** Self-stopping `CADisplayLink`, only the
   mask's frame changes per frame, inside a `CATransaction` with actions disabled, plus an explicit
   "don't spin up a link just to discover it's at rest one frame later" guard. Zero CPU at rest is
   stated as the design goal and the code delivers it.
   `AudioutSharedUI/LevelMeterView.swift:230-308`.

2. **The metering gate (T-GATE) reaches all the way to the audio thread.** With the surface closed
   the RMS pass in the tap is skipped entirely, not merely ignored downstream.
   `AppDelegate.swift:531-537` → `PopoverController.swift:4425`/`4478` →
   `NativeCaptureCoordinator.swift:1618-1622`.

3. **Device level events are properly coalesced** with a leading/trailing-edge sampler at 40 ms, so
   a burst's final value always lands and the meter never freezes on a stale pre-quiet reading.
   `NativeBackend.swift:8636`, `8820-8851`.

4. **The popover does no rebuild while hidden, deliberately**, with the audit note naming the bug it
   fixed: *"Rebuilding here made every backend event a hidden full rebuild storm under volume-key
   repeat (audit B8)."* `PopoverController.swift:914-919`.

5. **The rail connect pulse fires from a model diff, never from a draw** — `lastConnectedMemberIDs`
   is diffed against the new snapshot, and the comment explains exactly which cheaper predicates
   were rejected and why. `PopoverController.swift:844-865`.

6. **`FoldAnimator` is a genuinely good design badly clocked.** One animated value, everything else
   laid out from it synchronously; the two-clock drift it replaced is documented with the live
   captures that found it. Only the timer source (P1-8) needs changing — the invariant is right.
   `FoldAnimator.swift:14-35`.

7. **`EQProcessor`'s mailbox is textbook real-time discipline.** `try()` rather than `lock()` on the
   processing thread so audio is never parked behind a writer; every allocation and every free
   happens on the writer thread; filter delay memory is carried across a retarget so a slider drag
   is silent rather than a crackle. `EQProcessor.swift:257-289`.

8. **`EQResponseCurveView.apply` is change-guarded with a memoised plan** — *"A no-op when neither
   input changed — a drag frame that re-sends the value already on screen must cost nothing."*
   `EQResponseCurveView.swift:236-244`.

9. **`HaloRingView`'s breathing pulse rides Core Animation, not a timer** — render-server driven,
   automatically stripped when the layer leaves the tree, re-added in `viewDidMoveToWindow`, and
   animated *over* the model layer so `cacheDisplay(in:to:)` still captures a settled ring.
   `HaloRingView.swift:330-345` and the doc comment at `:50-62`.

10. **Status item redraws are edge-triggered.** Both `updateMasterVolume` and
    `updateStreamingState` guard on an actual change before rebuilding the button image, which is
    what keeps the per-event repaint tail cheap. `StatusItemController.swift:104-122`.

11. **System volume is served from a cached last-seen value, not a blocking HAL read** — the doc
    comment states the reason outright: *"so a main-thread caller never waits on coreaudiod."*
    `NativeBackend.swift:2990-2993`. This is precisely the fix P0-1 needs applied to `btLastUsed`.

12. **The launch splash gates the first open on a discovery-settle debounce with a ceiling
    backstop**, rather than resizing the surface once per arriving device — and the quiet window is
    tuned wider than the observed inter-device gap so a trickling fleet cannot settle mid-stream.
    `AppSurfaceController.swift:280-310`; `DiscoverySettleTracker.swift`.

13. **Per-app capture debounces process-list churn before diffing membership**, so a burst of tab
    open/close notifications collapses into one diff. `PerAppCaptureCoordinator.swift:195-199`.

14. **The one-surface host does not resize the window on content-size changes** — the frame is fixed
    for the session and the resizer only notices overflow and logs it once. That removes an entire
    class of window-resize thrash from the fold path. `AppSurfaceController.swift:562-573`.

15. **Row-level caches are pruned against the live model** rather than left to accumulate:
    `liveRoutedAppNames` (`:795`), `offlineBundleIDs` (`:1303`), `energizePendingIDs` (`:1831`),
    `openDiagnosisIDs` (`:2777`), and every session-scoped set cleared in `surfaceDidHide`
    (`:4465-4494`).
