# PLAN — Volume-key interception on the aggregate device

**Status:** ready to build. Unblocked 2026-08-07 — the Wave-3 aggregate merged to
main (`daa8793e`) and is live-verified, so the trigger condition is now a shipped
feature and the identity gate this plan needs is real.

**Supersedes** the 2026-07-26 revision of this file, which was written before the
aggregate existed and before the Touch Bar was researched. Two things changed:
the gate is now buildable, and the Touch Bar turns out to split into a fixable
half and an unfixable half (§2), which adds a whole part (§7) that the old plan
did not have.

Self-contained handoff — an agent should be able to execute this without the
originating conversation. Verify each `file:line` citation against current source
before relying on it (docs orient, code decides); line numbers drift.

---

## 1. Why this is needed (proven live, not hypothetical)

The public **"Audiouter" aggregate device** wraps the Mac's built-in output so the
app appears in System Settings › Sound as a normal-looking output. When that
aggregate is the macOS default output, **the hardware volume keys do nothing** —
Alec confirmed this on real hardware. macOS shows the crossed-out volume HUD on
each press.

Today the only way to change volume while the app is routing is to open the app.
That is the gap this plan closes.

**The trap that wasted time before, do not repeat it:** the aggregate *advertises*
volume capability — `aggtool status` reports `vmvc=true scalarMain=true
muteMain=true` — but does **not** deliver it. A capability check is NOT a safe
gate. See §4.

---

## 2. The mechanism — researched 2026-08-07, no probe needed

This section is the load-bearing research. It is derived from static analysis of
`/System/Library/CoreServices/ControlStrip.app/Contents/MacOS/ControlStrip` on
macOS 27.0 (build 26A5388g), not from forum anecdote.

