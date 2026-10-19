# Why an EQ change silences an AirPlay speaker for ~2 s, and how other apps avoid it

Research brief, 2026-09-15. Three sub-agents: a code trace, a telemetry check, and a
primary-source survey of other EQ apps. Owner's report: every EQ gesture on a speaker costs
about 2 s of silence, sometimes more; mostly AirPlay, Bluetooth much less.

## Verdict

The silence is a **full AirPlay session restart**, not filter cost. An EQ edit that the
speaker's current engine stream cannot carry moves the speaker to another stream, and a
stream move is `unbind` then `bind`: RTSP TEARDOWN, SETUP, RECORD, a new clock anchor and a
new RTP timeline (`NativeBackend.swift:3300-3303`, `:3324-3326`, `:6706-6714`;
`AirPlayEngine.swift:842-853`). The receiver plays on a negotiated lead of up to 88 200
frames = 2.0 s at 44.1 kHz (OwnTone `airplay.c:2628-2629`, `latencyMax 88200`), so the
restart throws that queue away and refills it from empty. On top comes the sender's own
750 ms scheduling lead at the default 1000 ms start buffer (`AirPlayEngine.swift:68-71`,
`AppSettings.swift:127-130`). Measured fresh-session click-to-sound in this repo: ~2.2 s at
1000 ms, 3.5 s at 2250 ms (`OwnToneBackend.swift:903-912`, `AirPlayEngine/docs/latency-analysis.md:3-20`).
The owner's Mac has no start-buffer override, so 1000 ms applies: that is the ~2 s.

The trigger is the `stream != 0` guard in `eqEditIsExpressibleLocked`
(`NativeBackend.swift:3325`). A flat speaker sits on the shared stream 0, so:

- the first drag frame away from flat rebinds (drag frames are unthrottled, one `setEQ`
  per mouse move, `EQEditorView.swift:644-658`);
- Reset back to flat rebinds;
- a speaker with a saved curve rebinds **twice** on connect: `convergeDevice` binds it to
  stream 0 (`:7104`), then `reconcileEQPlan` moves it to its EQ stream (`:7155-7158`);
- editing one of two speakers that share a curve rebinds **both**, because
  `EQStreamAllocator` keys on the member set (`DeviceEQ.swift:120-126`).

Once a lone speaker owns its own stream, further drag frames only retarget coefficients
in place (`pushEQPlanLocked` → `EQProcessor.retarget`, `:3455-3475`,
`EQProcessor.swift:109-113`) and are instant. So it is not literally every gesture, but
every gesture that starts from flat, every Reset, and every connect.

"Sometimes longer": a rebind refused because the device is already `converging` is
deferred and re-driven later (`:3519-3528`, `:7010-7012`); all bind ops serialize on
`bindTail` (`:3535-3537`), so two speakers pay 2 s each in turn.

Bluetooth never enters this path (`:3286-3289`): it swaps a processor on `graphQueue`.
Its only artefact is a click from zeroed filter memory, roadmap 057. Main Out EQ is one
stage over the mix and never rebinds. The mock backend stores the value only, so this is
native-only.

## Proof from the owner's own session tonight

`~/Library/Logs/Audiout/telemetry.jsonl`, session `43BDE00B…`, Audiout 1.2.0 build 1815
(the `/Applications` copy), 2026-09-14 23:55 UTC, Sonos Move 2 (`C4:38:75:0E:BF:4A`):

```
23:55:21.939 connect_requested
23:55:22.868 eq_rebind stream=2147483648 → engine_scope_rebind from=0 to=2147483648   (saved curve: second session on connect)
23:55:26.943 send_sched gap_max_ms=1803.9                                             (send loop stalled 1.8 s in this window)
23:55:30.460 eq_rebind stream=0          → engine_scope_rebind from=2147483648 to=0   (back to flat: Reset)
23:55:34.846 eq_rebind stream=2147483648 → engine_scope_rebind from=0 to=2147483648   (first drag frame away from flat)
23:55:35.297 eq_rebind_deferred reason=already_converging, then eq_rebind, no engine line (re-drive was a no-op)
```

Three real session restarts in 13 s, one per flat/shaped crossing. `eq_rebind_failed` and
`eq_save_failed`: zero. PostHog, 14 days: `eq:adjusted` 93 (all `target=device`, 10 from
internal machines, 8 today), `eq:opened` 43, `eq:reset` 9. No exception mentions EQ.

