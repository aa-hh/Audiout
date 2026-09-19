# 10 — DefaultOutputDeviceMonitor: stop leaking one DispatchWorkItem per notification

Status: ready-for-agent
Wave: 2
Pipeline model: opus mode
Source: [REVIEW.md](../REVIEW.md), findings capture #2

`scheduleTrailingFanout` builds a `DispatchWorkItem` whose block captures the item itself, so the pair never deallocates; one per default-output/rate notification.

## Done when

The block no longer references `item` (a cancelled `DispatchWorkItem` already skips its block). A test proves a scheduled-then-cancelled fanout item is released.

## Test seam

`DefaultOutputDeviceMonitorTests`

## Verification

```bash
bash scripts/run-tests.sh --filter DefaultOutputDeviceMonitor
```

## Findings (verbatim from the area reports)

### 2. [BUG] `DefaultOutputDeviceMonitor` leaks one `DispatchWorkItem` per notification (retain cycle)
- Where: `DefaultOutputDeviceMonitor.swift:383-395`
- Evidence: `var item: DispatchWorkItem!; item = DispatchWorkItem { [weak self] in guard let self, !item.isCancelled else { return }` — block captures `item` strongly, item owns block.
- Why: one per default-output/rate notification (BT connect burst = four per connect), on the single process-wide monitor.
- Fix: drop the `!item.isCancelled` check (DispatchWorkItem already skips a cancelled block).
- Confidence: high
