# Playback-level meter — research & design

> **2026-07 update:** the meter feature described here has SHIPPED (leading
> `LevelMeterView` column, `PopoverColumnGrid.meterWidth`/`meterToLeading`,
> `DeviceRowView.showsMeter`, `PopoverController.updateLevel`). §6 "Phase B —
> real level signal" below is OBSOLETE: it assumed an OwnTone/audiocap fan-out
> that Phase 1/2 built against, but the shipped path is the native backend's
> own tap — see the note inline in that section.

**Feature:** add a new **leading (first) column** to every popover row: a thin
**vertical bar meter** that fills green from the bottom up, its height driven by
the **current live audio level** for that device/output, animating as audio
plays.

**Status:** research + design only. Read-only pass over the Phase-1 UI + core.
Effort estimates and a phased sequence are at the end.

---

## 0. TL;DR verdict

- **The backend already models this.** `BackendEvent.level(id:rms:)` exists
  (`OutputBackend.swift:21`) and `MockBackend` already emits it on a 10 Hz timer
  (`MockBackend.swift:138–156`). We do **not** need to invent a data channel —
  we need to (a) stop dropping the event at the app boundary and (b) build the
  meter view.
- **Per-device metering is a UI fiction, not a physical reality.** The real
  pipeline is a **single whole-system tap → one FIFO → OwnTone → fan-out** to
  every selected AirPlay device. All grouped devices necessarily share **one
  source level**. We can still show a meter *per row*, but in Phase 1 every
  selected/unmuted row will show the **same** program level (gated per-row by
  `isPlaying` = available ∧ selected ∧ ¬muted). The mock already does exactly
  this. This is honest and matches the plan's Q8(a) recommendation.
