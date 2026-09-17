# Mixer device row: make selection visible, then delete its stand-ins

Status: ready-for-agent
Closes: A1, A5, A6, A7, A10

- **A1 (P1)** `DeviceRowView.swift:2319, 3138-3153`, `PopoverController.swift:2312` —
  picking a speaker has no visible control. `InvisibleSwitchCell` paints nothing;
  three regions take the click, signalled only by a pointing-hand cursor, and the app
  ships a sentence to explain it ("Click a speaker's name to play your audio on it.").
  Give the row a resting difference that reads without hover, or restore a visible
  checkbox in the gutter with the rail drawn behind it; then delete
  `membershipHintText` and drop the pointing hand from the name and the gutter.
- **A5** `DeviceRowView.swift:3290-3339` — `flashRow()` has no caller outside its own
  test. Delete it or wire it to the event it was written for.
- **A6** `DeviceRowView.swift:974, 1005`, `MainOutRowView.swift:630` — filled engaged
  symbols are declared, catalogued and never drawn; the doc comments and DESIGN.md
  describe the filled version. Draw them or correct both records.
- **A7** `DeviceRowView.swift:3543`, `HaloRingView.swift:252` — a dashed stroke means
  "connecting" on the ring and "not set" on the Offset chip.
- **A10** `PopoverController.swift:3386-3387` — "Bluetooth pairings" is a disabled
  plain menu item where DESIGN.md's section-header rule applies.
