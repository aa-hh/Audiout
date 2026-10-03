# Individual local outputs — speakers, jack, USB, HDMI as their own rows

Origin: a user asked for the local audio options to be split into one item per
output the Mac actually has: MacBook speakers AND the headphone jack when
something is plugged in, each USB output when present, and so on. Grilled with
the owner 2026-09-26 (decisions below).

## What exists today (read before touching anything)

- **"This Mac" is a role, not a device.** One row, fixed id `local-mac`
  (`NativeBackend.swift`, `localDeviceID`), that FOLLOWS the system default
  output and takes its name. It carries passthrough, the auto-swap rule, Main
  mirroring the system volume (`GroupController.localRowDrivesMain`), volume-key
  interception, "Current device == no redirect" for app routes, and the
  companion snapshot's local flag. ~78 sites key off `Device.isLocalDevice`;
  `Device.swift` documents "exactly one device in a fleet" carries it. Its sync
  offset is ONE app setting (`AppSettings.syncOffsetMs`), not per device.
- **While whole-system routing is armed, "This Mac" IS the built-in speakers.**
  The public "Audiout" aggregate becomes the default output and wraps ONLY the
  built-in output (`AggregateOutputDevice.swift`, `builtInOutputDeviceUID`); the
  synced local copy renders through the default. A user whose Mac normally
  plays through anything else — a USB DAC, headphones in the jack, a monitor's
  speakers — therefore hears the Mac's copy on the laptop speakers. Unverified
  on hardware from this session; ticket 06, reproducible with headphones.
- **Bluetooth is the precedent for "a Core Audio output as its own row".**
  `BTDeviceEnumerator` lists HAL devices by transport type; each becomes a
  `Device(kind: .bluetooth)` keyed by its Core Audio UID; each selected one gets
  a `BTDeviceSink` — an `AVAudioEngine` pinned to that exact device via
  `setDeviceID`, delayed to the room reference (`BTReferenceTimeline`), with
  `LocalOutputLatency.measure(deviceID:)` for the reported part and the sync
  drawer + trim store + alignment wizard for the rest. Bluetooth is never
  engine-driven; it is the second routing partition, Cast the third.
- **Licence boundary.** `SyncedLocalSink.swift` is GPL-headered;
  `BTSyncedSink.swift` and `SyncCore.swift` are licence-clean by design. A wired
  sink is built from the licence-clean family, never by copying from the GPL
  local sink (`AudioutCore/Sources/AudioutCore/AGENTS.md`).

## Decisions (owner, 2026-09-26)

1. **Keep "This Mac"; add wired rows beside it.** The existing row keeps every
   behaviour above as the passthrough / default-output role. Every OTHER wired
   output appears as an ordinary synced endpoint, the way Bluetooth rows do.
   The wired row whose UID matches the current default output is HIDDEN (it is
   what "This Mac" already is); when the default changes, the hidden one swaps.
2. **Every wired Core Audio output gets a row**: built-in speakers, headphone
   jack, USB, HDMI/DisplayPort, Thunderbolt. Excluded by transport: Bluetooth
   (already its own partition), AirPlay, virtual, aggregate, auto-aggregate
   (the loop-risk set `SystemLocalOutputResolver.isLoopRisk` already refuses),
   and the app's own public aggregate by UID.
3. **Sync = reported latency automatically, plus the existing trim drawer.**
   Delay per wired row = room reference − `LocalOutputLatency.measure(deviceID:)`
   − trim, clamped ≥ 0, same as `BTReferenceTimeline`. The sync drawer, trim
   store and alignment wizard generalise from "Bluetooth row" to "locally
   rendered sink" so an HDMI → TV → soundbar chain (which under-reports) can be
   aligned by the user.
4. **Wired rows are per-app destinations and saved-group members**, exactly as
   Bluetooth: `isRouteTargetReachableLocked` and `AppRouteTargetEligibility`
   admit them; `GroupStore` keys them by UID. Scene-as-app-target stays AirPlay 2
   only.

## Design shape

- New `Device.Kind.wired` (fourth partition beside `.bluetooth` and `.cast`):
  `id` = Core Audio `kAudioDevicePropertyDeviceUID`, `supportsAirPlay2 == false`,
  `isLocalDevice == false`, never fed to `engine.updateDiscovery`.
  `isDiscoveredOverLocalNetwork` answers `false` (exhaustive switch forces it).
