# G2b spike — a programmatic AGGREGATE device instead of the HAL driver

**Verdict: GO — the aggregate replaces the G2 driver for this feature, with two
hard caveats (A1, A2 below).** Everything the driver buys for "Audiouter shows
up in Sound settings, selected while routing, deselect = off switch" the
aggregate also buys — for zero install friction, zero code inside coreaudiod,
and a *better* crash mode. What it cannot buy, ever, is a live volume slider in
Sound settings (A2), and it demands one contained capture-path fix before
anything may set it default (A1).

Everything below was measured on this machine (macOS 27, Apple silicon) with
`build/aggtool` unless labeled *expected*. The default output device was never
changed; nothing audible happened. The machine was left at baseline (aggregate
destroyed, on-disk entry verified gone).

Tool: `aggtool.swift` (single Swift file, `./build.sh`, no sudo). Subcommands
`create` / `status` / `destroy` / `nest-test` / `watch` are agent-safe;
`set-default` / `restore` are **human-only** (they change the default output).

---

## 1. Create, appear system-wide, destroy, persist — ALL PROVED

`AudioHardwareCreateAggregateDevice` with
`kAudioAggregateDeviceIsPrivateKey: false`, name `Audiouter`,
UID `com.audiouter.spike.aggregate`, one sub-device (`BuiltInSpeakerDevice`,
also the main/clock sub-device) → `noErr`, and:

- **Enumeration:** appears in `kAudioHardwarePropertyDevices` for every process:
  `'grup'  out:2  Audiouter`.
- **`system_profiler SPAudioDataType`:** `Audiouter: … Output Channels: 2,
  Current SampleRate: 44100, Transport: Unknown` (SPAudio has no label for
  `'grup'` — cosmetic only, see §6).
- **Destroy:** `AudioHardwareDestroyAggregateDevice` → `noErr`, entry gone from
  enumeration *and* from disk.
- **Persistence across process exit: YES — the non-private flavor outlives its
  creator.** `create` and `status` are separate processes; the device was
  there. Stronger: coreaudiod writes it into its own store,
  `/Library/Preferences/Audio/com.apple.audio.SystemSettings.plist`
  (`Meta_UIDList` + `MetaDevice.com.audiouter.spike.aggregate`, master
  `BuiltInSpeakerDevice`, `private => false`) — so it survives coreaudiod
  restarts **and reboots** until explicitly destroyed. `destroy` removes the
  plist entry too (verified: zero occurrences after).
- **Trap: `AudioObjectID` is not stable.** `create` returned id 146; every
  later resolve of the same UID returned 107 (reproduced twice). Always resolve
  by UID (`kAudioHardwarePropertyTranslateUIDToDevice`), never cache the id —
  same rule `SystemOutputVolume` already follows.

Measured properties of the aggregate vs the raw speakers it wraps:

| property | Audiouter ('grup') | MacBook Pro Speakers ('bltn') |
|---|---|---|
| outputChannels | 2 | 2 |
| nominalSampleRate | 44100 (tracks sub-device) | 44100 |
| canBeDefaultDevice / System | **1 / 1** | 1 / 1 |
| latency (out frames) | 61 | 61 |
| safetyOffset (out) | 113 | 113 |
| volume: vmvc / scalar / mute | **false / false / false** | true / true / true |
| icon present / settable | false / false | — |
| name settable | true | — |

## 2. Settable as default — contract read, live call shipped, NOT run

`canBeDefaultDevice = 1` and `canBeDefaultSystemDevice = 1` (measured, output
scope) are exactly the bits Sound settings and `AudioObjectSetPropertyData`
gate on — same precondition the G2 driver report cites. The call, verbatim from
`aggtool` `set-default` (house rule: `DefaultOutputDevice`, never
`DefaultSystemOutput`):

```swift
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var id: AudioObjectID = /* TranslateUIDToDevice("com.audiouter.spike.aggregate") */
AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                           UInt32(MemoryLayout<AudioObjectID>.size), &id)
```

`aggtool set-default` saves the previous default's UID to
`build/.previous-default-uid` first; `aggtool restore` puts it back and
destroys the aggregate. Human checklist below runs it.

## 3. Capture path — one real trap, otherwise byte-identical to today

**The trap (measured): an aggregate cannot wrap another aggregate, and the
failure is SILENT.** `nest-test` builds exactly what
`NativeCaptureCoordinator.createAggregate()`
(`AudiouterCore/Sources/AudiouterCore/NativeCaptureCoordinator.swift:1973-2011`)
would build if `Audiouter` were the default output: a private aggregate whose
main sub-device is the public aggregate's UID (read from the default at
`:1980-1981`). Result: **creation returns `noErr` — and the composite is a
zombie: 0 output channels, nominal rate 0.0.** Every call keeps succeeding and
capture delivers nothing: the exact all-zero silent-success family this repo
was bitten by in the nominal-rate bug.

