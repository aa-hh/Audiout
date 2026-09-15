# 02 — Raise the engine stream cap 6 → 16 and measure 16 parallel ALAC encodes

Status: built ffd89914; gate result rtf=0.038 on the mule (16 streams × 5 s in 0.19 s) → Track C
Worktree: this one (`claude/equalizer-latency-optimization-d714da`)

Why: one permanent stream per AirPlay speaker (ticket 03) needs more than 5 streams
beyond stream 0. The cost is one ALAC encode per stream instead of one per distinct
curve; this ticket measures it headlessly and reports the real-time factor (RTF =
wall seconds / audio seconds) for 16 streams.

## Caps

- `AirPlayEngine/Sources/CAirPlayEngine/shims/outputs.h:63`
  `#define OUTPUTS_MAX_QUALITY_SUBSCRIPTIONS 15`. `outputs.h` is an engine-owned shim,
  listed under "Sibling shim edits (NOT vendored)" in `AirPlayEngine/docs/VENDORED-DIFFS.md:147`,
  so no ledger entry. `struct output_buffer.data[]` is stack-sized from it (`:191`);
  17 entries is fine.
- `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:1375`
  `maxSimultaneousStreams = 16`; fix the numbers in its doc comment (`:1368-1374`).
- `AudioutCore/Sources/AudioutCore/NativeBackend.swift:606-609`
  `engineStreamCapacity = 16`, make it `static let` (internal, tests read it), and
  replace the comment: it mirrors `AirPlayEngine.maxSimultaneousStreams`, kept in step
  by hand because that constant is internal to the engine package; the shim it derives
  from is engine-owned, not vendored.
- `outputs.c:332` `IDLE_FILL_MAX_STREAMS 16`: read `idle_fill_entry_claim` (`:407`).
  If a 17th stream fails to claim gracefully (returns NULL and callers tolerate it),
  leave it; otherwise raise to 32 and say so in the commit.
- grep both packages' tests for anything that encodes 6/5: known one is
  `NativeBackendTests.budgetExhaustionBypassesTheDeterministicLoserWithoutBinding`
  (`:9437`), which builds 6 devices for a budget of 5. Make it build
  `NativeBackend.engineStreamCapacity` devices so the last one is the loser again.
  `EQStreamTopologyTests` pass the budget explicitly and need nothing.

## Benchmark test — `AirPlayEngine/Tests/AirPlayEngineTests/MultiStreamEncodeLoadTests.swift`

Model it on `MultiStreamWriteRoutingTests.swift` (same `SerializedEngineState`
nesting, same `init()` resets, same `AirPlayEngine()` + `await engine.enterHeadlessTestMode()`).
Headless mode runs `airplay_write` inline on the calling thread, and once a master
session holds ≥ 352 frames `airplay_write` drains it through `packets_send` →
`alac_encode` (`sender/airplay.c:4374-4380`, `:2183`) with no session attached, so the
encoder really runs.

1. Test seam to prove the encoder ran: add
   `uint32_t airplay_test_master_session_rtp_pos(const void *ams)` returning
   `((const struct airplay_master_session *)ams)->rtp_session->pos` next to the other
   `airplay_test_*` accessors (`airplay.c:~1255-1277`), declared in
   `shims/engine_bridge.h` beside them (`:142-155`). `pos` advances by
   `samples_per_packet` only on the success path (`rtp_packet_next` after a good
   `alac_encode`). `airplay.c` is vendored: mark the block
   `[AirPlayEngine vendored change 2026-09-15] TEST SEAM` like its neighbours and add
   a row to `AirPlayEngine/docs/VENDORED-DIFFS.md` in the same table the P2b seams use.
2. One `@Test func sixteenStreamsEncodeFasterThanRealTime()`:
   - `airplay_test_master_session_make(id, &q, false)` for ids 1...16 (quality
     44100/16/2 like the sibling test).
   - Program material: 352-frame interleaved S16 packets of a deterministic pseudo-random
     signal (LCG), not zeros or a pure sine — ALAC on silence is not a measurement.
     Pre-build ONE 352-frame `Data` and reuse it for every stream and packet.
   - 5 s of audio = 626 packets. For each packet: `engine.write(streams: entries, pts:)`
     with 16 entries (same Data, streamId 1...16) and `pts` advancing 352/44100 s.
     Time the loop with `ContinuousClock` (that is the encode cost; headless write is
     inline). Then `Task.sleep` 20 ms as the sibling does.
   - Assert every session's `rtp_pos == 626 * 352` (encode ran on all 16; a missing
     ALAC encoder would make `pos` stay 0 and the timing meaningless).
   - Print one line: `ENCODE_BENCH streams=16 audio_s=5.0 wall_s=<x> rtf=<x/5>`.
   - Assert `rtf <= 1.0`. That ceiling is a hang-stop, not a speed claim (repo rule:
     test deadlines never assert machine speed). Defect the test names in its comment:
     the cap raise letting 16 whole-system encodes fall behind real time.
3. Run: `AUDIOUT_TEST_PACKAGE=AirPlayEngine bash scripts/run-tests.sh --filter MultiStreamEncodeLoadTests`
   and `bash scripts/run-tests.sh --filter NativeBackendTests` (227 tests) and
   `--filter EQStreamTopologyTests`. Also `bash scripts/build.sh`.

## Report

Reply with the printed `ENCODE_BENCH` line verbatim, the `Test run with N tests` lines,
and which machine ran the benchmark (local or the mule — `run-tests.sh` says). The gate
for ticket 03 is `rtf <= 0.25`. Commit on this branch, push to origin, do not merge.