- **The feature was explicitly deferred in Phase 1** ("Q8 Meters: SKIPPED in
  Phase 1 entirely" — `PLAN-PHASE-1.md:585`), and the app currently **discards**
  `.level` events on purpose (`AppDelegate.swift:191–193`). Re-introducing the
  meter is a deliberate reversal of that decision, so it should be scoped as its
  own task, not folded into the in-flight column overhaul.
- **Recommended:** Phase A = mock-driven meter to prove the UI end-to-end (all
  the plumbing already exists in the mock); Phase B = a real level signal from
  the capture side (`audiocap` computes peak/RMS already — see §1.3), fanned out
  as one shared value. Do **not** wait on OwnTone for levels — its API/websocket
  carry no instantaneous level (§1.4).

---

## 1. Data availability (the crux)

### 1.1 The event already exists in the protocol

`OutputBackend.swift:9–22`:

```swift
public enum BackendEvent: Sendable, Equatable {
    case deviceAdded(Device)
    case deviceRemoved(id: String)
    case deviceUpdated(Device)
    /// A cheap RMS level sample (0…1) for the per-device level meter
    /// (`NSLevelIndicator`, display-only — SPEC.md §9). Emitted only for
    /// selected, unmuted devices while "playing."
    case level(id: String, rms: Float)   // OutputBackend.swift:21
}
```

So the protocol already carries a **per-id, 0…1 level** on the *same* event
stream the whole UI is driven from (`makeEventStream()`, `OutputBackend.swift:46`).
This is the single load-bearing fact: the meter is a *display of an existing
event*, not new backend surface.

### 1.2 MockBackend already emits it (offline dev is free)

`MockBackend.swift:138–156`:

```swift
private func startLevelTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 0.1, repeating: 0.1)   // 10 Hz
    timer.setEventHandler { [weak self] in self?.emitLevels() }
    timer.resume()
    levelTimer = timer
}

private func emitLevels() {
    tick &+= 1
    for device in live.values where device.isPlaying {           // gated per-device
        let seed  = Double(abs(device.id.hashValue) % 1000) / 1000.0
        let phase = Double(tick) * 0.35 + seed * 6.28
        let base  = Double(device.volume) / 100.0
        let rms   = base * (0.55 + 0.45 * abs(sin(phase)))       // gentle wobble
        emit(.level(id: device.id, rms: Float(min(1, max(0, rms)))))
    }
}
```

- Gated by `isPlaying` (`MockBackend.swift:192–194`): `isAvailable && isSelected
  && !isMuted`. So a meter only animates for rows that are actually "playing" —
  exactly the desired behavior.
- Controlled by the `emitsLevels` init flag (`MockBackend.swift:29, 35, 42, 81`),
  default `true`. Tests turn it off.
- Rate is 10 Hz — a sensible meter cadence. Each sample is already 0…1.

**Consequence:** Phase A needs *zero* backend work. The mock is emitting live,
plausible, per-device wobbling levels right now; they're just being thrown away.

### 1.3 The real signal — where it can come from

Real audio topology (verified):

```
 [whole-system Core Audio process tap]         ← audiocap, ONE stereo mixdown
        │  interleaved Float32 PCM
        ▼
 [audiocap IOProc → ring buffer → PipeWriter]  ← converts F32→S16LE
        │  writes to ONE fifo
        ▼
 [single FIFO: <owntone-lib>/airplay.fifo]     ← FIFOManager.swift
        │  OwnTone reads the pipe track ONCE
        ▼
 [OwnTone] ──fan-out──▶ AirPlay dev A, dev B, dev C …   ← one source, N outputs
```

Citations:
- Tap is **whole system**, single mixdown: `dev/audiocap/README.md:1–3`
  ("captures **all system audio**"), `README.md:37` ("Target (at most one;
  default = whole system)"). The `--pid`/`--exclude` variants still produce **one**
  stream.
- Capture is a **subprocess** the app spawns, not in-process:
  `CaptureProcess.swift:3–4` ("capture runs as a SUBPROCESS — the app spawns the
  `audiocap`-derived helper binary"), `CaptureProcess.swift:99–111`
  (`Process()`, `proc.executableURL = binaryPath`, stdout → `nullDevice`, only
  **stderr** is wired back line-by-line via `readabilityHandler`,
  `CaptureProcess.swift:120`).
- One FIFO, one pipe track, played once and fanned out:
  `CaptureCoordinator.swift` runs a single explicit `clearQueue → addToQueue(uri)
  → play` sequence; `OwnToneBackend.setOutputSet(_:)` does
  `PUT /api/outputs/set {"outputs":[ids]}` — it **replaces the whole selected
  set** (`OwnToneClient.setOutputSet`), it is not per-device streaming.

**Candidate real-level sources, ranked by effort:**

| Source | Where the PCM/level is | Effort | Notes |
|---|---|---|---|
| **`audiocap` peak/RMS** (recommended) | Already computed in-process to the tap. `PipeWriter.swift:30` `private(set) var peakSample: Float`, updated in the F32→S16 convert loop `PipeWriter.swift:101–107` (also `main.swift:139,175–184`). | **Med** | The realtime IOProc/writer already walks every sample. Add a periodic (10–20 Hz) RMS/peak emit to a **side channel** back to the app. Honest program level, cheap. |
| Add a level line to audiocap **stderr** | stderr is *already* wired back to the app (`CaptureProcess`/`AudiocapProcess` parse it line-by-line, e.g. rate parsing `CaptureCoordinator.swift:295–308`). | **Low–Med** | Cheapest IPC: emit e.g. `level 0.42` lines at 10–20 Hz on stderr; `CaptureCoordinator` parses them and calls back into `OwnToneBackend` to `emit(.level(...))`. No new socket. Downside: stderr is a text log channel; keep the rate modest. |
| Dedicated IPC (unix socket / mmap) audiocap→app | New channel | High | Overkill for a display-only 0…1 value at 10–20 Hz; only worth it if we later want higher rate / lower latency. |
| **OwnTone websocket / REST** | — | **N/A — no signal** | Websocket frames carry **names only, no payload** (`OwnToneWebSocketMonitor.swift` subscribe types `["player","outputs","volume","queue","update"]`; a frame just means "re-GET"). REST exposes **per-output volume (a setting)** and **player master volume/state** (`OwnToneClient.PlayerState { state, volume }`) — never an instantaneous audio level. Do not attempt to mine levels from OwnTone. |

**`OwnToneBackend` currently emits no `.level` at all** — grep confirms no
`.level(` / `case level` in `OwnToneBackend.swift`; only the mock emits. So the
real path is a green-field addition: parse a periodic level out of the capture
side and `OwnToneBackend.emit(.level(id:rms:))` for each currently-selected,
unmuted output (same value each — see §1.4).

### 1.4 Per-device vs shared-source — the honest answer

**Physically, it is one shared source level.** There is exactly one tap, one
FIFO, one pipe track. OwnTone fans that single stream to every selected output.
No per-device output level exists anywhere in the stack (OwnTone doesn't report
it; the hardware receivers don't report it back). Therefore:

- A meter *per row* is fine as a **UI affordance**, but in Phase 1 (and until a
  native per-device sender exists in Phase 2) **every selected/unmuted device in
  a group shows the identical program level**. The mock already does this
  (per-id emit of the same underlying program-ish wobble).
- The right Phase-1 real implementation: capture computes ONE program level;
  `OwnToneBackend` fans it out as `.level(id:, rms:)` for each id in the current
  output set that is unmuted (mirroring `isPlaying`). Muted/deselected rows get
  no samples → meter decays to zero.
- This matches `PLAN-PHASE-1.md:169–179` Q8(a): "a single shared program-level
  meter; per-device metering waits for the native sender."

**Verdict: build a per-row meter view; drive it from a shared source level in
Phase 1; treat true per-device levels as a Phase-2 upgrade behind the same
`BackendEvent.level` API (no UI change needed later).**

---

## 2. Level → UI data flow

### 2.1 What's there today, and the one deliberate gap

The event stream is consumed in `AppDelegate.apply(_:)` (`AppDelegate.swift:182–206`).
Today `.level` is explicitly dropped:

```swift
case .level:
    // Meters are SKIPPED in Phase 1 (RESOLVED Q8) — ignore for now.
    return                                   // AppDelegate.swift:191–193
```

Everything else (`deviceAdded/Updated/Removed`) folds into `devicesByID` and
calls `popoverController.update(devices:)` (`AppDelegate.swift:202`). Crucially,
`PopoverController` has **no** level entry point today — `update(devices:)` is
the only push channel (`PopoverController.swift:95`).

### 2.2 Proposed plumbing

Add a thin, dedicated level path parallel to the device-snapshot path. Keep it
**out of** `devicesByID`/`Device` (levels are transient telemetry, not model
state — folding them into `Device` would spam `deviceUpdated` and thrash the
whole rebuild path).

1. **AppDelegate** — handle `.level` instead of dropping it:
   ```swift
   case .level(let id, let rms):
       popoverController.updateLevel(rms, for: id)   // NEW
       return
   ```
   Note it deliberately does **not** call `ensureDefaultSelection()` /
   `update(devices:)` (those run only on real model events). A level sample is a
   cheap, no-allocation forward.

2. **PopoverController** — new `updateLevel(_:for:)`:
   ```swift
   public func updateLevel(_ rms: Float, for id: String) {
       guard popover.isShown else { return }          // ← the CPU/battery gate
       deviceRowsByID[id]?.setLevel(rms)
       for rows in memberRowsByGroup.values {
           for row in rows where row.device.id == id { row.setLevel(rms) }
       }
       // MainOutRowView / GroupRowView meters, if built: drive from an
       // aggregate (max over members) — see §4.4.
   }
   ```

3. **DeviceRowView** — `setLevel(_:)` forwards to the embedded meter view
   (`LevelMeterView.setLevel`, §3). The meter owns its own smoothing + redraw;
   the row does nothing else.

### 2.3 Update cadence

- Backend emits at **10 Hz** (mock) — visually fine; a real capture emit at
  **10–20 Hz** is plenty for a display-only meter. Do **not** push toward 60 Hz;
  the meter's own decay animation (a `CADisplayLink`/`CVDisplayLink` or a
  `CAAnimation`, §3) interpolates between samples so the bar looks smooth even at
  10 Hz input.
- Each `.level` is O(1): dictionary lookup + set a float + `needsDisplay` on one
  tiny layer. No layout, no rebuild.

### 2.4 Stopping metering when the popover is closed (the battery story)

Three independent gates, cheapest first:

1. **UI gate (mandatory):** `PopoverController.updateLevel` early-returns when
   `!popover.isShown` (as above). The popover is `.transient` and closed the vast
   majority of the time, so this alone makes the meter path inert whenever the
   user isn't looking. This mirrors the existing pattern — `update(devices:)`
   already branches on `popover.isShown` (`PopoverController.swift:98`).
2. **Emit gate (recommended for the real backend):** the *real* capture level
   emit should itself be suppressible. Since capture only runs when NOT in
   passthrough, and the meter is only visible when the popover is open, the real
   backend can gate its level emit on "popover open" via a lightweight
   `backend.setMeteringActive(_:)` toggled by `PopoverController` in
   `popoverDidShow`/`popoverDidClose` (NSPopoverDelegate). The mock can honor the
   same toggle (start/stop its `levelTimer`). This stops the *work*, not just the
   *display*. Optional in Phase A (the mock timer is trivial), important in
   Phase B (don't run an audiocap-side RMS loop for nobody).
3. **Meter self-gate:** each `LevelMeterView` stops its own decay
   `CVDisplayLink`/animation once it has decayed to 0 and no new sample has
   arrived (idle → no frames). It restarts on the next `setLevel(>0)`.

Wire the `popoverDidShow`/`popoverDidClose` hooks in `PopoverController` (it's
already the `NSPopoverDelegate`, `PopoverController.swift:73`) to (a) start/stop
metering and (b) zero every meter on close so a stale bar can't linger on reopen.

---

## 3. AppKit meter view

### 3.1 Design

A small **layer-backed `NSView`** — `LevelMeterView` — living in
`AudioutedSharedUI` (same target as `DeviceRowView`/`ControlCenterSlider`
so both popover and mixer window can reuse it). It draws a **vertical rounded
track** with a **green fill** growing from the bottom.

Rendering approach — **two `CALayer`s, no per-frame Auto Layout, no per-frame
`draw(_:)`**:

- A background **track layer** (rounded rect, faint recess — matches the
  `ControlCenterSlider` recess vocabulary), sized once in `layout()`.
- A **fill layer** clipped to the track's rounded shape, whose **height is
  animated** by setting its `bounds`/`position` (or a `CAGradientLayer` mask).
  Green→yellow→red is a static vertical gradient revealed by the fill height, so
  color-at-peak is free.

Why layers, not `NSLevelIndicator`: the SPEC originally name-checked
`NSLevelIndicator .discreteCapacity` (`SPEC.md:485`) but that's a **horizontal,
segmented, chunky control** — wrong shape for a thin vertical VU bar and awkward
to color-ramp smoothly. A 2-layer custom view is smaller, animates on the
compositor, and matches the CC slider's hand-drawn look already in the codebase.

### 3.2 Ballistics (so it reads like a meter, not a strobe)

Real meters have **fast attack, slow decay**. Smooth in the *view*, off the
raw sample:

```
displayed += (target - displayed) * (target > displayed ? attack : decay)
// attack ≈ 0.5 (snappy rise), decay ≈ 0.12 (gentle fall), per display frame
```

Drive `displayed` from a `CVDisplayLink` (or a repeating `CAAnimation` on the
fill height); each incoming `setLevel(target)` just updates `target`. This
decouples the 10 Hz input from the 60 Hz visual and gives the characteristic
meter fall. Optionally hold a **peak cap** (a thin marker that snaps up and
falls slowly) — nice-to-have, skip in Phase A.

### 3.3 Color

Static vertical gradient behind the fill mask:

- 0–70% → green (`systemGreen`)
- 70–90% → yellow
- 90–100% → red

Because the gradient is fixed and only the *fill height* changes, the tip color
tracks the level automatically. Keep it single-green in Phase A if simpler;
add the ramp in polish.

### 3.4 Size

- Fits `DeviceRowView.rowHeight = 38` (`DeviceRowView.swift:63`) and
  `GroupRowView.rowHeight = 38`. Give the bar a fixed **column width ~6–8pt** and
  a **height ~20–22pt**, centered vertically. It's a *thin* bar — see the layout
  column constant in §4.
- Non-interactive: `hitTest` returns `nil` (like `CardRimView`,
  `CardView.swift:157`) so it never eats clicks meant for the row.

### 3.5 Code sketch

```swift
// AudioutedSharedUI/LevelMeterView.swift
import AppKit
import QuartzCore

/// A thin vertical VU/peak meter: a rounded track with a green→yellow→red fill
/// growing from the bottom. Display-only, layer-backed, fed 0…1 samples via
/// `setLevel`. Ballistics (fast attack / slow decay) live here so a 10 Hz input
/// still animates smoothly. Non-interactive (never eats row clicks).
public final class LevelMeterView: NSView {

    public static let columnWidth: CGFloat = 8      // the new grid column (§4)
    private let barWidth: CGFloat = 4
    private let barHeight: CGFloat = 22

    private let track = CALayer()
    private let gradient = CAGradientLayer()         // green→yellow→red, static
    private let fillMask = CALayer()                 // masks gradient to fill height

    private var target: CGFloat = 0                  // latest sample (0…1)
    private var displayed: CGFloat = 0               // smoothed value driving the bar
    private var link: CVDisplayLink?

    public override var isFlipped: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        track.cornerRadius = barWidth / 2
        track.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.25).cgColor
        layer?.addSublayer(track)

        gradient.colors = [NSColor.systemGreen, NSColor.systemGreen,
                           NSColor.systemYellow, NSColor.systemRed].map(\.cgColor)
        gradient.locations = [0.0, 0.6, 0.85, 1.0]  // green mostly, hot near top
        gradient.startPoint = CGPoint(x: 0.5, y: 0)  // bottom
        gradient.endPoint   = CGPoint(x: 0.5, y: 1)  // top
        gradient.cornerRadius = barWidth / 2
        gradient.mask = fillMask
        layer?.addSublayer(gradient)
    }
    public required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: Self.columnWidth, height: barHeight)
    }

    public override func layout() {
        super.layout()
        let x = (bounds.width - barWidth) / 2
        let y = (bounds.height - barHeight) / 2
        let barRect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
        // No implicit animations on geometry set in layout.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = barRect
        gradient.frame = barRect
        applyFillHeight()
        CATransaction.commit()
    }

    /// Feed a new level sample (0…1). Starts the decay link if idle.
    public func setLevel(_ rms: Float) {
        target = CGFloat(min(1, max(0, rms)))
        startLinkIfNeeded()
    }

    /// Force the meter to empty (popover closed / row deselected).
    public func reset() {
        target = 0; displayed = 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        applyFillHeight(); CATransaction.commit()
        stopLink()
    }

    private func applyFillHeight() {
        let h = gradient.bounds.height * displayed
        fillMask.frame = CGRect(x: 0, y: 0, width: gradient.bounds.width, height: h)
        fillMask.backgroundColor = NSColor.black.cgColor   // opaque = revealed
    }

    // MARK: ballistics (fast attack, slow decay) driven off a display link
    private func tick() {
        let k: CGFloat = target > displayed ? 0.5 : 0.12
        displayed += (target - displayed) * k
        CATransaction.begin(); CATransaction.setDisableActions(true)
        applyFillHeight(); CATransaction.commit()
        if displayed < 0.001 && target == 0 { stopLink() }   // idle → stop frames
    }
    private func startLinkIfNeeded() { /* create + start CVDisplayLink → tick() on main */ }
    private func stopLink() { /* stop + release link */ }
    deinit { stopLink() }
}
```

(The `CVDisplayLink` create/start/stop is boilerplate; the important bits are:
callback hops to the main actor, calls `tick()`, and the link **stops itself**
when idle so a closed/empty meter burns nothing.)

---

## 4. Layout integration

### 4.1 The current grid, and why the new column is the easy part

`PopoverColumnGrid` (`PopoverColumnGrid.swift`) anchors every right-hand column
(slider, `%` readout, trailing control) off the **trailing** edge, so the columns
line up across `MainOutRowView`, `DeviceRowView`, `GroupRowView` regardless of
what *leads* the row. The **leading** side is per-row-type:

- `DeviceRowView`: icon at `leadingInset` (14) / `indentedLeadingInset` (30 for
  members) (`DeviceRowView.swift:223–224, 270`).
- `MainOutRowView`: icon at `leadingInset` (`MainOutRowView.swift:217`).
- `GroupRowView`: activate button at `leadingInset - 4`
  (`GroupRowView.swift:173–174`).

Because the meter is a **new leading column to the LEFT of the existing first
element**, it does **not** touch any trailing anchor — the whole right-hand grid
is untouched. We only shift each row's existing leading element rightward by one
fixed column.

### 4.2 New grid constants

Add to `PopoverColumnGrid`:

```swift
/// The leading playback-level meter column (a thin vertical VU bar to the LEFT
/// of every row's first existing element). Fixed width so all row types align.
public static let meterWidth: CGFloat = LevelMeterView.columnWidth   // ~8
/// Gap between the meter column and the row's first existing element.
public static let meterToLeading: CGFloat = 8
```

Then the effective leading inset for the existing first element becomes
`leadingInset + meterWidth + meterToLeading` (and likewise for the indented and
group variants). Cleanest: introduce a helper so the three row types stay in
sync:

```swift
public static func firstElementLeading(indented: Bool) -> CGFloat {
    (indented ? indentedLeadingInset : leadingInset) + meterWidth + meterToLeading
}
```

The meter itself sits at `leadingInset` (top-level) or a smaller inset for
members, centered vertically, `meterWidth` wide.

### 4.3 Per-row wiring

- **DeviceRowView** (`DeviceRowView.swift:218–300`): add a `LevelMeterView`
  subview, constrain it leading = `leadingInset`, then change the icon's leading
  constraint from `constant: leading` to `iconView.leadingAnchor = meter.trailing
  + meterToLeading`. Add a public `setLevel(_:)` that forwards to the meter, and
  reset the meter in `apply(...)` when the row is not `isPlaying` (deselected /
  muted / unavailable) so a stale bar can't stick. This mirrors the existing
  hover-reset discipline in `apply` (`DeviceRowView.swift:170–175`).
- **GroupRowView / MainOutRowView**: add the same meter column so the leading
  edge lines up. Drive the group/Main-Out meter from an **aggregate** (e.g. `max`
  of the member levels) — see §4.4. If we don't want a meter on those rows, we
  still reserve the column (empty) so device rows below stay aligned, exactly how
  the grid already reserves empty slots (`PopoverColumnGrid.swift:52–57`).
- **ColumnHeaderRow** (`ColumnHeaderRow.swift`): the meter column is unlabeled;
  no header label needed. The existing "Volume"/"Enabled" headers are
  trailing-anchored and unaffected.

### 4.4 Group / Main-Out aggregate meter

Since all members share the source level anyway (§1.4), the aggregate is trivial:
the Main-Out and group meters can show the *same* program level as the device
rows (whenever the target has any playing member). `PopoverController.updateLevel`
can forward the sample to `mainOutRow.setLevel` / the active `GroupRowView` too,
or compute `max` over the group's member ids. Either is fine; `max` is the
conventional "master meter" behavior and future-proofs the per-device Phase-2 case.

### 4.5 Interaction with the other in-flight changes

The row files carry TODO-ish references to a **column-header row (task A/B)**, a
trailing **"Enabled" column (task C)**, and **Groups-section** rework. All of
those live on the **trailing** side or are separate rows; the meter is a **new
leading column** and is orthogonal:

- The meter does not move any trailing anchor, so it can't regress the
  slider/`%`/Enabled alignment those tasks care about.
- If the Groups section is removed, the meter simply never mounts on group rows —
  no coupling.
- Sequencing: land the meter **after** the leading-side churn settles (the enable
  switch already moved from leading to trailing per the `DeviceRowView` comments,
  `DeviceRowView.swift:295–298`), so we're not rebasing leading constraints twice.

---

## 5. Performance & correctness risks

1. **Metering while invisible (battery).** Biggest risk. Mitigated by the three
   gates in §2.4 — the `!popover.isShown` early-return is mandatory; the
   emit-side gate is strongly recommended for the real backend so audiocap isn't
   computing RMS for a closed popover.
2. **Per-frame layout thrash.** Avoided by driving the fill via a `CALayer`
   height inside a `CATransaction { setDisableActions(true) }`, never Auto Layout
   per frame (§3). Set constraints once; animate on the compositor.
3. **Idle CPU from a running display link.** The meter must **stop its own
   `CVDisplayLink` when decayed to 0** and restart on the next non-zero sample
   (§3.5). Otherwise N idle meters each spin a 60 Hz link.
4. **Stale bars on reopen / deselect.** A closed popover or a row that stops
   playing must **zero** its meter (`reset()` on `popoverDidClose`, and in
   `DeviceRowView.apply` when `!isPlaying`). The codebase already has this exact
   failure mode with hover (T-U8, `DeviceRowView.swift:82–105`); reuse the
   discipline: transient telemetry is reset on every model refresh.
5. **Threading.** `.level` events arrive on the stream consumer already hopped to
   `@MainActor` (`AppDelegate.swift:177`). The `CVDisplayLink` callback runs on a
   high-priority thread — marshal to main before touching layers.
6. **Honesty of the shared level.** All grouped rows showing the identical bar
   could read as "broken" to a user expecting per-speaker VU. This is a **product
   decision**, not a bug (§1.4). If undesired, prefer omitting per-row meters on
   group members in Phase 1 and showing only a single Main-Out master meter,
   upgrading to real per-device in Phase 2.
7. **Reversing a shipped decision.** Q8 was deliberately SKIPPED
   (`PLAN-PHASE-1.md:585`) and the app drops `.level` on purpose
   (`AppDelegate.swift:191`). Re-enabling should be an explicit, reviewed change
   (and probably a note back into `PLAN`/`SPEC`), not a silent flip.
8. **`Equatable` on `BackendEvent`.** The enum is `Equatable`
   (`OutputBackend.swift:9`); `.level` carries a `Float`, so exact-equality
   dedup of level events is meaningless (fine — we don't dedup them). No change
   needed, just don't rely on `deviceUpdated`-style diffing for levels.

---

## 6. Recommended implementation sequence

### Phase A — mock-driven meter, prove the UI (no backend work)

Everything the mock needs already exists (§1.2). Rough effort: **~½–1 day.**

1. **`LevelMeterView`** in `AudioutedSharedUI` (§3.5) — layer-backed
   vertical bar, `setLevel`/`reset`, self-stopping display link, single-green
   first (add the color ramp later). *(sonnet, med)*
2. **`PopoverColumnGrid`** — add `meterWidth`/`meterToLeading` +
   `firstElementLeading(indented:)`; repoint `DeviceRowView`'s leading icon
   constraint through it. *(low)*
3. **`DeviceRowView`** — mount the meter as the new leading column, add
   `setLevel(_:)`, reset it in `apply(...)` when `!isPlaying`. *(low–med)*
4. **`PopoverController.updateLevel(_:for:)`** — dispatch to rows, early-return
   when `!popover.isShown`; zero all meters in `popoverDidClose`. *(low)*
5. **`AppDelegate`** — replace the `.level` drop (`AppDelegate.swift:191–193`)
   with `popoverController.updateLevel(...)`. *(trivial)*
6. Optional: `MainOutRowView`/`GroupRowView` meter column (aggregate) for visual
   completeness, or reserve an empty column. *(med)*
7. Snapshot/harness coverage — the `popover-snapshot` tool already renders the
   panel offscreen; add a meter-visible variant. Structural test hooks
   (`test_meterLevel(for:)`) like the existing `test_*` accessors. *(low)*

**Exit criteria:** popover open with the mock fleet shows green bars animating
on selected/unmuted rows, decaying on mute/deselect, empty on closed reopen,
CPU idle when closed.

### Phase B — real level signal (behind the same API) — OBSOLETE, see 2026-07 note above

This section's plan (audiocap stderr line → CaptureCoordinator parse →
OwnToneBackend emit) targeted the Phase-1 OwnTone/FIFO pipeline. That pipeline
is no longer the shipping path: the native AirPlay 2 backend computes RMS
directly off its own system-audio tap in `NativeCaptureCoordinator`
(`rmsOfS16LE`, `onLevel` callback) and `NativeBackend.emitLevel` fans `.level`
out per selected+unmuted device — no audiocap stderr parsing or IPC hop
involved. The steps below are kept for historical record only.

Rough effort: **~1–2 days** (mostly the capture-side emit + IPC choice).

1. **audiocap:** emit a periodic (10–20 Hz) RMS/peak. `peakSample` is already
   tracked in the convert loop (`PipeWriter.swift:101–107`); add an RMS
   accumulator and print e.g. `level <0..1>` to **stderr** (cheapest — stderr is
   already parsed) or a small side channel. *(med)*
2. **CaptureCoordinator / AudiocapProcess:** parse the level line (same shape as
   the existing rate parse, `CaptureCoordinator.swift:295–308`) and hand it to
   `OwnToneBackend`. *(low–med)*
3. **OwnToneBackend:** `emit(.level(id:, rms:))` for each id in the current
   output set that is unmuted (the shared-source fan-out, §1.4). Gate emission on
   a `setMeteringActive(_:)` toggle the popover flips on show/close. *(med)*
4. No UI change — Phase A already consumes `.level` identically for mock and
   real.

### Phase 2 — per-device AND per-app levels (shipped 2026-07-17)

The native AirPlay-2 backend now carries **distinct per-device and per-app levels**:

- **Per-device metering**: `BackendEvent.level(id:rms:)` now includes the MAX of the
  whole-system tap RMS (for Selected Devices) and each per-app mixed stream's RMS
  (for redirect targets), attributed via `NativeBackend.streamBindings` /
  `latestStreamRMS`. Drives the leading `LevelMeterView` column on device rows
  and the Main Out row.
- **Per-app metering**: `BackendEvent.appLevel(bundleID:rms:)` carries live RMS for
  routed apps, with distinct sources per route type:
  - `.device`-routed apps: `AppRouteMixer.onAppLevel` emits POST-volume RMS
  - `.currentDevice`-routed apps: `LocalPlaybackEngine.onAppLevel` emits PRE-volume
    (raw capture) RMS
  - `.noRedirect` apps: `PerAppCaptureCoordinator` (metering-only tap, marked
    `.unmuted`) emits RMS
  - All three gated by `setMeteringActive(true/false)` (popover open/close).
  Drives the leading `LevelMeterView` column on Applications rows (`AppRowView`,
  `showsMeter` flag).
- Excluded apps (Settings denylist) are never metered in any path.

The meter view and UI plumbing remain unchanged across all backends — per-device
and per-app levels feed the *same* `BackendEvent` API.

---

## Appendix — key citations

| Fact | Location |
|---|---|
| `.level(id:rms:)` event defined | `OutputBackend.swift:21` |
| Event stream is the only UI channel | `OutputBackend.swift:44–46` |
| Mock emits levels @10 Hz, gated by `isPlaying` | `MockBackend.swift:138–156, 192–194` |
| `emitsLevels` init flag (default true) | `MockBackend.swift:29,35,42,81` |
| App **drops** `.level` on purpose (Q8 skip) | `AppDelegate.swift:191–193` |
| Meters SKIPPED in Phase 1 (decision) | `PLAN-PHASE-1.md:585` |
| Q8(a) shared program-level meter recommendation | `PLAN-PHASE-1.md:166–179` |
| Capture is a subprocess; only stderr wired back | `CaptureProcess.swift:3–4,99–120` |
| audiocap tracks `peakSample` in convert loop | `PipeWriter.swift:30,101–107`; `main.swift:139,175–184` |
| Whole-system single mixdown tap | `dev/audiocap/README.md:1–3,37` |
| OwnTone websocket = names only, no payload | `OwnToneWebSocketMonitor.swift` (subscribe types) |
| OwnTone REST has volume-setting + master state only | `OwnToneClient.PlayerState { state, volume }` |
| `OwnToneBackend` emits no `.level` (stub) | `OwnToneBackend.swift` (no `.level(`) |
| Shared grid: trailing-anchored columns | `PopoverColumnGrid.swift:72–99` |
| DeviceRow leading icon inset | `DeviceRowView.swift:223–224,270` |
| Row heights (38 / 38 / 44) | `DeviceRowView.swift:63`, `GroupRowView.swift:39`, `MainOutRowView.swift:56` |
| `PopoverController.update(devices:)` gated on `popover.isShown` | `PopoverController.swift:95–105` |
| Non-interactive layer view precedent (`hitTest → nil`) | `CardView.swift:157` |
| Layer + `CATransaction`-disabled-actions precedent | `CardView.swift:127–134` |
| SPEC's original `NSLevelIndicator` note | `SPEC.md:485` |
