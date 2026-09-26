# 02 — `Device.Kind.wired` and `WiredOutputEnumerator`

Status: ready-for-human (built 2026-09-26; live check owed)
Blocked by: 01

## Change

- `Device.swift`: add `case wired` with doc, `isWired`, symbol per transport
  (decide glyphs with the owner; SF Symbols only), `isDiscoveredOverLocalNetwork
  == false`. Every exhaustive switch on `Kind` in Core and UI gets its arm.
- New `WiredOutputEnumerator.swift` (licence-clean header style, Core Audio
  only). Seam protocol `WiredOutputEnumerating` mirroring `BTDeviceEnumerating`
  (`onSnapshot`, `start`, `stop`, `refresh`) so tests feed snapshots with no
  HAL. Pure, unit-tested filter:
  keep `hasOutputStreams` and transport ∉ {Bluetooth, BluetoothLE, AirPlay,
  Virtual, Aggregate, AutoAggregate, Unknown}; drop UID ==
  `AggregateOutputDevice.productUID`; drop the current default output's UID,
  resolved through our aggregate to its sub-device when the aggregate is default.
  Listeners: `kAudioHardwarePropertyDevices`, `kAudioHardwarePropertyDefaultOutputDevice`.
- `NativeBackend`: surface snapshots as `Device(kind: .wired)` rows
  (`deviceAdded`/`deviceUpdated`/`deviceRemoved`), never into `outputIDs`,
  never into `engine.updateDiscovery`. An unplugged output's row stays greyed
  while used (selected, app-routed, or a saved-group member) and is removed
  once unused; replug restores it; the popover's deselect-on-loss edge stays
  Bluetooth-only.
- `MockBackend`: two wired fixtures (a "USB Audio DAC", an "External
  Headphones") so `run-app.sh` shows the rows offline.

## Tests (name the defect each catches)

- Filter table: each excluded transport, the aggregate UID, the default's UID.
- Default-change swap: the hidden row changes when the default UID changes.
- Snapshot → `Device` mapping keeps the UID as `id`.
- `NativeBackendWiredDevicesTests`: `usedUnpluggedRowStaysGreyedUntilReleased`,
  `groupMemberUnpluggedRowStaysUntilGroupReleasesIt`, and
  `replugRestoresAvailability` cover the keep-used-rows-greyed behavior
  (ticket 02b).
