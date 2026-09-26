# 04 — Mixer rows, glyphs, and the sync drawer for wired outputs

Status: needs-info
Blocked by: 03; owner answers to the spec's open questions (placement, glyphs,
lone-selection rule)

## Change

- `PopoverController`: list `.wired` rows in the agreed section; the row
  matching the default is never listed (enumerator already drops it, but the
  ingest guards too). Selected-then-unplugged → deselected on the edge.
- Sync drawer / trim store / wizard: generalise the "Bluetooth row" gates in
  `PopoverController+SyncDrawer.swift`, `PopoverController+BTWizard.swift` and
  `BTTrimStore` to "locally rendered sink" (BT or wired), keyed by UID. The
  measured-latency path (mic probe) must work for a wired row; the by-ear
  questions too. Chip copy: a never-aligned wired row's chip is the wizard door.
- Glyph per transport, template SF Symbols; no custom assets.
- Analytics: `wired:row_selected` / `wired:row_deselected` (properties:
  `transport` enum string, `selected_count`), `bt_sync:*` events reused for the
  drawer with a `transport` property added — register in
  `audiout-shared/docs/analytics-events.md` first.

## Tests

- Row visibility and swap on default change (PopoverDeviceVisibilityTests row).
- Drawer opens for a wired row; trim persists by UID; tests stay invisible.
