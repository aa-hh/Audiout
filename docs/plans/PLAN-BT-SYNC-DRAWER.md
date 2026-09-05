# PLAN — Bluetooth SYNC drawer (live scrub tuning)

Status: SPEC LOCKED, not started. Branch: `claude/foreman-roadmap-004-bt`.
Supersedes the inline `− / value / +  ·  metronome` SYNC cluster shipped in the
BT-OFFSET-UI wave. Roadmap item 004.

---

## 1. Why this exists

The Bluetooth SYNC trim is how a user compensates for a speaker's own output
lag. Today the row carries a full control cluster (minus button, editable ms
field, plus button, metronome toggle) that is permanently visible, steps in
whole milliseconds, and — critically — **tears down and restarts that device's
audio engine on every change**, which costs ~500 ms of silence per edit.

That is fine for a once-per-setup value. It is unusable for the interaction the
product actually needs: sitting in front of the speakers with music playing and
nudging until the smear collapses.

This plan replaces it with:

- a **read-only value chip** on the row (the only SYNC control in the row),
- which opens an **in-place drawer** underneath that row containing the big
  readout, − / + steppers, a **fine-adjustment ruler**, an **align-by-ear**
  button, and a **revert** button,
- backed by a **live, glitch-free trim path** that applies while music plays
  with no engine restart,
- at **0.1 ms resolution**.

### Locked product decisions (do not relitigate)

| # | Decision | Rationale |
|---|---|---|
| D1 | Drawer expands **in place**, pushing rows below down. Not a child popover. | Sync is a comparison between speakers — a floating panel covers the rows you are comparing against. Also avoids popover-on-popover. |
| D2 | **At most one drawer open at a time.** Opening one closes any other. | Drawer is ~2× a row's height; several open at once would swamp a menu-bar popover. |
| D3 | The ruler is a **moving tape under a fixed centre pointer**, not a slider with a thumb travelling a track. | Must be visually unmistakable from the VOLUME slider, and must have no endpoints so range and precision can coexist. |
| D4 | Ruler visible window is **±6 ms** around the current value; drag past the edge scrolls the tape (no ends until the usable clamp). | At the drawer's ~380 pt width, ±6 ms gives ~3 pt of travel per 0.1 ms — actually feelable. ±50 ms would give <0.5 pt, making the decimals a lie. |
| D5 | Resolution **0.1 ms**; drag speed sets gearing (slow = 0.1 ms/pt, fast = up to 2 ms/pt). | One control spans setup-scale jumps and hair-splitting. |
| D6 | Trim applies **continuously during the drag**, never on release. | The entire point is judging by ear while dragging. |
| D7 | The readout reads **"22.4 ms later"**, never a bare signed number. | "−22.4" vs "+22.4" is ambiguous and users get the direction backwards. |
| D8 | **Revert** button restores the value the drawer held when it was opened. Disabled when unchanged. | A way home after scrubbing yourself lost. (Upgrade path: once the setup wizard exists it writes a calibrated baseline and Revert targets that instead — see razor note in T1.) |
| D9 | The metronome / align-by-ear toggle **moves off the row into the drawer**. | It is only useful while adjusting. On the row it is a permanent mystery icon for a transient job. |
| D10 | Untuned devices show **"Not set"**, not "0.0 ms". | Zero reads as finished; "Not set" reads as an invitation. This is the discoverability fix. |
| D11 | The ruler and the numeric field **hard-stop at the device's real usable floor**, not at the nominal ±500 ms. | Below the floor the delay math clamps to zero and further movement does nothing — the readout would be lying. |

### Explicitly out of scope

- The setup wizard ("which side is early?" bisection). Separate plan, separate
  branch. This drawer must not assume it exists.
- Any microphone-based auto-alignment. Cut by product decision.
- Changing the align tick sound, its BPM, or its 30 s auto-stop.
- AirPlay rows. They have no SYNC column and must render byte-for-byte
  identically before and after this work.

---

## 2. Current state — read this before touching anything

Package layout note: core audio/model code is `AudioutCore/Sources/AudioutCore/`,
shared row views are `AudioutCore/Sources/AudioutSharedUI/`, the popover is
`AudioutCore/Sources/AudioutPopoverUI/`.

### How the delay is actually realised

