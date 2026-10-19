# 04 — Keep the Bluetooth stream alive through silence

Status: resolved (built + reviewed 2026-09-12; live check owed)

Prevent the biggest jump instead of correcting it: a stream restart after silence
rolls a fresh 20–90 ms latency (`bt-latency-stability-research-2026-09-05.md:141-146`).
Feed silent frames to the Bluetooth sinks while the program is silent so the
stream never restarts.

- Scope: Bluetooth sinks only. AirPlay/engine paths keep their current behavior.
- Configurable (decision 4): on by default, with a timeout — after 10 min of
  continuous silence, stop and let the speaker idle; the next silence→audio edge
  then triggers a measurement window (ticket 03) instead.
- Settings surface: one switch + the timeout, in the device/sync area. Bare
  minutes field, no preset list (Alec's localization preference).
- Watch battery-driven speakers: some auto-off on silence regardless; the
  timeout is the mitigation, don't fight the speaker.
- Verify against the actual silence/suspend path in the pipeline first — find
  where the BT stream currently stops on program silence before assuming the
  mechanism.

Done when: with keep-alive on, a silence gap shorter than the timeout produces no
latency re-roll on resume (fake-speaker test asserting the sink saw continuous
frames); with it off or timed out, the resume edge fires the sampler trigger.

## Comments

- 2026-09-12 (wave 1 review fix pass): the Settings surface shipped as a bare-number
  minutes popup — the house pattern, following the wake-restore precedent — so the
  "no preset list" line above is superseded.
- The suspend mechanism (the `isSilence` flag) and the claim that keeping the stream
  up avoids a latency re-roll are both UNVERIFIED against real hardware; they are
  owed to the live real-music test.
- The silence→audio resume trigger is deferred to ticket 03.
