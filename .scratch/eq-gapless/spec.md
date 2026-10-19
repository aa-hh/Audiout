# EQ without the AirPlay gap — roadmap 056 (+ 087 headroom)

Owner ruling 2026-09-15: build all three tracks of roadmap 056, measure first; and fix
the EQ clipping (087) in the same session. Research and evidence:
`dev/notes/eq-live-apply-latency-research-2026-09-15.md`.

## Problem

Every EQ change that crosses flat↔shaped moves the speaker between engine streams.
A stream move is `engine.rebindOutput` = unbind + bind = a fresh AirPlay session, and
the receiver's ~2 s negotiated lead is thrown away (`NativeBackend.swift:3325`
`stream != 0` guard; `:6706-6714`; `AirPlayEngine.swift:842-853`). Proven from the
owner's own log (three `engine_scope_rebind` lines in 13 s, one per crossing).

## Design

Topology must never change on an EQ edit. Every AirPlay speaker binds to its own
permanent whole-system stream at connect, and an edit only retargets that stream's
`EQProcessor` in place (the mailbox path that already exists). The stream cap goes
6 → 16 to afford one stream per speaker, gated on a headless encode benchmark.

Order (serial in this worktree, except 01 which is its own worktree from main):

| # | Ticket | Gate |
|---|---|---|
| 01 | `issues/01-eq-headroom.md` — 087, makeup headroom | REJECTED at the live test: an auto-trim makes a boost quieter, never louder |
| 02 | `issues/02-stream-cap-and-encode-gate.md` — caps 6→16 + `MultiStreamEncodeLoadTests` | reports RTF |
| 03 | `issues/03-one-stream-per-device.md` — Track C, or Track A fallback | C if RTF ≤ 0.25, else A |

## Invariants (from AudioutCore/Sources/AudioutCore/AGENTS.md, keep every one)

- A flat EQ stays byte-identical passthrough: a flat device's stream entry has
  `processor: nil` and shares the `enginePCM` Data (no copy, no filter).
- No live `EQProcessor` is ever rebuilt for a value change; `retarget(to:)` only.
- A device the per-app domain claims (`streamBindings[id] != nil`) is outside the
  whole-system EQ domain and says so through `eqBypassReason = .perAppRouting`.
- Every whole-system session-establishing engine op goes through `bindOutput`, which
  arbitrates on the engine's own `boundStreamId` answer.
- Bluetooth never enters this path (`setEQ` branches at `:3286-3289`).
- Tests stay invisible; `run-tests.sh --filter`, never bare `swift test`; trust only a
  `Test run with N tests` line.

## Done means

- 01, 02, 03 merged to main via PR after adversarial review (never skip: ticket 17 of
  passive-drift shipped green tests with 10 real defects).
- Live check on the owner's Sonos: drag a band from flat, Reset, reconnect with a saved
  curve — no gap on any of them. `engine_scope_rebind` must not appear in
  `~/Library/Logs/Audiout/telemetry.jsonl` during the test.
- `AudioutCore/Sources/AudioutCore/AGENTS.md` EQ rules rewritten to the new shape;
  old paragraphs already live in AGENTS-HISTORY.md.