`BTDeviceSink` (in `AudioutCore/Sources/AudioutCore/BTSyncedSink.swift`)
does **not** schedule audio at absolute times. It:

1. accepts captured PCM into a lock-free `BTFrameRing` via `enqueue(...)`,
   stamping a one-time anchor: `targetReleaseNanos = capture_pts + totalDelay`;
2. renders **silence** every cycle until the reference clock reaches
   `targetReleaseNanos` (`renderInterleaved` → `SyncTiming.plan`), at which
   point `released = true`;
3. from then on drains the ring continuously through `FractionalResampler` at
   the drift-corrected ratio.

So the delay is physically **the amount of audio piled up in the ring at the
moment the gate opened**. After release, the only way to change the delay is to
move the ring's read position.

`BTFrameRing` is a single-producer/single-consumer ring. `readCounter` is
**consumer-owned** — the render thread may move it freely without racing the
producer. Capacity is `max(2, 8 s × rate)` rounded up to a power of two
(524288 frames at 44.1 kHz ≈ 11.9 s), and the producer drops chunks rather than
overwrite unread data, so the region *behind* the read pointer holds
`capacity − used` frames of intact history — roughly 11.4 s with a 500 ms
delay. Both seek directions therefore have ample room for a ±500 ms trim.

### The current (wrong) trim path

```
DeviceRowView stepper/field
  → DeviceRowViewDelegate.deviceRow(_:didSetSyncTrimMs:for:)      [Int ms]
  → PopoverController.deviceRow(_:didSetSyncTrimMs:for:)          (caches in btTrimsByID)
  → BTOutputControlling.setBTSyncTrim(_:forDevice:)               (NativeBackend ~line 7934)
      · clamps via BTSyncTrim.clamp
      · persists the whole map through BTTrimStore.save
      · hops to captureControlQueue → BTSyncedSink.setTrimMs(_:forDeviceUID:)
  → BTSyncedSink.setTrimMs  (~line 1007)
      · stores into trimMsByUID
      · calls sink.requestRebuild(cause: "trim_change")            ← THE PROBLEM
  → BTDeviceSink.rebuildLocked → stopLocked() + startLocked()
      · clearSessionStateLocked() wipes anchor, ring, resampler, drift state
      · the gate re-arms and the device is SILENT for the whole delay again
```

`delayNanos(forUID:)` composes the final delay:

```
BTReferenceTimeline.delayNanos(
    composition:          .airPlayPresent ? live presentation delay : btOnlyBufferMs (500)
    deviceOffsetMs:       the device's own output lag (subtracted)
    trimMs:               the user's signed nudge (added)
)   → clamped ≥ 0 inside SyncTiming.totalDelayNanos
```

The `≥ 0` clamp is what creates D11's usable floor.

### Where the UI lives

- `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift`
  - `showsSyncControls: Bool` (init param, line ~355) gates the whole cluster.
  - Fields: `syncMinusButton`, `syncPlusButton`, `syncField`, `alignButton`,
    `syncTrimMs`, `alignSymbolName` (~lines 297–311).
  - `configure(...)` applies state (~line 658).
  - `configureSyncControls()` + the `showsSyncControls` constraint block
    (~lines 1432, 1531–1560) build the trailing→leading cluster.
  - Delegate methods at lines ~69–76.
- `AudioutCore/Sources/AudioutSharedUI/PopoverColumnGrid.swift` §"SYNC
  column" (~lines 578–620) holds every SYNC metric as a named constant —
  **all new metrics go here, none inline.**
- `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift`
  - `btTrimProvider` (line ~259), `btTrimsByID` cache (~269), row construction
    passing `showsSyncControls: device.isBluetooth` (~1445), trim resolution
    (~1615–1622), delegate implementations (~2751–2757).
- The popover sizes itself from Auto Layout `fittingSize` → `preferredContentSize`,
  so a drawer added into the row stack resizes the popover automatically. The
  resize-animation primitive is at `PopoverController.swift` ~line 885–910;
  drawer open/close must use the **animated** path.

---

## 3. Task breakdown

Eight tasks. `T1` is the gate — nothing else merges before it. `T4` is fully
independent and can start immediately in parallel.

```
T1 (fractional trim type) ──┬─→ T2 (live seek)      ──┐
                            ├─→ T3 (usable range)   ──┤
                            └─→ T6 (row chip)       ──┼─→ T7 (accordion + wiring) ─→ T8 (docs/Figma)
T4 (ruler view) ─→ T5 (drawer view) ────────────────  ┘
```

