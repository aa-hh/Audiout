# Faithful port of NativeDiscovery.resolve / probeIPv4First / probeUnconstrainedFallback.
# NWConnection modelled: start() -> .ready (if reachable); cancel() -> .cancelled delivered async.
import sys
FIXED = len(sys.argv) > 1 and sys.argv[1] == "fixed"

class Queue:
    def __init__(s): s.q=[]
    def async_(s,f): s.q.append(f)
    def drain(s):
        while s.q: s.q.pop(0)()

class Conn:
    def __init__(s, q, v4only, dev, log): s.q=q; s.v4only=v4only; s.dev=dev; s.handler=None; s.log=log; s.cancelled=False
    def start(s):
        s.log.append(("start", "v4" if s.v4only else "any"))
        fam = "v4" if (s.v4only or s.dev["prefer"]=="v4") else "v6"
        if s.v4only and not s.dev["v4"]: s.q.async_(lambda: s.handler("failed")); return
        s.addr = fam
        s.q.async_(lambda: s.handler("ready"))
    def cancel(s):
        if not s.cancelled:
            s.cancelled=True; s.q.async_(lambda: s.handler("cancelled"))

class Disc:
    def __init__(s, dev):
        s.q=Queue(); s.dev=dev; s.probes={}; s.resultTXT={}; s.resolved=[]; s.log=[]
    def resolve(s, key):
        s.resultTXT[key]=True
        s.probeIPv4First(key)
    def _ready(s, c, key):
        if c.addr=="v4": s.resolved.append(key)
        else: s.log.append(("IPv6-only log", key))
        c.cancel(); s.probes[key]=None
    def probeIPv4First(s, key):
        c=Conn(s.q, True, s.dev, s.log); s.probes[key]=c
        def h(state):
            if state=="ready": s.q.async_(lambda: s._ready(c,key))
            elif state=="failed" or (state=="cancelled" and not FIXED):
                def f():
                    s.probes[key]=None
                    s.probeUnconstrainedFallback(key)
                s.q.async_(f)
            elif state=="cancelled":  # fixed
                s.q.async_(lambda: s.probes.__setitem__(key,None))
        c.handler=h; c.start()
    def probeUnconstrainedFallback(s, key):
        if not s.resultTXT.get(key): return
        c=Conn(s.q, False, s.dev, s.log); s.probes[key]=c
        def h(state):
            if state=="ready": s.q.async_(lambda: s._ready(c,key))
            else: s.q.async_(lambda: s.probes.__setitem__(key,None))
        c.handler=h; c.start()

def test_dual_stack(prefer):
    d=Disc({"v4":True,"prefer":prefer}); d.resolve("airplay|Kitchen|_airplay._tcp|local."); d.q.drain()
    starts=[e for e in d.log if e[0]=="start"]; v6=[e for e in d.log if e[0]=="IPv6-only log"]
    print(f"prefer={prefer}: probes started={starts}, onResolve count={len(d.resolved)}, IPv6-only logs={len(v6)}")
    return len(starts)==1 and len(d.resolved)==1 and not v6

ok = test_dual_stack("v4") & test_dual_stack("v6")
print("PASS" if ok else "FAIL: successful IPv4 probe's .cancelled started the unconstrained fallback")
sys.exit(0 if ok else 1)
