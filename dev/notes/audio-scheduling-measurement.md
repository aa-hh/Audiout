# Audio Scheduling Measurement Protocol

**Status:** Template for human-in-the-loop measurement. This is NOT an automated test.
**Owner:** Alec (manual execution)
**Related plan:** `docs/plans/PLAN-AUDIO-THREAD-SCHEDULING.md`, tasks T10 and T17

---

## Overview

This protocol measures whether Stage 1 scheduling fixes improve stutter under CPU load. The measurement discriminates among three hypotheses:

- **H1:** Send-thread starvation (control thread blocked under load)
- **H2:** Capture-side underrun (tap IOProc missing cycles or locked on F12 contention)
- **H3:** Sync-packet drift (sync packet send latency degrades receiver scheduling)

The measurement gate (T10) **decides whether Stage 2 (real-time send thread) is needed at all**. Read the results mechanically from the table; this is not a judgment call.

---

## Preconditions

**Machine state:**
- Quiet system. No other demanding workloads (browsers, IDEs, etc.).
- **Critically important:** Do NOT run `swift test` during this measurement. The test suite itself is a known CPU load source on this machine. See `docs/plans/PLAN-AUDIO-THREAD-SCHEDULING.md` §H.8.
- Real AirPlay receiver connected and ready to play (e.g., Sonos speaker).

**App state:**
- Build the app from this worktree: `swift build` in the root.
- Launch the app normally. Wait for it to stabilize (taps active, UI responsive).
- Ensure audio is routing to the AirPlay receiver (confirm in UI or by listening).

**Baseline state:**
- Machine idle (load average near 0.5–2.0 on an 8-core system).
- No audio playing initially.
- Terminal or log viewer ready to capture output.

---

## Measurement Protocol

### Phase 1: Idle Baseline

1. Ensure the app is running and audio path is ready (no audio playing yet).
2. Record machine idle state:
   ```bash
   uptime  # Note the load average
   ```
3. Start audio playback to the AirPlay receiver (any content, sufficient to hear audio quality).
4. Listen for ~30 seconds. **Note:** Is audio clear, or does it crackle/stutter?
5. Record idle audio quality: **clear** / **slightly crackling** / **stuttering**.
6. If collecting metrics: capture the probe output (stderr or logs) for 30 seconds to establish idle baseline metrics (p50/p95/p99/max wake latency, inter-arrival gap, in-cycle work time). Metric families are defined in task T1.

### Phase 2: Loaded Baseline (Before Stage 1 Fixes)

*This phase establishes the problem. Repeat Phase 1 under load, then apply Stage 1 fixes and re-run.*

1. Stop audio playback (or keep it running; the test will overlay load).
2. In a new terminal, spin up CPU load:
   ```bash
   bash scripts/load-gen.sh 16 30
   ```
   This starts 16 CPU spinners for 30 seconds, reproducing observed load average of ~16.

3. **While load is running**, resume audio playback to the AirPlay receiver.
4. Listen for the full duration of the load. **Note:** Is audio clear, slightly crackling, or stuttering?
5. Record loaded audio quality: **clear** / **slightly crackling** / **stuttering**.
6. If collecting metrics: capture probe output during the entire 30-second load window.
7. Let load-gen.sh exit cleanly. Wait ~30 seconds for system to idle.

### Phase 3: Idle Baseline (After Stage 1 Fixes)

Repeat Phase 1 identically, now with Stage 1 fixes applied.

### Phase 4: Loaded Baseline (After Stage 1 Fixes)

Repeat Phase 2 identically, now with Stage 1 fixes applied.

---

## Results Table

Fill in after all four phases complete. Each row represents one measurement pass.

| Phase | Load | Audio Quality | Wake Latency p50 (µs) | Wake Latency p95 (µs) | Wake Latency p99 (µs) | Wake Latency max (µs) | Inter-Arrival Gap p50 (ms) | Inter-Arrival Gap p99 (ms) | In-Cycle Work p99 (µs) | H1 Send Starvation? | H2 Capture Underrun? | H3 Sync Drift? |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Idle (before fixes) | None (idle) | [clear/crackle/stutter] | — | — | — | — | — | — | — | — | — | — |
| Loaded (before fixes) | 16 spinners | [clear/crackle/stutter] | | | | | | | | [Y/N/maybe] | [Y/N/maybe] | [Y/N/maybe] |
| Idle (after fixes) | None (idle) | [clear/crackle/stutter] | — | — | — | — | — | — | — | — | — | — |
| Loaded (after fixes) | 16 spinners | [clear/crackle/stutter] | | | | | | | | [Y/N/maybe] | [Y/N/maybe] | [Y/N/maybe] |

### Interpreting the Results

**Wake latency** (captured by task T1's probe):
- Measured from the instant the tap IOProc is called until the control thread's write closure begins execution.
- High values under load suggest the control thread is being starved (H1).
- Large improvements after fixes suggest H1 was the issue.

**Inter-arrival gap** (captured by task T1's probe):
- Time between consecutive write() calls at the engine's entry point.
- Spikes or large gaps under load suggest the capture side is missing IOProc cycles (H2).
- Improvements after F12 lock fix (task T8) would point to H2.

**In-cycle work time** (captured by task T1's probe):
- Time spent inside the write closure from entry to exit.
- Establishes the baseline for the real-time send thread's computation budget (task T14).

**Hypothesis scoring:**
- **H1 dominates** if wake latency is high (>5 ms) under load and improves significantly after fixes.
- **H2 dominates** if inter-arrival gap shows dropped cycles under load and improves after the F12 lock fix.
- **H3 dominates** if sync-packet delivery is delayed but wake latency and inter-arrival gap are acceptable.

### Decision Gate (T10)

**Does H1 dominate (send starvation)?**
- **Yes:** Stage 2 (real-time send thread) proceeds as planned. Dispatch tasks T11–T14 after this measurement.
- **No:** H2 likely fixed the problem. Document which hypothesis won, and defer Stage 2 pending further investigation.

---

## Notes

- This is a **human-in-the-loop measurement**, not an automated test. The steps must be executed manually, and audio quality assessment is subjective but valid (stuttering is unmistakable).
- Metrics are provided by task T1's scheduling probe. The probe reports `p50/p95/p99/max` for wake latency, inter-arrival gap, and in-cycle work time.
- Measurement must be performed on the same quiet machine each time (typically Alec's live system) to avoid noise from other workloads.
- If the system stutters even at idle after fixes, investigate whether other unrelated issues have been introduced (e.g., regression in capture or encoding).
- The load generator (`scripts/load-gen.sh`) is reproducible across runs. If you need to vary load, adjust the N parameter.

---

## References

- `docs/plans/PLAN-AUDIO-THREAD-SCHEDULING.md` — full plan with hypothesis definitions and background
- `scripts/load-gen.sh` — load generator script
- Task T1 — scheduling probe that provides the metric families
- Task T10 — this measurement (human gate, no automation)
- Task T17 — final A/B measurement after all fixes land
