# Popover (Mixer) performance baseline

Measured against the real `PopoverController` + `MockBackend`, headless, on
the owner's MacBook Pro. **No code was changed as a result — nothing on the hot path
is slow.** This note exists so the next person doesn't re-derive it.

Reproduce with a throwaway `@Suite` in the test target driving
`claimPanelForSurfaceHosting()` / `rebuildForOpen()` / `update(devices:)` /
`test_pushLevel(_:for:)`, timed with `DispatchTime.now().uptimeNanoseconds`.

## Steady state — all cheap, none of it rebuilds

| path | cost | rebuilds triggered |
|---|---|---|
| `test_pushLevel` per row | 0.0002 ms | — |
| one metering tick, 8 rows | 0.002 ms | — |
| `update(devices:)`, identical snapshot | 1.4 ms | **0** |
| `update(devices:)`, connection-state change | 1.4 ms | **0** |
| `update(devices:)`, volume change | 1.4 ms | **0** |
| `update(devices:)`, device appears/disappears | — | 1 (correct) |

The change test in `update(devices:)` and `refreshDeviceRows()` are doing their
job: the two highest-frequency real changes — a connect sweep walking every
member through `.connecting` → `.connected`, and a slider drag — cost 1.4 ms and
rebuild nothing. Metering is effectively free. **Don't "simplify" either gate.**

## Rebuild — linear, and the only number worth watching

`rebuildForOpen()`, release build, autorelease pool per iteration:

| fleet | rebuild | per row | growth vs previous |
|---|---|---|---|
| 4 | 20.1 ms | 4.02 ms | — |
| 8 | 32.6 ms | 3.62 ms | 1.62× |
| 16 | 58.7 ms | 3.46 ms | 1.80× |
| 32 | 110.0 ms | 3.33 ms | 1.87× |
| 64 | 216.5 ms | 3.33 ms | 1.97× |

**Linear.** Growth stays under 2.0× per doubling and per-row cost falls, then
flattens at ~3.3 ms — fixed overhead amortising, not a superlinear term. Roughly
2 ms of each row is `DeviceRowView`'s own construction; re-applying an existing
row instead costs 0.27 ms, so a row-recycling rebuild is theoretically ~7×
cheaper per row. **Not worth it at the scale this ships at**, and it would break
the "rows aren't mutated in place after a structural change" invariant that a
dozen trap comments in `AGENTS.md` depend on. SF Symbol lookup is 0.03 ms; a
symbol cache would buy ~6%, also not worth it.

One open costs ONE rebuild. Verified by counting: the claim, identical backend
re-announces, and connection-state changes add none.

At household scale (≈8 speakers) an open is **~33 ms**, comfortably inside the
~100 ms "instant" threshold. It crosses 100 ms at about **32 discovered
devices** and reaches 216 ms at 64 — and AirPlay discovery is network-wide, so
an office or apartment building can plausibly surface that many. That is the
trigger to revisit, and it is the same territory roadmap 039 (popover overflow
when content grows) already covers.

## Measurement trap

A first pass reported 2.57× growth per doubling — a false O(n²). The probe was
looping without an `autoreleasepool`, so thousands of discarded row views piled
up and allocation slowed as the loop ran. **Wrap every iteration in
`autoreleasepool` when timing anything that builds AppKit views**, or the
measurement invents a superlinear term that isn't there.

Two other things that looked like leads and were not: batching the per-row
`NSLayoutConstraint` activation is no faster than activating each (attach is
~6 ms of 188 ms at 64 rows), and a single full Auto Layout solve over the stack
is linear (≈2.1× per doubling).
