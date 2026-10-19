# 02 — PTP helper: only the owning app may ask the root daemon to release

Status: ready-for-agent
Wave: 1
Pipeline model: fable (normal mode)
Source: [REVIEW.md](../REVIEW.md), findings engine #4

The root PTP daemon exits on a `release` message from any local process; the XPC peer is never validated.

## Done when

The helper checks the peer's code signature / audit token (same Team ID or a documented equivalent) before honouring `release`; an unauthorised peer is logged and ignored. `PTPHelperService` in the app still releases the helper cleanly. The AirPlayEngine test suite (Guard 6) stays green; `scripts/ptp-helper.plist` unchanged unless the check requires it.

## Test seam

AirPlayEngine tests (`PTPHelperTestSupport`) plus a documented manual check: send `{release:true}` from an unsigned process and confirm the daemon stays up

## Verification

```bash
bash scripts/run-tests.sh --package AirPlayEngine 2>/dev/null || (cd AirPlayEngine && echo 'use the AirPlayEngine runner named in AirPlayEngine/AGENTS.md')
```

## Findings (verbatim from the area reports)

### 4. [BUG] The root PTP daemon shuts down on request from any local process — the XPC peer is never validated
- Where: `AirPlayEngine/Sources/ptp-helper/main.c:463-478`; service registration `scripts/ptp-helper.plist:51-55`
- Evidence:
  ```c
  xpc_connection_set_event_handler((xpc_connection_t)peer, ^(xpc_object_t event) {
    if (xpc_get_type(event) == XPC_TYPE_DICTIONARY &&
        xpc_dictionary_get_bool(event, "release"))
    {
      ptp_helper_logmsg("ptp-helper: release requested - exiting so the PTP ports are freed");
      ptp_helper_should_run = 0;
    }
  });
  ```
- Why it matters: the Mach service is registered by a system-domain launchd job, so any process on the machine
  can look it up, connect, and send `{"release": true}`. Repeating that kills the PTP clock as fast as launchd
  demand-starts it, and every PTP-only receiver (Sonos et al.) stops streaming. This is the one root process
  in the product; its only input needs the strongest check in the package, and it has none.
- Fix: before honoring `release`, require the peer to be the app — `xpc_connection_set_peer_code_signing_requirement`
  with the app's designated requirement (macOS 12+), or check the peer's audit token / euid. One call, at the
  top of the peer handler.
- Confidence: high