House rules apply to every task: work on `claude/foreman-roadmap-004-bt`, never
on `main`; Guard 4 runs the full suite on any Swift commit
(`bash scripts/run-tests.sh`); Guard 7 requires `scripts/self-review.sh` on the
staged diff before commit. Push to `origin/claude/foreman-roadmap-004-bt`.
**Do not merge to `main`** — the owner live-tests first and merges on their own say-so.

---

### T1 — Fractional trim: `Int` → `Double` milliseconds, end to end

**Why:** every other task needs 0.1 ms to exist as a type.

**Files**
- `AudioutCore/Sources/AudioutCore/BTTrimStore.swift`
- `AudioutCore/Sources/AudioutCore/BTSyncedSink.swift`
- `AudioutCore/Sources/AudioutCore/NativeBackend.swift`
- `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift` (delegate signature only)
- `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift` (cache + provider types)
- `AudioutCore/Sources/AudioutApp/AppDelegate.swift` (~line 467, `btTrimProvider` closure)

**Do**

1. `BTSyncTrim`: change `rangeMs`, `coarseStepMs`, `fineStepMs` and `clamp` to
   `Double`. Add:
   ```swift
   /// The scrub's quantum. Every committed trim is a whole multiple of this,
   /// so the readout, the ruler, and the persisted value can never disagree
   /// about what "22.4" means.
   public static let resolutionMs: Double = 0.1
   /// Snap to `resolutionMs` and clamp to ±`rangeMs`.
   public static func quantise(_ ms: Double) -> Double
   ```
   `quantise` must round-half-away-from-zero and must return values free of
   binary-float dust (`(ms / 0.1).rounded() * 0.1` then round to 1 dp).
2. `BTTrimStore.Envelope.trims` becomes `[String: Double]`. **Do not bump
   `schemaVersion`** and do not write a migration: `JSONDecoder` reads a v1
   integer payload (`22`) straight into `Double`, and the feature has never
   shipped, so no user has a file this could break. Add a one-line comment
   saying exactly that so a future reader does not "fix" it.
3. `BTSyncedSink`: `trimMsByUID: [String: Double]`, `setTrimMs(_ ms: Double, …)`.
   `BTReferenceTimeline.delayNanos(… trimMs: Double)`. Check
   `SyncTiming.totalDelayNanos`'s `userOffsetMs` parameter — if it is `Int`,
   widen it to `Double` (it feeds a nanosecond computation, so this is a
   precision *gain*; verify no other caller relies on integer truncation).
4. `NativeBackend`: `btTrimsByUID: [String: Double]`, and the `BTOutputControlling`
   protocol's `setBTSyncTrim(_ ms: Double, forDevice:)` /
   `btSyncTrim(forDevice:) -> Double`. Update the no-op default implementation
   too (~line 8013).
5. Delegate: `deviceRow(_:didSetSyncTrimMs ms: Double, for:)`.
6. razor comment on `BTSyncTrim`, verbatim:
   ```swift
   // razor: Revert targets the drawer's open-time value, not a calibrated
   // baseline — there is no calibration source yet. When the setup wizard
   // lands it should persist a per-device baseline alongside the trim and
   // Revert should prefer it.
   ```

**Do not** change `coarseStepMs` (10) or `fineStepMs` (1) values — only their
type. The steppers keep behaving exactly as they do today.

**Tests** (extend the existing BT trim suites; find them with
`git grep -l BTSyncTrim AudioutCore/Tests`)
- `quantise` snaps 22.44 → 22.4, 22.45 → 22.5, −22.45 → −22.5, and clamps
  ±500.0.
- `quantise` output has no float dust: `quantise(0.1 * 3)` is exactly the same
  `Double` as `quantise(0.3)`.
- `BTTrimStore` round-trips 22.4 exactly.
- `BTTrimStore` loads a hand-written v1 file whose values are JSON integers and
  yields the same `Double`s.

**Acceptance:** full suite green; no behaviour change visible in the app.

---

### T2 — Live trim: ring seek with crossfade, no engine rebuild

**Why:** D6. This is the load-bearing change; everything else is chrome.

**File:** `AudioutCore/Sources/AudioutCore/BTSyncedSink.swift` only.

