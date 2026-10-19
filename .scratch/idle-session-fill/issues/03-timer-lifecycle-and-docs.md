# 03: Run the fill live on the engine thread

**What to build:** In the running app the fill happens by itself: an 8 ms persistent timer on the engine's event base, created and destroyed with the shim's existing deferred-dispatch event so it lives exactly as long as the engine runs. The stale cadence comment in the Swift engine is corrected, and the shim folder's agent notes gain one rule line: the fill lives in the shim and bypasses the Swift write guards.

**Blocked by:** 02 (the tick it drives).

**Status:** ready-for-agent

- [ ] Timer created in dispatcher init and freed in dispatcher deinit; engine start/stop brackets it; no leak on stop/start cycles.
- [ ] Headless test mode is unaffected (no event base, so no timer; the test seam still works).
- [ ] Cadence comment corrected; shim agent notes updated.
- [ ] Full AirPlayEngine suite passes with a "Test run with N tests" line.
