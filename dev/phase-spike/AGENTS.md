# dev/phase-spike

## Purpose

A throwaway feasibility harness measuring achievable phase-lock precision and
comparing rate-correction mechanisms. Disposable measurement code: it links
nothing shipping, and nothing here is vendored into the app.

## Rules

- `PlanMath` re-derives the shipping timing formula independently, so the two must be kept in step by hand.
- The real-device probe opens a genuine output cycle and can click a speaker relay; a human runs it.
- The offline suite never touches a real device, so host time is never valid there.
- Click detection compares against a theoretical bound, never a fixed threshold.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `PlanMath` → independent re-derivation of the release-placement plan, Monte-Carloed.
- `OfflineTimestampProbe` → offline graph proving host time is invalid there.
- `CorrectionProbe` → sweeps the stock rate-correction units for latency and clicks.
- `FractionalResampler` → the custom four-tap resampler this harness recommends.
- `RealDeviceProbe` → measures real per-cycle host-time jitter, silent by construction.
- `Stats` → dependency-free statistics, signal analysis and time helpers.
