# Faithful port of PTPHelperSelfHealingActivator.activate + unregisterDrainAndReregister
# + PTPHelperActivator.activate's status gate (PTPHelperService.swift 316-318, 575-605, 764-806).
import asyncio, time
FIXED = False

class Helper:  # fake SMAppService helper
    def __init__(s): s.status = "enabled"; s.on_unregister = None
    async def unregister(s):
        s.status = "notRegistered"          # drain observed
        if s.on_unregister: await s.on_unregister()   # Device B arrives here
    def register(s): s.status = "enabled"

class Inner:  # PTPHelperActivator: status gate first, then wait for clock
    def __init__(s, h): s.h = h; s.calls = 0
    async def activate(s, timeout):
        st = s.h.status
        if st != "enabled": return ("needsApproval", st)
        s.calls += 1
        await asyncio.sleep(0)
        return "timingPortsUnavailable" if s.calls == 1 else "ready"  # wedged once, healed after cycle

class State:
    def __init__(s): s.inFlight = 0; s.last = None; s.cycling = None
    async def beginAttempt(s):
        if FIXED:
            while s.cycling is not None: await s.cycling.wait()
        s.inFlight += 1
    def endAttempt(s): s.inFlight -= 1; return s.inFlight
    def arm(s, now, window):
        if FIXED and s.inFlight != 0: return False
        if s.last is not None and not (now - s.last > window): return False
        s.last = now
        if FIXED: s.cycling = asyncio.Event()
        return True
    def finishCycle(s):
        if FIXED and s.cycling: ev = s.cycling; s.cycling = None; ev.set()

async def unregisterDrainAndReregister(h, delay, attempts):
    try: await h.unregister()
    except Exception: return "unregisterThrew"
    polls = 0
    while h.status != "notRegistered":
        if polls >= max(1, attempts): return "drainNeverObserved"
        polls += 1; await asyncio.sleep(delay)
    for a in range(max(1, attempts)):
        if a > 0: await asyncio.sleep(delay)
        try: h.register(); return ("registered", h.status)
        except Exception: continue
    return "registerExhausted"

class SelfHealing:
    def __init__(s, inner, h): s.inner=inner; s.h=h; s.state=State()
    async def activate(s, timeout):
        await s.state.beginAttempt()
        out = await s.inner.activate(timeout)
        others = s.state.endAttempt()
        if out != "timingPortsUnavailable": return out
        if not (others == 0 and s.state.arm(time.time(), 60)): return out
        try:
            cyc = await unregisterDrainAndReregister(s.h, 0.01, 10)
            if not (isinstance(cyc, tuple) and cyc[0] == "registered"): return out
        finally:
            s.state.finishCycle()
        await s.state.beginAttempt()
        r = await s.inner.activate(timeout)
        s.state.endAttempt()
        return r
