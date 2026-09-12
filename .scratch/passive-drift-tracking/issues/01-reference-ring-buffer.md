# 01 — Retain recent outgoing audio as the correlation reference

Status: ready-for-agent

Keep a rolling history (~15 s) of the post-fan-out PCM with its monotonic pts so a
mic capture taken moments later can be correlated against what was actually sent.

- Hook point: `NativeCaptureCoordinator.deliver` (`:1847` at time of writing) —
  today each block is written to sinks and dropped.
- Retain the Bluetooth-bound variant (what the BT speakers actually got, i.e. the
  `bedded`/split output when active, plain pcm otherwise) plus pts per block.
  One shared buffer is enough while all BT sinks get identical bytes; keep the
  door open for per-sink buffers (the split fan-out already produces variants).
- Ring buffer, fixed allocation, no locks on the audio path beyond what `deliver`
  already holds; readers (the sampler, ticket 03) snapshot asynchronously.
- Off by default; armed only while tracking or a re-sync capture is active, so
  the steady-state pipeline cost is zero.

Done when: a test proves that after N delivered blocks, a reader can pull a
contiguous [t0, t1] slice with sample-accurate pts, and that arming/disarming
does not disturb delivery.
