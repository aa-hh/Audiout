# 09 — LevelMeterView: stop the display link when the view leaves its window

Status: ready-for-agent
Wave: 2
Pipeline model: opus mode
Source: [REVIEW.md](../REVIEW.md), findings popover #2

`LevelMeterView` stops its `CADisplayLink` only when the level eases to rest; a popover `rebuild()` discards rows mid-signal and the orphaned meter ticks forever, keeping itself and its row alive.

## Done when

`viewDidMoveToWindow` resets the meter and stops the link when `window == nil`, matching `MembershipBusView`, `HaloRingView` and `AlignmentStageView`. A test proves a meter with a non-zero target removed from its window has no running link and deinits.

## Test seam

`LevelMeterViewTests`

## Verification

```bash
bash scripts/run-tests.sh --filter LevelMeter
```

## Findings (verbatim from the area reports)

### 2. [BUG] `LevelMeterView` never stops its display link when it leaves a window; every `rebuild()` strands one
- Where: `AudioutSharedUI/LevelMeterView.swift:284`, `:302`, `:143`; `PopoverController.swift:1638`
- Evidence: link stops only when level eases to rest in `tick()`; no `viewDidMoveToWindow` override, while `MembershipBusView:218`, `HaloRingView:374`, `AlignmentStageView:1690` all have one. `rebuild()` discards rows; CADisplayLink retains its target so orphaned meters tick forever and `deinit` never runs.
- Fix: `override func viewDidMoveToWindow() { super…; if window == nil { reset() } }`.
- Confidence: high