**Do**

1. Introduce `BTDelayLine`, a consumer-side wrapper owning the existing
   `BTFrameRing` plus the seek/crossfade state, and exposing exactly one
   consumer entry point so `FractionalResampler.render`'s `pullFrame` closure
   is untouched:
   ```swift
   func readFrame(into dst: UnsafeMutablePointer<Float>) -> Bool
   ```
   `BTDeviceSink.ring` becomes a `BTDelayLine`; `enqueue` forwards to
   `delayLine.write(...)`; `renderInterleaved`'s closure becomes
   `self.delayLine.readFrame(into: frame)`. No other call-site changes.
2. Add to `BTFrameRing` (consumer thread only — document that):
   ```swift
   /// Move the read position by `frames` (negative = replay history, positive
   /// = skip ahead). Returns the delta actually applied after clamping to the
   /// available history behind the read pointer and the unread data ahead of
   /// it. Consumer thread ONLY: `readCounter` is consumer-owned, so this needs
   /// no lock and cannot race the producer.
   func seek(byFrames frames: Int) -> Int
   ```
   Backward limit: `capacity − used`. Forward limit: `used` (never pass the
   write pointer).
3. Trim requests reach the delay line as a **pending delta in frames**, written
   from the control queue and consumed by the render thread:
   - `BTDelayLine.requestShift(frames: Int)` — non-blocking; accumulates into a
     pending counter (a single heap word plus `OSMemoryBarrier`, matching the
     ring's existing discipline). Accumulate rather than overwrite so a fast
     scrub cannot drop deltas.
   - On the next `readFrame` call, if a pending delta exists, the delay line
     takes it (zeroing the pending word), calls `ring.seek(byFrames:)`, and
     begins a crossfade.
4. **Crossfade.** A raw seek clicks. Before moving the read pointer, copy the
   next `crossfadeFrames` frames from the *current* position into a
   preallocated scratch buffer (the "old tail"); then seek; then for the next
   `crossfadeFrames` output frames emit
   `old[i] * cos(θ) + new[i] * sin(θ)` with `θ = (π/2) · i / crossfadeFrames`
   (equal-power). If the ring runs dry mid-fade, the remaining new-side samples
   are zero and the fade degrades gracefully to a fade-out.
   ```swift
   /// 5 ms. Long enough that a splice in music is inaudible, short enough that
   /// a fast scrub's overlapping shifts stay perceptually continuous.
   static let crossfadeMs: Double = 5
   ```
   A shift arriving mid-crossfade restarts the fade from the current mixed
   output — never leave a fade half-applied.
5. **Real-time discipline.** All of the above runs on the render thread: no
   allocation, no locks, no logging, no Obj-C. Preallocate the scratch in
   `init`. This is the same contract the existing `render` path documents.
6. `BTSyncedSink.setTrimMs` stops calling `requestRebuild`. It computes the
   delta against the previous trim, converts to frames at `renderSampleRate`,
   and calls `sink.requestShift(frames:)`. **Sign check — get this right:** a
   *larger* trim means the device plays *later*, which means a *longer* delay,
   which means the read pointer must move **backward** (replay history). So
   `frames = -Int((newMs - oldMs) / 1000 * renderSampleRate)`. Write a test
   that pins this direction; it is the single easiest thing to invert.
7. If the sink has not yet released (`released == false`, still pre-roll), skip
   the seek entirely and instead recompute `targetReleaseNanos` from the new
   delay — no audio has been emitted, so the gate is the cheaper and cleaner
   lever. Guard this under `stateLock` alongside the existing anchor logic.
8. `requestRebuild(cause: "trim_change")` must no longer appear anywhere. Leave
   `offset_change`, `composition_change`, `config_change`, `rate_change`
   exactly as they are — those are genuine structural changes.

**Tests** (`AudioutCore/Tests/AudioutCoreTests/`, near the existing
`BTSyncedSink` render tests — these use `renderInterleaved` directly with no
engine, which is the seam to reuse)
- `seek` clamps at both ends and reports the applied delta.
- A positive trim change moves the read pointer backward (the direction pin).
- After a shift, output is continuous: no sample-to-sample step larger than the
  source signal's own maximum step, measured on a 1 kHz sine fed through the
  ring. This is the anti-click assertion.
- Total frames consumed over a shift equals the expected count ± the crossfade
  length — i.e. the shift really moved the timeline by the requested amount.
- A shift arriving mid-crossfade produces no discontinuity.
- Two shifts in one render cycle both land (accumulation, not overwrite).
- Pre-release shift path recomputes the target instead of seeking.
- No `bt_sink_rebuild` telemetry is emitted for a trim change.

**Acceptance:** full suite green. Live check (the owner): drag the ruler while music
plays — audio must stay continuous, no dropout, no click, and the change must
be audible immediately.

---

### T3 — Usable trim range per device

**Why:** D11. Without it the ruler lets the number run into a region where
nothing happens.

**Files:** `BTSyncedSink.swift`, `NativeBackend.swift`, `PopoverController.swift`.

**Do**

1. `BTSyncedSink.usableTrimRangeMs(forDeviceUID:) -> ClosedRange<Double>`.
   The delay is `reference − deviceOffset + trim`, clamped ≥ 0, where
   `reference` is the live presentation delay when AirPlay is present and
   `btOnlyBufferMs` (500) otherwise. So:
   ```
   lower = max(-BTSyncTrim.rangeMs, -(reference - deviceOffset))
   upper =  BTSyncTrim.rangeMs
   ```
   Read `composition`, `offsetMsByUID` and `btOnlyBufferMs` under `tableLock`,
   exactly as `delayNanos(forUID:)` does. Return the full ±range for an unknown
   uid.
2. Add `btUsableTrimRangeMs(forDevice:) -> ClosedRange<Double>` to
   `BTOutputControlling` (default implementation returns
   `-BTSyncTrim.rangeMs ... BTSyncTrim.rangeMs`).
3. `PopoverController` gets a `btTrimRangeProvider: ((String) -> ClosedRange<Double>)?`
   alongside the existing `btTrimProvider`, wired in `AppDelegate` next to it.
   Nil provider ⇒ full range (mock/dev builds keep working).

**Trap:** the range moves when AirPlay devices join or leave the group (the
reference term changes from 500 ms to the AirPlay presentation delay). The
drawer must re-read it on every `update(devices:)`, not cache it at open time.

**Tests:** a device with a 400 ms offset in BT-only mode yields a −100 ms floor;
the same device with AirPlay present yields a much lower floor; unknown uid
yields the full range.

---

### T4 — `BTSyncRulerView` (independent — start immediately)

**Why:** D3/D4/D5. The one genuinely new control.

**File (new):** `AudioutCore/Sources/AudioutSharedUI/BTSyncRulerView.swift`

**Shape:** an `NSView` drawing a horizontal tape of tick marks that slides
under a **fixed centre pointer**. No thumb, no filled track — it must not read
as a slider.

**Public surface**
```swift
public protocol BTSyncRulerViewDelegate: AnyObject {
    /// Continuous during the drag (D6). Already quantised and clamped.
    func syncRuler(_ ruler: BTSyncRulerView, didScrubTo ms: Double)
    /// Fired once when the drag ends — the commit/persist point.
    func syncRulerDidEndScrub(_ ruler: BTSyncRulerView)
}

public final class BTSyncRulerView: NSView {
    public weak var delegate: BTSyncRulerViewDelegate?
    /// Current value. Setting it externally repositions the tape without
    /// firing the delegate.
    public var valueMs: Double
    /// Hard stops (T3). The tape refuses to scroll past these.
    public var usableRangeMs: ClosedRange<Double>
}
```

**Drawing**
- Minor tick every 1 ms, major tick every 5 ms, numeric label on majors only
  (integer ms, `.monospacedDigitSystemFont`, `Tokens.Color.tertiaryLabel`).
- Centre pointer: a 2 pt accent-coloured vertical line spanning full height plus
  a small downward triangle at the top edge. Accent = the existing gold token
  (`Tokens.Color.accent` — confirm the exact token name in `Tokens.swift`; do
  not introduce a new colour).
- Beyond a usable bound, draw the tape dimmed and stop scrolling (a hard stop,
  not a rubber band).
- Everything sizes from new `PopoverColumnGrid` constants:
  `syncRulerHeight` (40), `syncRulerVisibleSpanMs` (12 — i.e. ±6, D4),
  `syncRulerMinorTickHeight` (6), `syncRulerMajorTickHeight` (12),
  `syncRulerPointerWidth` (2).

**Interaction**
- `mouseDown` → `mouseDragged` → `mouseUp`, tracked manually (no
  `NSTrackingArea` needed for the drag itself).
- **Gearing (D5):** ms-per-point is a function of instantaneous drag speed,
  measured over the last event's delta:
  ```
  speed (pt/event)   → ms per pt
  ≤ 1                  0.1 / ptPerFineStep   (slowest: 0.1 ms per ~3 pt)
  ramp                 linear in log-speed
  ≥ 40                 2.0
  ```
  Implement as a named private function `msPerPoint(forSpeed:)` with the two
  anchors as `PopoverColumnGrid` constants (`syncRulerSlowMsPerPoint`,
  `syncRulerFastMsPerPoint`). Drag **right** = larger value = plays later
  (matches the tape moving left under the pointer — verify by eye, this is the
  second easy inversion after T2's sign).
- Hold ⌥ during a drag ⇒ force the slowest gearing regardless of speed.
- Every emitted value goes through `BTSyncTrim.quantise` then the usable clamp.
- Scroll wheel over the ruler nudges by `resolutionMs` per detent (free, and
  trackpad users will try it).

**Accessibility (not optional)**
- `setAccessibilityRole(.slider)`, `setAccessibilityLabel("Sync offset")`,
  `accessibilityValueDescription` reading e.g. "22.4 milliseconds later".
- Implement `accessibilityPerformIncrement` / `Decrement` at `resolutionMs`.
- Keyboard: `acceptsFirstResponder = true`; ←/→ nudge by `resolutionMs`,
  ⌥←/→ by `coarseStepMs`. Draw a focus ring when it is first responder.
- Respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` — no
  inertial glide when set.

**Tests** (`AudioutCore/Tests/…UITests` — follow the existing headless
`DeviceRowView` test style; drive with synthesised `NSEvent`s or expose
`test_scrub(byPoints:speed:)` seams in the same spirit as the existing
`test_select*` hooks)
- Slow drag of 30 pt changes the value by ~1 ms; fast drag of 30 pt changes it
  by far more.
- ⌥ forces fine gearing at any speed.
- Values are always quantised to 0.1 and never leave `usableRangeMs`.
- Delegate fires continuously during the drag and `didEndScrub` exactly once.
- Setting `valueMs` externally does **not** fire the delegate.
- Accessibility increment/decrement move by exactly 0.1 ms.

---

### T5 — `BTSyncDrawerView`

**Depends on:** T4.
**File (new):** `AudioutCore/Sources/AudioutSharedUI/BTSyncDrawerView.swift`

The drawer's visual contract (mockup-locked):

- Container inset to the row's content column, with a **2 pt accent left edge**
  running its full height and a background one step darker than the row
  (`Tokens.Color.controlBackground` family — reuse, do not invent). Square
  corners: the codebase's rule is no rounded corners on single-sided borders.
- Top band, left: caption `"<device name> plays"` in
  `Tokens.Color.tertiaryLabel`, above a 26 pt tabular-figures readout and the
  suffix `"ms later"` (D7). For a negative value the readout shows the absolute
  number and the suffix becomes `"ms earlier"`. For an unset device: `"Not set"`
  in place of the number (D10).
- Top band, right: `−` button, `+` button, `Align by ear` button (metronome
  symbol + label; D9 — moved off the row), `Revert` button (D8).
- Below: `BTSyncRulerView`, full width.
- Footer, left: hint text `"Drag to nudge · hold ⌥ for finer"`. Footer, right:
  nothing (the Revert affordance is a real button in the top band, not a label
  — this is a correction to the earlier mockup, where a bare "calibrated 21.8"
  read as a mystery).
- The big readout is click-to-edit: clicking turns it into an `NSTextField`
  accepting a decimal. Reuse the editing behaviour already built into
  `DeviceRowView.syncField` — Return commits and is consumed (must not close the
  popover), focus loss commits, Escape reverts, ↑/↓ nudge. **Lift that
  `NSTextFieldDelegate` logic into a shared helper rather than copy-pasting it**;
  it was hard-won from live testing.
- `−` / `+` step by `coarseStepMs`; ⌥-click steps by `fineStepMs`.
- `Revert` is disabled when the current value equals the open-time value.

**Delegate**
```swift
public protocol BTSyncDrawerViewDelegate: AnyObject {
    func syncDrawer(_ d: BTSyncDrawerView, didChangeTrimMs ms: Double, committed: Bool)
    func syncDrawer(_ d: BTSyncDrawerView, didToggleAlignTick active: Bool)
    func syncDrawerDidRequestClose(_ d: BTSyncDrawerView)
}
```
`committed: false` during a live scrub (apply to audio, do not persist);
`committed: true` on drag end, stepper click, typed commit, or revert (apply
**and** persist). This split exists so a scrub does not write the JSON store
dozens of times a second.

**Configure**
```swift
public func configure(deviceName: String, trimMs: Double, isSet: Bool,
                      usableRangeMs: ClosedRange<Double>, alignTickActive: Bool)
```
Calling `configure` while the user is mid-drag or mid-edit must not yank the
value out from under them — guard exactly as `DeviceRowView.configure` already
guards `syncField` with `currentEditor() == nil`.

**Height:** `PopoverColumnGrid.syncDrawerHeight` — derive it from its parts
(readout band + ruler + footer + insets) rather than hardcoding a magic number,
in the style of the existing derived `syncClusterWidth`.

**Tests:** configure/read-back for each state (set, unset, negative → "earlier",
at floor); Revert enablement; ⌥-click stepping; the `committed` flag is false
during scrub and true on end; align toggle round-trips.

---

### T6 — Row: value chip replaces the cluster

**Depends on:** T1, T5.
**File:** `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift` (+ grid constants).

**Do**

1. Delete `syncMinusButton`, `syncPlusButton`, `syncField`, `alignButton` and
   their constraint block from the row. Their behaviour now lives in the drawer.
2. Add `syncChipButton: NSButton` — a bordered, rounded-rect (`var(--radius)`
   equivalent: `PopoverColumnGrid.syncChipCornerRadius = 5`) control showing:
   - `"22.4 ms"` + a trailing chevron (`chevron.down` collapsed,
     `chevron.up` expanded), tabular figures;
   - `"Not set"` in `tertiaryLabel` with a **dashed** border when unset (D10);
   - filled with the accent colour, dark text, when its drawer is open — so the
     row and drawer read as one object.
3. New delegate method, replacing `didSetSyncTrimMs` on the row:
   ```swift
   func deviceRow(_ row: DeviceRowView, didToggleSyncDrawerFor id: String)
   ```
   `deviceRow(_:didToggleAlignTick:for:)` moves to the drawer's delegate and is
   removed from `DeviceRowViewDelegate`.
4. `configure(...)` gains `syncDrawerExpanded: Bool` and `syncTrimIsSet: Bool`;
   `syncTrimMs` becomes `Double`.
5. Grid constants: replace `syncStepperButtonWidth`, `syncValueFieldWidth`,
   `syncControlGap`, `syncAlignButtonWidth`, `syncAlignGap` and the derived
   `syncClusterWidth` with `syncChipWidth`, `syncChipHeight`,
   `syncChipCornerRadius`. **Keep `syncTrailing`, `btFeedReserveWidth`,
   `btFeedToSyncGap` and the subsection header's SYNC-title centring maths
   working** — the FEED pill stays hard right and the column title stays centred
   over the chip. Update the derived centre calculation to use the chip width.
6. Accessibility: the chip is a button labelled "Sync offset for <device>",
   value "22.4 milliseconds later" or "not set", with
   `accessibilityExpanded` reflecting drawer state.

**Non-negotiable regression guard:** AirPlay rows (`showsSyncControls == false`)
must render byte-for-byte as before. There are existing row-layout tests —
run them and do not modify their expectations.

---

### T7 — Accordion, wiring, persistence

**Depends on:** T1, T3, T5, T6.
**File:** `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift`.

**Do**

1. State: `private var expandedSyncDeviceID: String?`. Setting it to a new id
   **collapses the previous drawer first** (D2) — one drawer instance is enough;
   reuse and reconfigure it rather than creating one per row.
2. On `didToggleSyncDrawerFor id`: if `expandedSyncDeviceID == id`, collapse
   (set nil); else expand that row. Rebuild the device stack so the drawer view
   is inserted immediately after the target row, then publish the new
   `preferredContentSize` through the **animated** resize path (~line 885–910).
   Use the standard token duration; honour reduce-motion.
3. Auto-collapse when: the device stops being available or selected; the row
   disappears from `update(devices:)`; the popover closes. On collapse, if the
   align tick is running, stop it (`didToggleAlignTick(false)`) — a metronome
   ticking with no visible control is a bug.
4. Trim application:
   - `committed == false` → apply to audio only:
     `setBTSyncTrim(ms, forDevice:)` must gain a `persist: Bool` parameter (or a
     sibling `setBTSyncTrimLive(_:forDevice:)`) so the scrub path skips
     `BTTrimStore.save`. Update `btTrimsByID` either way so the row chip tracks
     the scrub live.
   - `committed == true` → apply **and** persist.
5. Re-read `btTrimRangeProvider` on every `update(devices:)` and push the fresh
   range into the open drawer (T3's trap).
6. Test seams in the existing house style:
   `test_toggleSyncDrawer(deviceID:)`, `test_expandedSyncDeviceID`,
   `test_syncDrawerVisible`. **Note the known trap:** `test_select*`-style hooks
   bypass AppKit dispatch and have previously hidden real breaks — so also
   assert the chip's target/action is actually wired, not just that the model
   flips.

**Tests**
- Opening B while A is open leaves exactly one drawer, attached to B.
- Collapse on deselect, on disappearance, and on popover close.
- Align tick stops on collapse.
- A scrub sequence produces many audio applications and exactly one persist.
- Popover height grows by `syncDrawerHeight` on expand and returns exactly on
  collapse.
- AirPlay rows never expose the chip or drawer.

---

### T8 — Docs and design-system sync

**Depends on:** T6, T7 landed.

1. Update `docs/plans/PLAN-UNIVERSAL-SYNC.md`'s "UI SPEC LOCKED" block: the SYNC
   column is now a chip + drawer, and the align button lives in the drawer.
   Keep the older cluster description only as a struck-through note explaining
   what replaced it and why.
2. Update the nearest `AGENTS.md` files (`AudioutSharedUI/`, `AudioutCore/`)
   with two rules worth having: **a trim change must never rebuild a sink**, and
   **only one sync drawer may be open at a time**.

---

## 4. Traps

1. **Sign inversion, twice.** T2's seek direction (larger trim ⇒ read pointer
   moves *backward*) and T4's drag direction (right ⇒ later). Both are 50/50
   guesses that compile either way. Pin both with tests.
2. **Do not schedule BT audio at absolute times.** Live-verified this session:
   the Bluetooth pacing clock jumps by tens of milliseconds, so anything handed
   an absolute host time can land in the device's past and go silently
   inaudible. Everything here works in relative frames — keep it that way.
3. **Do not reset the drift corrector on a trim.** A seek is not a new clock
   context. `clearSessionStateLocked` must not run on the trim path; the PI
   integrator keeps its learned rate.
4. **Real-time thread discipline** in `BTDelayLine`: no allocation, no locks, no
   logging, no Obj-C messaging. The existing `render` path documents this
   contract — match it.
5. **`Double` in dictionary keys / equality.** Never compare trims with `==`
   for "changed?" decisions without quantising first; use
   `BTSyncTrim.quantise` on both sides.
6. **Popover height.** The popover derives its size from Auto Layout fitting
   size. A drawer with an ambiguous height silently collapses the popover
   instead of erroring — give it a definite height constraint.
7. **The align tick and a paused stream.** The tick is injected into the capture
   fan-out, so with no audio playing there is nothing to inject into. That is
   pre-existing and out of scope, but do not "fix" it by starting a stream.
8. **Guard 4 runs the full suite** on every Swift commit, and the suite floor is
   ~80 s. Do not commit six times in a row; batch.

---

## 5. Definition of done

- Trim changes apply while music plays with no dropout, no click, and no
  `bt_sink_rebuild` telemetry.
- The ruler resolves 0.1 ms, spans the full range by scrolling, and hard-stops
  at the device's real floor.
- Exactly one drawer open at a time; it collapses on deselect, disappearance,
  and popover close, taking the align tick with it.
- Untuned devices read "Not set"; tuned devices read "N ms later" / "N ms
  earlier".
- Revert restores the open-time value and disables when there is nothing to
  revert.
- AirPlay rows are visually and behaviourally unchanged.
- Full suite green (`bash scripts/run-tests.sh`).
- Live verification by the owner on real hardware before any merge to `main`.
