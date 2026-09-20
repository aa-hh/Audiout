# 08 — AppRowView: clear the slider drag flag on keyboard and VoiceOver changes

Status: ready-for-agent
Wave: 2
Pipeline model: opus mode
Source: [REVIEW.md](../REVIEW.md), findings popover #1

`AppRowView.volumeChanged` sets `isDraggingSlider` and only clears it on `.leftMouseUp`; a keyboard or VoiceOver change wedges it and the row ignores every later model push. `MainOutRowView.masterChanged` already carries the fix.

## Done when

`AppRowView` uses the same switch as `MainOutRowView` (`.leftMouseDown`/`.leftMouseDragged` → dragging, default → not). The `STABILITY(D4)` marker is removed here and the four docs that describe the marker scheme are updated to say none remain. A test drives `volumeChanged` with a non-mouse current event and proves a following `apply` repaints.

## Test seam

`AppRowViewTests` (or the popover Applications-card suite that already exercises `AppRowView`)

## Verification

```bash
bash scripts/run-tests.sh --filter AppRow
```

## Findings (verbatim from the area reports)

### 1. [BUG] `AppRowView`'s slider drag flag never clears after a keyboard or VoiceOver volume change; the row stops tracking the model for the session
- Where: `AudioutSharedUI/AppRowView.swift:718`, `:269`
- Evidence: `isDraggingSlider = true; if event?.type == .leftMouseUp { isDraggingSlider = false }` — carries a `STABILITY(D4)` comment naming the defect. `MainOutRowView.swift:689` already fixes it (clears on anything not a mouse drag); `DeviceRowView.swift:2261` installs a scoped mouse-up monitor.
- Fix: copy `MainOutRowView.masterChanged`'s switch into `AppRowView.volumeChanged`, delete the marker.
- Confidence: high
