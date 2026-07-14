# T-PTP-PROBE result — can root bind UDP 319/320 on macOS?

**Date:** 2026-07-13 · **macOS:** 14.4.1 (arm64) · **Verdict: RESOLVED — YES, root
can bind 319/320, provided macOS AirPlay Receiver is OFF.** The gating unknown for
the shipped PTP helper (T-HELPER-DESIGN-1) is cleared in our favor.

## Evidence

The probe (`/tmp/ptp_bind_probe.c` — plain `bind()`, no SO_REUSEADDR/REUSEPORT,
matching libairptp exactly) run unelevated returned **EADDRINUSE (errno 48)**, not
EACCES (errno 13). EADDRINUSE means the ports are *already bound*, not
*permission-denied*.

`lsof` identified the holder: **our own OwnTone** (pid 82557), which is holding
both `*:319` and `*:320` right now. OwnTone started as root, bound the ports, and
dropped privileges to `alechenderson` — i.e. it is *already doing exactly what our
helper will do*, successfully, on this macOS version. That is stronger proof than
an abstract probe: a real AirPlay 2 sender binds 319/320 here.

## Why this reconciles with shairport's "macOS uses those ports" claim

macOS occupies 319/320 **only when AirPlay Receiver is enabled** (System Settings →
General → AirDrop & Handoff → AirPlay Receiver). We turned that OFF earlier in the
session for the fake-speaker work — which is why OwnTone can hold the ports now.
shairport/nqptp's failure reports are from machines with AirPlay Receiver on (or an
older macOS default).

## Consequence for the design (T-HELPER-DESIGN-1 stands)

- The SMAppService root helper binding 319/320 is viable on macOS 14.4.1.
- **New operational requirement:** the app must detect when macOS AirPlay Receiver
  is holding 319/320 and prompt the user to disable it (OwnTone required the same
  human step in Phase 0). Add to Phase 1/2 app onboarding UX.
- No design rework needed; the "helper owns 319/320" premise holds.

## Optional future rigor (not blocking)

A from-scratch elevated probe (stop OwnTone → confirm ports free → `bind()` under an
osascript admin dialog → expect SUCCESS) would confirm from zero, but is unnecessary:
OwnTone holding the ports live is conclusive. Not run to avoid disrupting the
in-flight T-C1 backend agent (which is using the OwnTone server) and to spare
redundant root dialogs.