- `WiredOutputEnumerator` (Core Audio only — no IOBluetooth, no TCC): HAL
  device list → transport filter → `hasOutputStreams` → drop the default's UID
  (resolved THROUGH our aggregate to its sub-device) → snapshot. Re-enumerate on
  `kAudioHardwarePropertyDevices` and `kAudioHardwarePropertyDefaultOutputDevice`
  changes. No paired list means no ghost rows: an unplugged output leaves the
  list; a saved group that names it keeps the member greyed, the way a dropped
  AirPlay device is kept.
- Per-row sink: the `BTDeviceSink` shape (pinned `AVAudioEngine`, ring, resampler,
  PI phase loop, per-device EQ) fed from the same fan-out the Bluetooth manager
  reads, under the same live room reference. Whether that is `BTDeviceSink`
  itself with a transport-neutral name or a sibling is ticket 03's call; the
  refusal of aggregate/virtual transports stays.
- Volume: software gain per row, mute = gain 0 (glossary "software gain").
  Hardware volume on a USB DAC that publishes a settable HAL volume is a later
  opt-in, mirroring the Bluetooth "hardware-controlled speaker" toggle.
- Composition: a wired output present with no AirPlay/Cast keeps the Mac host
  clock as reference (like BT-only); with AirPlay/Cast present, the presentation
  timeline is the reference. `BTGroupComposition` grows a `wiredPresent` term or
  is renamed; the "Mac joining changes nothing" rule keeps holding for "This Mac".
- Analytics: new user actions get `Analytics.capture` events registered FIRST in
  `audiout-shared/docs/analytics-events.md`; properties carry transport enum
  strings and counts, never device names.

## Must be verified on a real Mac before ticket 02 is written (AGENTS.md rule)

See ticket 01. Specifically: whether the headphone jack is a separate HAL device
(Apple Silicon) or a data-source flip on one device (Intel) — the row model must
tolerate both; what UID/transport/name a USB audio output and an HDMI display
report (the owner has no USB DAC; a USB-C headphone dongle or a USB-C monitor
is the stand-in); whether HDMI reports any latency at all; and ticket 06's
suspected bug.

## Further decisions (owner, 2026-09-26, second round)

5. **Placement:** wired rows list directly under "This Mac" inside the Current
   Device subsection — the Mac and its other outputs. Bluetooth and AirPlay
   sections are untouched.
6. **Glyphs, one per transport**, SF Symbols template-rendered: jack →
   `headphones`, USB → `cable.connector`, HDMI/DisplayPort → `display`,
   built-in speakers when not the default → `laptopcomputer`.
7. **A wired row may be selected alone**, with "This Mac" deselected, exactly
   like a lone Bluetooth row: the aggregate takes the default output and the
   pinned sink plays. Volume keys then go through the app, as they do today
   whenever the aggregate is the default.

No open owner questions remain; ticket 01 (hardware) is the only gate.

## Tickets

| # | Ticket | Status |
|---|---|---|
| 01 | `issues/01-hardware-verification.md` | ready-for-human |
| 02 | `issues/02-wired-kind-and-enumerator.md` | needs-info (blocked by 01) |
| 03 | `issues/03-wired-sink.md` | needs-info (blocked by 02) |
| 04 | `issues/04-popover-rows-and-drawer.md` | needs-info (blocked by 03) |
| 05 | `issues/05-routing-scope.md` | needs-info (blocked by 03) |
| 06 | `issues/06-this-mac-plays-on-built-in-with-dac-default.md` | needs-triage |

## Done means

- A Mac with headphones in the jack and a display with speakers attached shows
  "This Mac" (the default), plus one row each for the others; plugging and
  unplugging updates the list; the default's own row never duplicates "This Mac".
- Speakers + headphones + one Sonos selected together play in time (owner's
  ear, then the passive drift sampler shows no widening baseline); trim moves
  the headphones.
- An app routed to the headphones plays only there; a saved group naming them
  restores it; the companion snapshot lists it with the right flags.
- USB is confirmed on the first USB audio output that turns up (ticket 01).
- Tests stay invisible; `run-tests.sh --filter`, never bare `swift test`.