**Required fix (A1), before anything ever sets the aggregate default:** one
shared "effective capture device" resolver — *if the default output's UID is
our aggregate, resolve through to its main sub-device and pin the tap-aggregate
there.* It must be shared by **both** call sites, or the identity guard storms:

- `createAggregate()` (`:1980`) — pins `tappedOutputDeviceID`;
- the default-device listener's compare-before-rebuild guard (`:2195-2197`) —
  otherwise it reads current = aggregate ≠ tracked = speakers on every
  notification and rebuilds forever.

With A1 in place the capture topology is **identical to today**: global process
tap (`CATapDescription(stereoGlobalTapButExcludeProcesses:)`, `:1929` — captures
process streams regardless of destination device, per the G2 report) + private
tap-aggregate pinned to the *real* speakers. Local silencing while routing also
stays what it is today — the tap's `muteBehavior` (`:1931`), not the default
device — because unlike the driver's null sink, **the aggregate passes audio
through to the speakers**.

**Resampling / rate events: none added.** One sub-device = the main/clock
sub-device; coreaudiod's own store shows `drift => 0` for it — no drift
resampler in the render path. Latency/safety-offset are identical to the raw
speakers (table above). The aggregate's nominal rate tracks the sub-device, and
after A1 the rate listener still installs on the real speakers — the same
device it watches today. Correction to this spike's premise: the memory note is
stale — the whole-system tap **has** the nominal-rate listener now
(`installSampleRateListener`, installed at `NativeCaptureCoordinator.swift:1890`,
defined `:2238-2275`, compare-before-rebuild `:2155`), mirroring
`PerAppCaptureCoordinator.installSampleRateListener`
(`PerAppCaptureCoordinator.swift:1250`). Both keep working unchanged under A1.

## 4. Crash behavior — the claimed advantage HOLDS

- **Audio keeps flowing.** coreaudiod owns the aggregate's I/O (it is
  coreaudiod's own AudioAggregateDriver, configured by that plist entry) — the
  creating process holds no runtime role after creation. Kill −9 the app while
  `Audiouter` is default: processes keep rendering into the aggregate, the
  aggregate keeps forwarding to the speakers. **No silent-Mac mode.** The
  driver's worst risk (G2 C1: null sink + dead app = silent Mac needing a Mach
  heartbeat to engineer away) simply does not exist here.
- **The entry lingers** in the device list and on disk until destroyed (that is
  the §1 persistence, seen from the other side). While stale it is a fully
  functional passthrough to the speakers — annoying at worst, never harmful.
- **Adopt-or-recreate is trivial and proved:** next launch translates the UID —
  hit = adopt (`aggtool` does; create/destroy ran in different processes
  throughout), miss = recreate. On quit: restore the previous default *then*
  destroy. On launch after a crash: adopt, and if we are still default, stay.

## 5. Unselect detection — existing machinery fires, nothing device-specific

`SystemOutputVolume` owns a listener on the **system object** for
`kAudioHardwarePropertyDefaultOutputDevice`
(`AudiouterCore/Sources/AudiouterCore/SystemOutputVolume.swift:197-200`,
installed via `installDefaultDeviceListenerLocked()` `:549` from `start()`
`:439`) and surfaces every change as
`onExternalChange(volume:muted:defaultDeviceChanged: true)` (`:65`, fired
`:477/:486`). A system-object property listener fires on *any* default-output
change regardless of the device types involved — an aggregate is just another
`AudioObjectID`. The tap's own listener (`NativeCaptureCoordinator.swift:2179`)
fires too and correctly triggers the rebuild back onto the new device. So "user
picked another device in Sound settings" arrives as an existing callback; the
feature only adds the comparison *is the new default still our UID?* Both G2
traps carry over verbatim: echo-guard our own writes, and distinguish
"deselected" from "device gone". `aggtool watch` lets the human watch the
listener fire live.

## 6. Cosmetics and limits

- **Name: fully ours.** Renders as exactly `Audiouter` in enumeration and
  `system_profiler`; `kAudioObjectPropertyName` is even settable post-create.
  *Expected* in Sound settings: same name (it reads the same property) — human
  eyeball confirms.
- **Icon: none, and not settable** (measured: property absent, not settable).
  macOS shows its stock icon for aggregate-class devices; the driver could ship
  a custom icon, we cannot.
