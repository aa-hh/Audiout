# Phase 3 Polish — Performance Feel Audit (A7)

Real measurements of launch time, popover latency, idle CPU, memory footprint,
and shipped-bundle size, plus a read-only hot-path review of the 25 Hz meter
path, discovery cadence, popover-open path, and slider-drag path. Every number
below states its method; nothing is estimated without saying so. No live
audio/AirPlay session was started and no PTP port was bound — every live
process used the **mock backend** (verified: mock fixtures "MacBook Pro
Speakers", "Sonos Move", "Move 2", "Mixer", "Living Room TV", "airport-mixer",
"sonos-move-2" — 7 devices — not real hardware).

## Method + environment

- **Machine**: Apple M1, macOS 14.4.1 (arm64). Checked quiet before each
  timed run (`top -l 1`: no other user process above low single-digit % CPU
  at the moment of each sample; one unrelated worktree's `swift build
  --build-tests` briefly ran during setup and was clear before real
  measurements started).
- **Build**: release throughout. `scripts/make-app.sh build` (wraps `swift
  build -c release --product AudiouterApp`, ad-hoc codesigned, hardened
  runtime) for the app-launch and bundle-size numbers. `swift build -c
  release --product popover-harness` (same package, same optimization level)
  for the popover-rebuild numbers, since `AudiouterPopoverUI` isn't an
  exported library product and can't be reached from an out-of-package
  script (see below).
- **Launch time**: a Python wrapper (`scratchpad/perf/launch_time.py`) forks
  `build/Audiouter.app/Contents/MacOS/AudiouterApp` directly (env
  `AIRPLAY_BACKEND` explicitly unset so `makeBackend()` resolves
  `MockBackend`), records `time.monotonic()` at fork, and stamps every stderr
  line as it arrives. The app's own `AppDelegate.log("Audiouter launched
  (backend: \(type(of: backend)))")` (`AppDelegate.swift:329`) fires at the
  END of `applicationDidFinishLaunching`, but `StatusItemController()`
  (`AppDelegate.swift:194`) — the menu-bar icon — is the FIRST thing that
  function does; everything between the two is synchronous main-thread work
  (model wiring, notification registration), no I/O wait beyond tiny local
  JSON reads. So this line is a close, slightly-conservative upper bound for
  "menu-bar icon ready." The process is `terminate()`d immediately after each
  sample. This is a direct-exec measurement — it does NOT include
  LaunchServices/Gatekeeper/translocation overhead a real Finder
  double-click would add on a fresh download; that's a different, unmeasured
  number (`[confirm-in-G1]`).
- **Popover content-rebuild cost**: rather than write a new repo file (the
  task's only permitted repo write is this findings doc), the ALREADY
  EXISTING `popover-harness` executable (`Sources/popover-harness/main.swift`)
  was built in release and run through the same per-line stderr/stdout
  timestamp wrapper (`scratchpad/perf/line_timestamps.py`). The harness's own
  checkpoint `print()`s bracket two clean `popover.test_simulateOpen()` calls
  — the SAME `rebuildForOpen()` → `rebuild()` path `toggle()` uses on a real
  click (`PopoverController.swift:512`, `:558`, `:567`) — with nothing else
  expensive between the prints. This measures the view-tree
  teardown/rebuild cost in isolation; it does NOT include the native
  `NSPopover` show animation (`popover.animates = true`,
  `PopoverController.swift:363`), which is a fixed, OS-controlled fade this
  app doesn't (and shouldn't) turn off, and which can't be timed headlessly.
- **Idle/active CPU**: `top -pid <pid> -l N -s 1 -stats pid,cpu,mem,threads`
  sampling once per second.
  - State (a) popover-closed idle: sampled the real, fully-launched
    `AudiouterApp` process (mock backend) for 60 consecutive samples.
  - State (b) "metering active": could NOT click the real popover open —
    `osascript`/System Events has no Automation permission in this shell
    (`-1743 Not authorised to send Apple events to System Events`), and
    granting that is a system-settings change this audit does not have
    standing to make unilaterally. Instead, a second scratch SwiftPM package
    (`scratchpad/perf/core-timing`, depending on the repo's real, exported
    `AudiouterCore` library product via a read-only `.package(path:)` —
    no repo file modified) drives `MockBackend.setMeteringActive(true)`
    directly — the exact `MeteringControlling` call
    `PopoverController`/`AppDelegate` fire on `popoverDidShow`
    (`AppDelegate.swift:238-240`). This measures the Core-side event-emission
    cost (the backend's 10 Hz level timer + dictionary bookkeeping + stream
    yield) in isolation, NOT the AppKit-side repaint
    (`DeviceRowView.setLevel` → `LevelMeterView`'s `CVDisplayLink`
    ballistics) — see the hot-path section for why that split is
    reasoned about separately. Three 45s phases (idle → metering-on →
    metering-off) ran back-to-back in the SAME process, `top -pid`'d
    throughout, so state (c) "CPU returns to baseline" is answered by the
    phase-3 numbers.
- **Memory**: `footprint <pid>` (private/dirty footprint, excludes
  shared/dyld-cache pages) and `ps -o rss` (resident set, includes shared
  pages) on the same live mock-backend process, at launch and again after
  6 minutes idle. Repeated popover/Groups/Settings open-close footprint deltas
  could NOT be live-measured for the same Automation-permission reason above
  — backed instead by a static read of the relevant retain/reuse code
  (see findings).
- **Bundle size**: `du -sh` + `otool -L` + `find -iname '*.dylib'` on two
  builds: `scripts/make-app.sh build` (default — dylibs NOT bundled) and
  `AUDIOUTER_BUNDLE_DYLIBS=1 scripts/make-app.sh build-dylibs` (bundles every
  Homebrew dylib the binary transitively needs, for a Homebrew-less target
  Mac). The `build-dylibs/` output was deleted after measuring (not a repo
  file; not needed after the numbers were recorded).
- Every scratch script/package lives under `scratchpad/perf/`, never in the
  repo. The only repo write this audit makes is this file.

## Measurements

| Metric | Value | Method |
|---|---|---|
| Cold launch (first launch after build) | 424.7 ms | `launch_time.py`, n=1 (a true disk-cold run — dropped page cache — needs `sudo purge`, not attempted; this is "first launch since the binary was linked") |
| Warm launch (repeat launches, same session) | 159.3–161.1 ms (avg ≈ 160.0 ms) | `launch_time.py`, n=5 consecutive |
| Popover full content rebuild (`rebuildForOpen`→`rebuild`, 7 devices + 1 app route) | 3–8 ms (n=6 samples, 3 harness runs) | isolated `test_simulateOpen()` deltas, release `popover-harness` |
| Popover show — native `NSPopover` fade | not measured (OS-controlled, headless-invisible) | `[confirm-in-G1]` |
| Idle CPU, popover closed | 0.0% avg, 0.0% max (60/60 samples over 60 s) | `top -pid`, real app, mock backend |
| CPU, metering active (Core-side only, 10 Hz × 7 devices) | 0.0% avg, 0.0% max (45 s) | `top -pid`, `core-timing` scratch harness |
| CPU, metering off again (same process) | 0.0% avg, 0.0% max (45 s) | same run, phase 3 — confirms return to baseline, no timer leak |
| CPU, popover actually open (AppKit repaint + `CVDisplayLink`s) | not measured | `[confirm-in-G1]` — no Automation permission available to click the real popover |
| Memory footprint at launch (private/dirty) | 17 MB | `footprint <pid>` |
| Memory footprint after 6 min idle (same process, no interaction) | 17 MB (unchanged) | `footprint <pid>` |
| RSS at launch (includes shared pages) | ~40–42 MB | `ps -o rss` |
| Memory after repeated popover/Groups/Settings open-close | not measured | `[confirm-in-G1]` — same permission gap; static code review below |
| App bundle, default build (dylibs NOT bundled — dev-only, will not launch on a clean Mac) | 6.8 MB (binary 4.06 MB + icon 2.91 MB), 0 bundled dylibs | `du -sh`, `scripts/make-app.sh build` |
| App bundle, dylibs bundled (the actual customer-facing artifact per `AGENTS.md`'s "Homebrew-less target Mac") | ~38–40 MB, 19 bundled dylibs | `du -sh`, `AUDIOUTER_BUNDLE_DYLIBS=1 scripts/make-app.sh` |
| …of which pure video-codec dylibs (never invoked — audio-only app) | ~23.7 MB (≈60% of the bundled artifact) | `libavcodec` (9.8 MB), `libx265` (7.2 MB), `libSvtAv1Enc` (2.8 MB), `libvpx` (1.7 MB), `libx264` (1.3 MB), `libdav1d` (0.8 MB) |

## Findings

### Major

**M1. ~60% of the real shipping download is video-codec code an audio-only app never calls.**
- Plain-language: the actual file a customer downloads (once dylibs are
  bundled for a Mac without Homebrew — see `commercial-wrapper.md` §7 for
  whether that step is even wired into the release process) is about
  38–40 MB. Roughly 24 MB of that — three-fifths of the download — is H.264,
  H.265, AV1, and VP9 video encoder/decoder code that Audiouter never uses.
  It streams audio only, and specifically only one audio codec (Apple
  Lossless).
- Evidence: `AirPlayEngine/Sources/CAirPlayEngine/shims/transcode.c:130`
  calls `avcodec_find_encoder(AV_CODEC_ID_ALAC)` — the only codec ID
  referenced anywhere in the vendored shim. But the Homebrew `ffmpeg`
  formula this links against (`AirPlayEngine`'s `libavcodec`) is built with
  every codec enabled, so `libavcodec.62.28.102.dylib` itself dynamically
  depends on `libx264`, `libx265`, `libvpx`, `libdav1d`, and
  `libSvtAv1Enc` (`otool -L` on the bundled dylib), and
  `scripts/make-app.sh`'s dylib-bundling step (`AUDIOUTER_BUNDLE_DYLIBS=1`)
  walks that whole dependency graph and ships all of it.
- Suggested fix direction: either link a minimal, audio-codecs-only ffmpeg
  build (`--disable-everything --enable-encoder=alac` and friends) as the
  vendored dependency, or replace the ffmpeg dependency with a small
  standalone ALAC encoder — either removes ~24 MB with zero functional
  change. Worth doing before the first paid release, since download size is
  one of the few things a prospective buyer sees before paying anything.

### Minor

**N1. Every popover open tears down and rebuilds every row from scratch — fine today, an O(n) cost that will show up with a much larger fleet.**
- Plain-language: clicking the menu-bar icon doesn't reuse last time's rows
  — it deletes all of them and builds brand-new ones every single time,
  even if nothing changed. Measured cost today is tiny (a few
  milliseconds for 7 devices + 1 routed app), so this is not a real problem
  right now — flagging it because it's a rebuild-not-diff pattern that
  scales linearly with fleet size, and a power user with a large home (15+
  AirPlay speakers across several rooms) would be the first to notice it
  creep.
- Evidence: `PopoverController.swift:512` (`toggle`) calls
  `rebuildForOpen()` (`:558`) unconditionally on every show, which calls
  `rebuild()` (`:567`): `deviceRowsByID.removeAll()`, `panel.clearRows()`,
  then `makeDeviceRow` (`:774`) constructs a fresh `DeviceRowView` (and a
  fresh `LevelMeterView` inside it, each carrying its own `CALayer`s) for
  every device, every time.
- Suggested fix direction: no action needed at today's realistic fleet
  sizes; if profiling ever shows this mattering, diff-and-reuse existing row
  views by device id instead of tearing the whole card down.

**N2. Each visible VU meter runs its own independent `CVDisplayLink` instead of sharing one.**
- Plain-language: every speaker/app row showing a live volume bar has its
  own private clock ticking at the screen's refresh rate (60 or 120 times a
  second) to animate that one bar. With several bars visible at once (a
  home with many speakers, all playing), that's several independent clocks
  doing nearly identical work instead of one clock updating all of them.
  The design already does the two things that matter most (each clock
  fully stops itself when its bar goes idle — zero cost at rest — and each
  frame update avoids triggering an animation/layout pass), so this is a
  minor efficiency note, not a real slowdown at typical fleet sizes.
- Evidence: `AudiouterSharedUI/LevelMeterView.swift:58` (`private var
  displayLink: CVDisplayLink?`, one per instance), `:172-188`
  (`startDisplayLinkIfNeeded`) — the file's own doc comment already names
  the tradeoff: "every popover row gets one of these, so an always-running
  per-row display link would be a real cost with several devices visible."
- Suggested fix direction: a single shared `CVDisplayLink` (or one
  `CADisplayLink`-style ticker) driving every currently-animating meter
  would collapse N callbacks/frame into 1; not urgent given the self-stopping
  design already in place. `[confirm-in-G1]` for the actual measured delta
  with 5+ simultaneously-playing rows — this audit could not visually drive
  the real popover to check.

**N3. Whole-system RMS recompute runs at the raw ~86 Hz capture-buffer rate, not the coalesced 25 Hz emit rate.**
- Plain-language: the code that decides "how loud is each speaker right
  now" reruns on every raw audio buffer (dozens of times a second) even
  though the result is only ever sent to the screen at a smoothed, slower
  rate. The work itself is cheap (a small loop over connected devices and
  routed apps, off the real-time audio thread), so this is not a measured
  problem at realistic device/app counts — noted for completeness since the
  code's own doc comments explicitly call out the 25 Hz coalescing as the
  perf-relevant number, which slightly overstates how much work the
  coalescer actually saves.
- Evidence: `NativeBackend.swift:2868` (`levelEmitIntervalNanos`, ~25 Hz
  documented), `:2941-2950` (`emitLevel`, called from every raw capture
  callback) loops `self.order` and calls `emitCombinedLevel` (`:2982-2994`)
  for every selected+unmuted device, which itself loops `lastRoutes` — this
  full recompute happens BEFORE the `scheduleLevelEmit` coalescer
  (`:3001-3014`) decides whether to actually emit.
- Suggested fix direction: none needed today (this is a live-audio path this
  audit deliberately did not exercise — mock backend only); worth a second
  look only if a future fleet-size increase or profiling run shows it
  costing real time.

### Nit

**T1. Direct-binary launch time doesn't capture the real first-run experience.**
- Plain-language: the "warm launch ≈ 160 ms" number above is honest but
  optimistic — it skips the extra checks macOS runs the first time you open
  an app downloaded from the internet (Gatekeeper, "app translocation," etc.),
  which a real customer's first double-click will pay once.
- Evidence: method note above; not something this audit could measure
  without a notarized, downloaded artifact.
- Suggested fix direction: no code change; re-measure with a real
  downloaded-and-quarantined `.app` once Developer ID signing lands
  (`commercial-wrapper.md` §7). `[confirm-in-G1]`.

## Also checked — no finding (worth recording so it isn't re-audited)

- **Discovery is event-driven, not polled.** `NativeDiscovery.swift:679`
  (`NWBrowser`) reacts to `stateUpdateHandler`/`browseResultsChangedHandler`;
  the only scheduled work is a capped exponential backoff *retry* after a
  browser failure (`:720-735`), not a steady-state poll loop.
- **The metering gate is wired correctly.** `AppDelegate.swift:238-240`
  forwards `popoverDidShow`/`popoverDidClose` to
  `(backend as? MeteringControlling)?.setMeteringActive(_:)`; confirmed live
  (Core-only harness) that `MockBackend`'s level timer produces zero
  measurable CPU whether on or off, and that turning it off again returns to
  the same 0.0% baseline (no timer leak).
- **Slider drag never blocks on a synchronous backend call.**
  `NativeBackend.swift:931-957` (`setVolume`) dispatches the engine write via
  `stateQueue.async` and returns immediately with an optimistic local model
  update; the one synchronous call on the local-device path
  (`systemVolume.setVolume`, a Core Audio property write) runs off
  `stateQueue`, never blocking the row-model update queue.
- **Settings and Groups/Mixer windows are singletons, not rebuilt per
  open.** `AppDelegate.swift:373-381` / `:464-479` reuse the cached
  `mixerWindowController`/`settingsWindowController` if one exists;
  `MixerWindowController.showWindow()` (`MixerWindowController.swift:204-210`)
  just calls `refreshAll()` and re-fronts the existing window. Unlike the
  popover (N1), repeatedly opening/closing these does not accumulate new
  controller/view trees — a live open/close leak check is still
  `[confirm-in-G1]`, but there's no rebuild-from-scratch pattern here to
  cause one.
- **No evident retain cycle in the popover's rebuild path.**
  `PopoverPanelViewController.clearRows()` (`:230-243`) does a real
  `removeArrangedSubview` + `removeFromSuperview` on every card (not just an
  array clear), and both `DeviceRowView.delegate`
  (`AudiouterSharedUI/DeviceRowView.swift:96`) and `AppRowView.delegate`
  (`AudiouterSharedUI/AppRowView.swift:136`) are `weak`.

## Top 5 by user impact

1. **M1** — ~24 MB of unused video-codec code inflates the real download by
   roughly 60%; the single biggest lever on "does this feel like a bloated
   download" for a paying customer.
2. **N2** — one `CVDisplayLink` per visible meter row instead of one shared
   clock; self-stopping and cheap today, worth confirming at a large,
   all-playing fleet (`[confirm-in-G1]`).
3. **N1** — popover rebuilds every row from scratch on every open; invisible
   today (3–8 ms), a future scaling risk for power users with large fleets.
4. **T1 / open-popover CPU / open-close memory** — three related
   `[confirm-in-G1]` gaps, all caused by the same blocker (no Automation
   permission to drive the real UI non-interactively): real first-launch
   time via a downloaded/quarantined build, real CPU while the popover is
   actually visible and animating, and real memory deltas across repeated
   open/close cycles. None showed a problem in the code-level review or the
   closest available proxy measurement — recommend a short live pass once
   signed builds exist.
5. **N3** — whole-system level recompute runs at raw ~86 Hz instead of the
   documented 25 Hz; cheap today, purely a code-cleanliness note about what
   the coalescer actually coalesces.

Everything else measured clean: warm launch ≈160 ms, idle CPU 0.0% (including
6 minutes with zero interaction), memory footprint flat at 17 MB with no
drift, and the popover's own content-rebuild cost is a few milliseconds even
though item N1 flags its scaling shape.
