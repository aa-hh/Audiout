# 03 — A pinned synced sink per selected wired output

Status: needs-info
Blocked by: 02

## Change

- Decide: reuse `BTDeviceSink`/the BT sink manager under a transport-neutral
  name, or a sibling built from the same licence-clean pieces (`SyncCore.swift`
  ring/resampler/`PhaseController`). Either way: pinned via
  `outputNode.auAudioUnit.setDeviceID` BEFORE first start, aggregate/virtual
  transports refused, nominal-rate listener rebuilds, sleep/wake rebuild.
  Never copy from the GPL `SyncedLocalSink.swift`.
- Feed: the same fan-out the Bluetooth manager reads in
  `NativeCaptureCoordinator` (44.1 kHz airplay feed; the sink bridges to the
  device rate itself). Wizard tick variants: wired rows take the tick-ONLY
  variant (they do not power-gate), like the synced-local fan-out.
- Delay: `SyncTiming.totalDelayNanos` with `presentationDelayMs` = the live
  room reference, `deviceOffsetMs` = `LocalOutputLatency.measure(deviceID:)`
  (re-read on rebuild), `trimMs` from the generalised trim store (ticket 04).
- Composition: add the wired term to `BTGroupComposition` (or rename it); a
  wired-only or wired+BT selection keeps the host-clock reference with the
  BT-only buffer; AirPlay/Cast present → presentation reference.
- Selection plumbing: `setOutputSet` arms/disarms wired sinks by UID the way
  `btSelectedUIDs` does; the meter for a wired row counts its sink's applied
  state, never the desired flag (the synced-local trap).
- Gain: `group × row fader × Main` as software gain; mute = 0.
- Telemetry: `Telemetry.log(.localPlayback, "wired_sink_*")` lines mirroring the
  `bt_sink_*` set; failures through `Telemetry.fail` with the UID in `local:`.

## Tests

- Delay math table per composition (extend the BT table, do not add a suite).
- Arm/disarm follows the output set; a vanished device stops its sink.
- Aggregate transport refused.