What the log cannot show: no event marks "the receiver is making sound again", `eq_rebind`
has no completion timestamp, and `stream_health.silent_s` polls every 5 s and only sees
the Mac's outbound signal. The 2 s figure rests on the latency analysis and the owner's
ear, not on a direct measurement.

## How other apps do it

Every app that gets this right keeps one long-lived filter and writes parameters into it.

- **eqMac**: one `AVAudioUnitEQ` permanently attached to a running `AVAudioEngine`; a
  slider write is `band.gain = Float(gain)`, nothing else.
  https://github.com/bitgapp/eqMac/blob/master/native/app/Source/Audio/Effects/Equalizers/Equalizer.swift
- **EasyEffects** (LSP parametric EQ): a UI change writes one LV2 control port; the plugin
  interpolates old→new gain/freq/Q in 32-sample chunks across the buffer and never resets
  filter state. Filter *type* changes are a hard swap, gain drags are smoothed.
  https://github.com/lsp-plugins/lsp-plugins-para-equalizer/blob/master/src/main/plug/para_equalizer.cpp (`:40`, `:1211`, `:1290-1325`)
- **JUCE**: coefficients are a ref-counted object you swap; `reset()` is required only when
  the filter *order* changes, and reset is exactly what clicks.
  https://github.com/juce-framework/JUCE/blob/master/modules/juce_dsp/processors/juce_IIRFilter.h
- **Apple's own primitive**: `vDSP_biquadm_SetTargetsDouble` sets coefficient targets and
  `vDSP_biquadm` walks toward them per sample, no allocation, no state loss.
  `vDSP_biquadm_CreateSetup` zeroes all delay elements, so re-creating it per change is the
  click. https://developer.apple.com/documentation/accelerate/vdsp_biquadm_settargetsdouble
- **AirPlay**: nothing in a session describes audio content (transport, keys, clock anchor,
  format, packet size only), so filtering PCM before the encoder is invisible to the
  receiver. OwnTone flushes only for pause/stop, never for a sample change.
  https://github.com/owntone/owntone-server/blob/master/src/outputs/airplay.c (`:2620-2635`, `:4187`);
  https://openairplay.github.io/airplay-spec/audio/rtsp_requests/setup.html
- Rogue Amoeba and Boom 3D publish no mechanism, only that changes apply while audio
  flows. Unverified beyond that.

## The fix

Already scoped as **roadmap 056** ("Remove the ~1s EQ stream-rebind gap"). The original
work order was lost with its scratchpad; this note re-scopes it. Tracks:

- **A, unconditional**: let a lone AirPlay speaker shape stream 0 in place (drop the
  `stream != 0` guard at `:3325`, a lone-device rule in `EQStreamTopology.resolve`, a
  stream-0 processor in `pushEQPlanLocked`), and bind straight to the final stream at
  connect (`:7104`). Invariant to keep: a flat EQ stays byte-identical passthrough, so
  stream 0 keeps `processor: nil` while flat. Kills the gap for the one-speaker case and
  the double session on connect.
- **B, gate**: raise `OUTPUTS_MAX_QUALITY_SUBSCRIPTIONS` 5→15 and the stream cap 6→16, then
  benchmark 16 ALAC streams × 30 s headless; pass = real-time factor ≤ 0.25.
- **C, only if B passes**: one permanent stream per speaker. Deletes `EQStreamTopology`,
  `EQStreamAllocator`, `reconcileEQPlan`'s rebind machinery and the shared-curve split bug.

Two additions from this research:

- Drive `setEQ` from every drag value but coalesce to one publish per audio buffer;
  today each mouse move goes straight through.
- Consider `vDSP_biquadm_SetTargetsDouble` for the retarget ramp instead of the current
  try-lock mailbox swap, if the swap is ever audible. Not required for the gap.

Bluetooth's click is roadmap 057 (call `EQProcessor.retarget` instead of building a new
processor in `BTDeviceSink.setEQ`).

## Side findings

- The EQ stream logged `peak_dbfs=-0.0` all session while stream 0 sat at −2.1 dBFS:
  the shaped stream is hitting full scale. `EQProcessor` clips after filtering
  (widen → filter → clip → requantize), so a boost with no headroom distorts. Out of
  scope here; worth its own ticket.
- To measure the gap directly, stamp `eq_rebind` with a completion time and trigger a
  `stream_health` sample on rebind instead of the flat 5 s cadence.