- **Labeled "aggregate" anywhere a user looks?** `system_profiler` says
  `Transport: Unknown` (no 'grup' label — mildly untidy, invisible to normal
  users). Audio MIDI Setup shows it openly as an aggregate (expected — that is
  its editor UI). System Settings › Sound has a Type column whose wording for
  'grup' devices needs the human eyeball (checklist #2).
- **The one permanent cosmetic wart (A2): no volume surface.** Measured: the
  aggregate publishes *no* volume scalar, no virtual main volume, no mute —
  and unlike the driver (G2 C4, "80 mechanical lines"), **we cannot add one**:
  Apple's AudioAggregateDriver serves the device. While `Audiouter` is default,
  Sound settings' output slider is dead and the volume keys show the
  no-volume HUD. Mitigation is app-side (the app already routes volume keys to
  Main Out while active), but the *system* UI stays dead. This is the strongest
  argument the driver retains.
- **Clock/drift/latency: non-issues** wrapping a single sub-device — it is the
  clock master, drift compensation is off (`drift => 0` in the plist), and
  latency + safety offset measured identical to the raw speakers.

---

## Comparison — aggregate (G2b) vs HAL driver (G2)

| | Aggregate (this spike) | HAL driver (G2) |
|---|---|---|
| **Install friction** | **None.** No installer, no admin password, no coreaudiod restart, no `Developer ID Installer` cert, no notarization pipeline; MAS not foreclosed. | Admin password, 1–3 s system-wide audio dropout on install/uninstall, new cert (procurement long pole), `productbuild`+`notarytool`+`stapler` `make-app.sh` does not have, MAS permanently foreclosed. |
| **Crash behavior** | **Audio keeps flowing** (coreaudiod owns the I/O; passthrough to speakers). Stale entry = harmless, adopt-by-UID next launch (proved). | Null sink + dead app = **silent Mac**; needs a Mach service + heartbeat (C1/C3, the largest unbuilt chunk) to engineer away. |
| **Sound-settings fidelity** | Name exact; selectable; **volume slider/keys permanently dead — unfixable (A2)**; stock aggregate icon only. | Name exact; selectable; volume+mute addable (~80 lines); custom icon possible; slider works. |
| **Capture-path risk** | One silent trap, **measured**: tap-aggregate over our aggregate = `noErr` zombie (0 ch, rate 0). Fix A1 = shared resolve-through, two call sites, then topology identical to today. No new resampling/rate events. | Wrapping the driver device assumed to work (not yet live-proved); macOS 15 all-zero-tap reports; `isLoopRiskDevice` one-liner (C7). |
| **Ongoing maintenance** | ~100 lines of in-app Swift on APIs two coordinators already use daily; lifecycle = adopt/create/destroy. | 976-line C driver executing inside Apple's driver-host, per-OS-release quirk matrix, installer + notarization forever, uninstall/orphan UX (C6/§7). |

**Bottom line:** the driver wins one row (a live system volume slider). The
aggregate wins the other four, including both rows G2 called its own worst
risks (C1 silent-Mac, C2/C6 distribution). If a dead system slider while
routing is acceptable — the app already owns the volume keys — ship the
aggregate and retire the driver for this feature; the validated driver spike
remains on its branch as the fallback if A2 is ever deemed a deal-breaker.

Caveats, consolidated:
- **A1 (blocking):** shared effective-capture-device resolver before anything
  sets the aggregate default (§3) — and its absence fails *silently*.
- **A2 (product decision):** system volume slider/keys dead while selected;
  unfixable at this layer (§6).
- **A3:** echo-guard our own default writes; deselect ≠ device-vanished (§5,
  same as G2).
- **A4:** `LocalPlaybackEngine.isLoopRiskDevice`
  (`AudiouterCore/Sources/AudiouterCore/LocalPlaybackEngine.swift:1045-1054`)
  matches aggregates only by tap-name prefixes (`:1035`) — add the product UID,
  same one-line class as G2's C7. Also `NativeBackend.currentOutputDeviceName()`
  (`NativeBackend.swift:3356`) would label the local row "Audiouter" —
  self-referential, same fix family as G2 noted.
- **A5:** pick the shipping UID once and never change it (coreaudiod keys the
  persisted entry and per-device state by UID).

---

## Live checklist for Alec (~5 minutes, nothing an agent may run)

```
cd "dev/spikes/aggregate-device" && ./build.sh
```

1. `build/aggtool set-default` — saves your current default, creates the
   aggregate, makes it the default output.
2. **Eyeball System Settings › Sound › Output:** is `Audiouter` listed and
   selected? What does its Type column say? What icon?
3. Play a few seconds of music — it should still come out of the MacBook
   speakers (the aggregate is a passthrough, not a null sink).
4. Tap the volume keys — expect the no-volume (circle-slash) HUD and a greyed
   slider in Sound settings. Note what you see; this is caveat A2, the main
   product decision.
5. In a second terminal: `build/aggtool watch`, then pick **MacBook Pro
   Speakers** in Sound settings — the watch line should print the change
   instantly (that's the off-switch signal, point 5).
6. `build/aggtool restore` — restores your saved default and destroys the
   aggregate. `build/aggtool status` should say NOT present.