`ControlStrip.app` links **`DFRFoundation.framework`** ("Dynamic Function Row" —
Apple's internal name for the Touch Bar) and imports two mutually exclusive sets
of symbols:

| Imported symbol | What it drives |
|---|---|
| `_DFRFoundationPostHIDUsage` | Posts a real HID usage (Consumer page; `kHIDUsage_Csmr_VolumeIncrement` = `0xE9`, `…Decrement` = `0xEA`, `…Mute` = `0xE2`) into the system event stream |
| `_AudioObjectSetPropertyData`, `_AudioObjectIsPropertySettable` | Writes the default output device's volume scalar directly, and asks whether it *can* be written |

That yields a clean split, and it explains the greying exactly:

| Control | Path | Interceptable by a CGEventTap? |
|---|---|---|
| Physical volume keys (external / non-Touch-Bar keyboard) | HID | **Yes** |
| Touch Bar **discrete** Volume Up / Down / Mute buttons | `DFRFoundationPostHIDUsage` → HID | **Yes** |
| Touch Bar volume **slider** | `AudioObjectSetPropertyData`; greyed via `AudioObjectIsPropertySettable` | **No** — emits no event at all |
| Menu-bar / Control Center slider, Siri, `osascript set volume` | Same direct CoreAudio write | **No** |

A HID usage posted by `DFRFoundationPostHIDUsage` travels the same path as a real
key press — HID → WindowServer → session event taps — so it arrives at our tap as
an `NSSystemDefined` subtype-8 aux-key event, indistinguishable from a hardware
key. This is corroborated by [MonitorControl issue #180](https://github.com/MonitorControl/MonitorControl/issues/180),
where a user's greyed-out Touch Bar volume button still drove MonitorControl's
event tap; and the slider half is corroborated by the maintainer's own statement
in [discussion #845](https://github.com/MonitorControl/MonitorControl/discussions/845)
that the Touch Bar slider "is not available as well", with no known workaround.

**Consequence, and it is the reason §7 exists:** on a Touch Bar Mac whose Control
Strip shows the default volume *slider*, interception alone fixes nothing. The
user must be using the discrete buttons. §7 makes that true automatically.

**Residual uncertainty (small, folded into the live test — do NOT spend a separate
session on it):** symbol presence proves the binary can do both things, not which
UI element calls which function. The inference is strongly consistent with the
observed greying and with both MonitorControl reports, but the first live test
(§9) confirms it in thirty seconds. If discrete buttons turn out *not* to emit,
stop and re-plan — §7 becomes pointless and the feature only helps external
keyboards.

---

## 3. Scope and locked decisions

Alec, 2026-08-07:

1. **Option A (event tap) only.** The virtual-driver alternative — which would fix
   *every* surface natively including the sliders — is **rejected**: it requires an
   admin-password install. Do not revisit it. (Research kept at
   `dev/spikes/virtual-device/SPIKE-REPORT.md` in worktree
   `agent-a8f62fddcb614b153`; its caveat C4 notes a volume control is "roughly 80
   lines", so the option remains open if the constraint ever changes.)
2. **Dead sliders are acceptable.** Menu-bar, Control Center and Touch Bar sliders
   stay greyed. "They can go into our app and change it there. If they want a
   shortcut, we build them the shortcut through the buttons."
3. **Touch Bar layout is swapped automatically and reversibly, driven by the
   current output** — buttons while our aggregate is the default output, their own
   layout back the moment it isn't. Framed to the user as "to keep everything
   working with our app, let's make this change, but we're not changing your
   permanent setup." Not silent-and-permanent; not instructions-only.
4. **No HUD** (carried forward from Alec's 2026-07-26 call). Consuming the key
   kills the crossed-out HUD and we post nothing in its place. The app's own UI
   reflects the change. Do not reach for the private `OSDUIHelper` path —
   MonitorControl reports it degrading on recent macOS, and we support macOS 14–27.
5. **Mute key toggles Main mute** — `GroupController.setMainOutMuted(_:)` already
   exists (`GroupController.swift:873`), no new entry point needed.
6. **Step feel matches macOS exactly**: 1/16 of the range per press, 1/64 with
   ⇧⌥, snap to sixteenths.

**Deployment target is macOS 14** (`AudiouterCore/Package.swift:60`), so everything
here must work on 14 → 27. Every Touch Bar Mac that can run macOS 14 is a 2018–2022
model, and the Touch Bar was discontinued after the M2 13" (2022) — **that model
list is closed and will never grow**, which is what makes §7's hardware check cheap.

---

## 4. The design — ONE "we own volume" mode

Reframe, and this is the single most important structural decision: interception
(input) and applying Main to the Mac's own output (output) are the two halves of
the SAME condition — *"the system volume isn't ours to write, so we take the
wheel."* Build them as one mode behind one predicate. Two bolt-ons with two gates
is the wrong shape and will drift.

```
weOwnVolume ==
      default output device UID == AggregateOutputDevice.productUID   // our aggregate
   || systemOutputVolume == nil                                       // genuine HDMI etc.
```

**Why identity, not capability.** The aggregate lies (§1). `systemOutputVolume`
(`OutputBackend.swift:394`) returns non-nil off the aggregate's advertised
`scalarMain`/`vmvc` controls even though writes silently no-op, so a nil-check or
any capability probe slips straight through and the takeover never fires — volume
just dies with no error. We *create* the aggregate, so we own its UID
(`AggregateOutputDevice.productUID`, `AggregateOutputDevice.swift:87`) and a direct
string match is exact where a behavioural test is fragile. The second arm keeps the
genuinely-unreadable HDMI case working, which is a real pre-existing bug, not scope
creep.

`AggregateOutputDevice.swift:29-30` already anticipates this: *"a future volume-key
interceptor will gate on `AggregateOutputDevice.productUID`, not duplicate this
file."* Honour that — do not add a second aggregate-identity path.

**Re-evaluate on default-device change.** `DefaultOutputDeviceMonitor`
(`DefaultOutputDeviceMonitor.swift:56`) already watches
`kAudioHardwarePropertyDefaultOutputDevice` and fans out to subscribers with a
settle window. Subscribe; do not add a third HAL listener.

**Getting this wrong is a SILENT failure in both directions** — double-moving Main
on a normal output, or dead volume on the aggregate. It deserves the most test
attention of anything in this plan.

---

## 5. Part A — the interceptor (input half)

### A1. The tap

```swift
CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,               // consuming; .listenOnly cannot swallow the HUD
    eventsOfInterest: CGEventMask(1 << 14),   // NX_SYSDEFINED — no CGEventType case exists
    callback: …, userInfo: …
)
```

`14` is `NX_SYSDEFINED`; `CGEventType` has no public case for it, so the mask is
built by hand. Filter to **only** that type — never tap `.keyDown`, which would put
us in the path of every keystroke the user types.

### A2. Decoding (same event shape `MediaKeyController.postAux` writes)

Wrap in `NSEvent(cgEvent:)`, then require `type == .systemDefined && subtype == 8`.
From `data1`:

| Field | Extraction |
|---|---|
| key code | `(data1 & 0xFFFF_0000) >> 16` |
| key flags | `data1 & 0x0000_FFFF` |
| key state | `(keyFlags & 0xFF00) >> 8` — `0xA` down, `0xB` up |
| auto-repeat | `keyFlags & 0x1` |

Key codes from `IOKit/hidsystem/ev_keymap.h`: `NX_KEYTYPE_SOUND_UP = 0`,
`NX_KEYTYPE_SOUND_DOWN = 1`, `NX_KEYTYPE_MUTE = 7`. Extend
`MediaKeyController.AuxKey` (`MediaKeyController.swift:28`) rather than declaring a
second enum of the same constants.

Act on **key-down and auto-repeat**; swallow key-up silently (passing the up
through without the down would confuse downstream listeners).

### A3. The callback must be fast and must not hop threads to decide

macOS disables a tap whose callback is slow. The consume/pass decision therefore
has to be **synchronous** and read a cached, atomically-updated `weOwnVolume` flag
— never `await` a `@MainActor` value. Shape:

- pure decision function (testable, no Core Graphics types in its signature) →
  returns `.passThrough` or `.consume(VolumeIntent)`;
- on `.consume`, dispatch the *action* to the main actor asynchronously and return
  `nil` from the callback immediately.

Handle `.tapDisabledByTimeout` and `.tapDisabledByUserInput` in the same callback
by calling `CGEvent.tapEnable(tap:enable:true)`. A tap that silently dies is the
classic failure here, and a non-nil tap is not a healthy tap — poll
`CGEventTapIsEnabled` on the same default-device change that re-evaluates the mode,
and re-enable if it went false.

**razor:** install the run-loop source on the **main** run loop. Ceiling: if the
main thread ever blocks long enough for macOS to disable the tap, the upgrade path
is a dedicated thread with its own run loop. The re-enable handler above makes that
failure recoverable rather than fatal, so a dedicated thread is not worth its
complexity today.

### A4. Step math (pure, unit-tested)

Main is 0–100. macOS moves 1/16 of the range per press.

- normal press: `±100/16` = `±6.25`
- ⇧⌥ held: `±100/64` = `±1.5625`
- snap the *result* to the nearest sixteenth so repeated presses land on macOS's
  own detents and never drift
- clamp to `0...100`

Read the modifier from the same `NSEvent`'s `modifierFlags` (`.shift` + `.option`).
Note the aux-key encoding mirrors key state into the low bits of the flags — mask
with `.deviceIndependentFlagsMask` before testing, or ⇧⌥ detection will be wrong.

### A5. Driving Main

`GroupController.applyExternalSystemVolume(_:)` (`GroupController.swift:846`) —
contract is deliberately source-agnostic exactly so a key interceptor can call it:
*"the system output volume is already at `volume`; bring Main into agreement and
re-push every dependent gain. Writes NO hardware."* It is the read-back arm, never
writes the system volume, so it cannot feed back. Correct here because the
aggregate cannot take a hardware volume write anyway.

Mute: `GroupController.setMainOutMuted(!isMainOutMuted)` (`:873` / `:868`). Do not
overload the volume path with a mute concept.

### A6. Do NOT double-drive the normal path

On a normal (settable) output the existing chain still runs and must be left
completely alone:

```
volume key → macOS moves system volume
           → SystemOutputVolume listener fires
           → NativeBackend emits .systemVolumeChanged(volume:)
           → AppDelegate.swift:1329  groupController.applyExternalSystemVolume(volume)
```

When `weOwnVolume` is false the tap must pass the event through untouched. Both
paths firing would move Main twice per press.

---

## 6. Part B — Main must actually attenuate the Mac (output half)

Without this the feature is useless in the commonest case: the aggregate wraps the
built-in speakers, so pressing volume-down moves Main and quiets the AirPlay
members while **the Mac's own speakers stay at full**. The user presses volume-down
and hears nothing change.

`SyncedLocalSink`'s gain deliberately excludes Main on the assumption that "the
Mac's system volume already applies Main to its own output" — `syncedLocalGain`
(`NativeBackend.swift:2025`) is `group × device` only. That assumption breaks
exactly when `weOwnVolume` is true, because `setMasterGain`'s `mirrorToSystemVolume`
arm calls `systemVolume.setVolume(main)` and every write is behind an `isWritable`
check, so it silently no-ops.

**Fix:** when `weOwnVolume` is true, `syncedLocalGain` becomes `main × group ×
device`; when false it stays `group × device` (so Main is never double-applied).
Same predicate, no second gate.

The existing test `syncedLocalSinkGainCarriesGroupButExcludesMain` pins the
settable case — keep it green and add its mirror for the owned case.

**Also fold in here** (same writability question, narrow but real): `setMasterGain`
memoises `lastSeenSystemVolume = main` optimistically, trusting the mirror write
landed. On a **readable-but-unwritable** default output (some USB DACs — non-nil
`systemOutputVolume`, so *not* caught by the nil arm) the write no-ops but the memo
says `main`, so a later genuine external change *to `main`* is dropped. Make
`SystemOutputVolume.setVolume` report whether it wrote (it is fire-and-forget
`queue.async` today) and only memo on success.

---

## 7. Part C — Touch Bar Control Strip auto-swap

Makes §2's fixable half actually reachable. Fully feasible, verified on this
machine — **no admin password, no elevated privilege**.

### C1. Facts established (macOS 27.0, `MacBookPro17,1`)

- Layout lives in `~/Library/Preferences/com.apple.controlstrip.plist`,
  user-owned, mode `600`.
- Two arrays: `MiniCustomized` (collapsed strip) and `FullCustomized` (expanded).
  A missing key means "macOS default".
- Item identifiers, extracted from the ControlStrip binary:
  `com.apple.system.volume` (slider popover), `com.apple.system.volume-up`,
  `com.apple.system.volume-down`, `com.apple.system.mute`, and
  `com.apple.system.group.volume` (the group that expands into −/+ buttons).
- `ControlStrip` runs as the user, so reloading it needs no privilege. It is an
  on-demand LaunchAgent (`/System/Library/LaunchAgents/com.apple.controlstrip.plist`,
  no `LimitLoadToHardware` key) and respawns immediately.

### C2. Hardware detection

**razor:** a fixed set of Touch Bar model identifiers, matched against
`hw.model`. The set is closed (§3) so it can never go stale, and it needs no
private API. Ceiling: if a check ever has to be dynamic, the upgrade path is
`dlsym`-ing `DFRGetStatus` out of `DFRFoundation` — the same pattern the repo
already uses for `TCCAccessPreflight`.

Note ControlStrip's LaunchAgent has no hardware condition, so "is ControlStrip
running" is **not** a valid Touch Bar test. Do not use it.

### C3. Read / write discipline

- Read with `CFPreferencesCopyAppValue(key, "com.apple.controlstrip")`; write with
  `CFPreferencesSetAppValue` + `CFPreferencesAppSynchronize`.
- **Never write the plist file directly** — `cfprefsd` owns it and will clobber us.
- **Never blind-overwrite the array.** Read-modify-write: replace only the volume
  item, preserve every other identifier and its order. Unknown identifiers from a
  future macOS must survive untouched.
- Reload by terminating ControlStrip (match `NSRunningApplication` on bundle id
  `com.apple.controlstrip`, `terminate()`; fall back to `SIGTERM`). Verify live
  whether the reload is even needed — ControlStrip may pick the change up on its
  own; skip the kill if so.

### C4. The swap

On entering `weOwnVolume` **and** Touch Bar present:

1. Read `MiniCustomized` (falling back to the macOS default set when absent).
2. If it already contains `volume-up`/`volume-down`/`group.volume`, **do nothing** —
   the user is already on buttons (this is Alec's own case; his `FullCustomized`
   has `com.apple.system.group.volume`).
3. Otherwise replace `com.apple.system.volume` with `com.apple.system.group.volume`,
   in place.
4. Persist the *original* array plus a "we changed it" marker to our own store
   (`RoutingStore` or a sibling) — **before** writing, so a crash between the two
   cannot lose it.
5. Write, sync, reload.

On leaving `weOwnVolume` (or at quit): restore the saved original, clear the
marker, reload.

### C5. The three ways this goes wrong, and the answers

| Failure | Answer |
|---|---|
| App is `SIGKILL`ed while swapped → user's strip stays changed | Marker is persisted (C4.4). On next launch, if a marker exists and we are not currently in the mode, restore immediately. Same shape as the aggregate's existing orphan sweep. |
| User customises their Control Strip *while* we have it swapped → our restore clobbers their new choice | Before restoring, compare the current array against **what we wrote**. If it differs, the user changed it — drop the marker and restore nothing. |
| Output flips rapidly → repeated ControlStrip kills | Debounce on the same settle window `DefaultOutputDeviceMonitor` already applies; never act on the raw notification. |

### C6. User-facing framing

Alec's words: *"to keep everything working with our app, let's make this change,
but we're not changing your permanent setup."* Surface it once, plainly, where the
onboarding permission rows live — not as a modal per switch.

---

## 8. Part D — permissions

`CGEvent.tapCreate` returns `nil` without **Accessibility** trust. That flips the
grant from optional to mandatory, which is a real product change:
`MediaKeyController`'s posting degraded silently without it; the interceptor cannot
exist at all.

- Reuse the existing seam — `RemoteControlPriming` (`SetupModel.swift:221`,
  factory `RemoteControlPrimer.swift:12`), already used by both onboarding and
  `MediaKeyController.swift:45`. Do **not** add a second Accessibility path or a
  raw `AXIsProcessTrusted()` call; the seam is what lets
  `AIRPLAY_PERMISSIONS=granted|denied` reach this code in automated runs.
- **Surface a revoked-grant state in the UI.** The keys silently die otherwise, and
  the user has no way to know why. Onboarding permission rows are the home.
- **cdhash-pinning gotcha during live testing** (memory
  `tcc-grants-cdhash-pinned-on-adhoc-builds.md`): ad-hoc dev rebuilds silently lose
  the grant while Settings still shows it on. Toggling does not fix it; REMOVE (−)
  and re-add does. Expect this; it is not a code bug.

---

## 9. Testing

### Headless
Keep the CGEventTap plumbing a thin shell over pure, tested functions:

- **mode predicate** — our-aggregate UID → true; a normal settable device → false;
  `nil` systemOutputVolume → true; **the aggregate's lying capability flags → still
  true** (the regression that matters most);
- **step math** — up/down from every sixteenth, ⇧⌥ quarter-steps, clamping at 0 and
  100, snap-to-detent after mixed steps;
- **event decode** — key code / state / repeat extraction from real `data1` values;
  modifier masking (A4's `deviceIndependentFlagsMask` trap);
- **decision function** — mode off → pass through; mode on + volume key → consume;
  mode on + unrelated systemDefined event → pass through;
- **`syncedLocalGain`** — mode on folds Main in; mode off does not (keep
  `syncedLocalSinkGainCarriesGroupButExcludesMain` green);
- **Control Strip swap** — pure array transform with an injected prefs seam
  (no fake may touch the real domain): already-has-buttons → no-op; default slider →
  swapped; unknown future identifiers preserved; restore-after-user-edit → declines
  to restore.

### Live — owed to Alec, cannot be automated
1. **Confirm §2's split first, thirty seconds:** with the aggregate active, press a
   Touch Bar *discrete* button (moves Main) and drag the Touch Bar *slider* (still
   dead). If the discrete button does nothing, **stop and re-plan.**
2. Volume keys move Main and every routed device follows.
3. **A normal output is untouched** — macOS handles the keys, Main still follows via
   the existing path, no double-move.
4. Main down actually quiets the **Mac's own speakers**, not just the AirPlay ones.
5. Touch Bar swaps to buttons on entering the mode and restores exactly on leaving.
6. Force-quit while swapped, relaunch → strip restored.
7. Revoked Accessibility is visible, not silent.
8. No-HUD feels acceptable in practice.

---

## 10. Sequencing

| Wave | Work | Status |
|---|---|---|
| W1 | Mode predicate + tests | **done** — `bb3735ab` |
| W2 | Event decode + step math + decision function, all pure + tests | **done** — `bb3735ab` |
| W3 | CGEventTap shell, run-loop source, disable/re-enable handling, wire W1+W2 | **done** — `a2b8c6c8` |
| W4 | `syncedLocalGain` folds Main; `setVolume` reports success | **done** — `9a2ee681` |
| W5 | Control Strip swap/restore/crash-recovery + tests | **done** — `ce8827f3` |
| W6 | Revoked-Accessibility UI state | **done** — `881f9ec7` |
| W7 | Live checklist (§9) | **owed to Alec** — cannot be automated |

Suite at W6: 1775 green.

**One decision taken during W5, worth knowing before the live test.** The swap
only transforms a layout it can READ. A user who has never opened Customize
Control Strip has no stored `MiniCustomized`/`FullCustomized`, and the factory
default lives in `ControlStrip.app`'s own code, published through no plist — so
they are left alone rather than handed a strip we invented in slots that have
nothing to do with volume (Alec's call). Alec's own Mac has `FullCustomized`
carrying `com.apple.system.group.volume` already, so his expanded strip is
already on buttons and the swap is a no-op for him — his live test exercises the
interceptor, not the swap.

---

## 11. Definition of done

Volume keys and Touch Bar discrete buttons move Main — and therefore every routed
device *and* the Mac's own output — while the aggregate is the default output;
normal outputs behave exactly as before; the Touch Bar layout swaps and restores
without ever permanently altering the user's setup; a revoked Accessibility grant
is visible rather than silent; decision logic is unit-tested; Alec's live checklist
passes.

**Do NOT merge to main** — hand back a committed, pushed branch for Alec to
live-test first (house rule).
