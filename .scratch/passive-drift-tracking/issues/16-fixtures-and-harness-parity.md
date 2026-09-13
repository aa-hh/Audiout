# 16 — Fixtures for ProbeKit, and a Python harness that matches the Swift score

Status: planned
Blocked by: (none)

Turn dumped mic windows into small test fixtures, prove the Python harness scores them like the Swift correlator, and say how the labelled set gets recorded.

- **Fixture format.** The four raw windows in `.scratch/passive-drift-tracking/windows-2026-09-13/` are 5.1 MB for four (Float32, 44.1 kHz reference / 48 kHz capture). Store instead: band-limited 200 Hz–8 kHz, resampled to 24 kHz (the rate `PassiveDriftCorrelatorTests.swift` already uses, and enough for the 1–8 kHz treble band that resolved window 1), Int16 little-endian, whole 4 s window kept — trimming the reference to the 400–700 ms arrival region saves little on a 4 s window and would break a full-range check. About 190 KB per signal, 380 KB per window pair.
- **Size budget: 5 MB for the whole tracked set** (audiout-shared is MIT and git-tracked), so roughly a dozen windows. Garbage costs nothing extra: pair one window's reference with another window's capture in the test.
- **Naming:** `<stamp>-<label>-{ref,cap}.i16` plus the existing `-meta.json` (referenceRate, captureRate, baselines with uid/expectedDelayMs/anchor), extended with `label` and, for a forced jump, `trueDelayMs`. Labels: `good`, `garbage`, `noise`, `jump+40`.
- **Loader:** one small helper in `Tests/ProbeKitTests/` reading the pair and the sidecar. `Package.swift:27` needs `resources: [.copy("Fixtures")]` on the ProbeKitTests target — it has none today.
- **Parity check.** Add a fixture-reading mode to `dev/drift-window-analysis.py` so both sides consume the identical samples, and a Swift test that prints the correlator score. Harness plain-filter score must land within 5 % of Swift's on every fixture.
- **Recording the labelled set next live session:** 10+ known-good windows at normal level, pinned by one loud window accepted at ≥ 3.5 before and after; one forced jump by changing a single speaker's trim by exactly +40 ms (a trim change is a ring seek, so the true answer is known); both speakers muted at their own buttons for garbage; near-field noise at the Mac (window 2 of live test 3 is already one).
- Today's gate is a public var: `PassiveDriftCorrelator.swift:117` defaults `minPeakToSidelobe` to 3, and `AudioutCore/Sources/AudioutCore/PassiveDriftSampler.swift:104` sets 2.3. Fixtures are what let later tickets move that number on evidence.
- **Numbers later tickets are measured against** (ensemble brief §6): ≥ 90 % of known-good windows accepted, 0 of 40 garbage accepted, accepted error RMS ≤ 1 ms, the forced jump read within 2 ms in the first accepted window after it.

Done when: `bash scripts/run-tests.sh --filter PassiveDriftCorrelatorTests` loads all four fixtures, and the harness run over the same fixtures prints a per-window score within 5 % of the Swift score.

## Comments

- 2026-09-13: drafted from live test 3 (HANDOFF.md) and dev/notes/drift-ensemble-design-brief.md §4.
