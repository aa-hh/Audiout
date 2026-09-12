# 02: Idle silence fill in the sender shim, proven headless

**What to build:** A bound AirPlay session that the host has not written to for 100 ms receives silence from the shim at exactly real-time rate, for every stream that has a connected or streaming device, and stops the moment the host writes again. Delivered together with the test-only seam (run one fill cycle at a given time, returning samples written; read a stream's last delivered end time) and a new hermetic suite driving it under headless mode with real master sessions. Do it test-first at that seam.

**Blocked by:** None (can start immediately). Independent of 01 (different files).

**Status:** ready-for-agent

- [ ] Per-stream bookkeeping (last host write time, last delivered end time) is stamped by the shim's broadcast write and never by the fill.
- [ ] Stream selection comes from the shim's own device registry (live session, state connected or streaming), one entry per distinct stream id, with the device's quality.
- [ ] Owed samples = ((now − one packet) − end time) floored to whole packets, capped at 32 packets per cycle; end time advances by exactly what was written; an unknown idle stream seeds at now − one packet.
- [ ] The fill calls the two senders' write functions directly; nothing passes through the Swift write guards or telemetry.
- [ ] New suite with four cases: no fill within 100 ms of a host write; samples owed by elapsed time including a second consecutive tick; no fill for a stream without a connected device; a host write stops the fill on the next tick. Each test names the defect it catches.
- [ ] Multi-stream routing, write-backlog and shim unit suites still pass; every run shows a "Test run with N tests" line.
- [ ] No vendored sender file changes.
