# 02 — `Device.Kind.wired` and `WiredOutputEnumerator`

Status: needs-info
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
  If ticket 01 shows an Intel data-source flip, the snapshot also carries the
  data-source name so one row can relabel instead of two rows appearing.
- `NativeBackend`: surface snapshots as `Device(kind: .wired)` rows
  (`deviceAdded`/`deviceUpdated`/`deviceRemoved`), never into `outputIDs`,
  never into `engine.updateDiscovery`. Removal on unplug; a selected row that
  vanishes is deselected on the edge in the popover, like Bluetooth.
- `MockBackend`: two wired fixtures (a "USB Audio DAC", an "External
  Headphones") so `run-app.sh` shows the rows offline.

## Tests (name the defect each catches)

- Filter table: each excluded transport, the aggregate UID, the default's UID.
- Default-change swap: the hidden row changes when the default UID changes.
- Snapshot → `Device` mapping keeps the UID as `id`.
