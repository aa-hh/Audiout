# Faithful port of the rebind-recovery slot bookkeeping in
# NativeBackend+PerAppRouting.swift (resetAirPlaySessionForWholeSystem L871-925,
# enqueueRebindRecovery L1000-1176, handleDestinationSetsChanged binding diff
# L1760-1797, resetAirPlaySessionForRoutedApp L825-856) and NativeBackend.swift
# releaseRebindConverging / releaseConvergingAndRequeueIfNeeded (L3421-3446).
import sys
FIX = "--fix" in sys.argv

class Work:
    def __init__(s, fn): s.fn, s.cancelled = fn, False
    def cancel(s): s.cancelled = True

class B:
    def __init__(s):
        s.converging=set(); s.rebindConverging=set(); s.gen={}; s.pending={}
        s.added=set(); s.streamBindings={}; s.outputIDs={}; s.desiredOn={}
        s.timers=[]; s.tail=[]; s.engine_ok=lambda: False; s.maxAttempts=3
        s.converges=[]
    def claimed(s,i): return s.desiredOn.get(i)==True or i in s.converging or i in s.added
    def stillOwns(s,i,scope):
        if scope[0]=="perApp": return s.streamBindings.get(i)==scope[1] and not s.claimed(i)
        return i in s.added
    def release(s,i):
        s.rebindConverging.discard(i); s.converging.discard(i)
        want=s.desiredOn.get(i)
        if want is not None and i in s.outputIDs and want != (i in s.added):
            s.converging.add(i); return i
        return None
    def wsReset(s):
        for d in list(s.added):
            if d not in s.outputIDs: continue
            sup = d in s.rebindConverging and d in s.pending
            if d in s.converging and not sup: continue
            s.converging.add(d); s.rebindConverging.add(d)
            g=s.gen.get(d,0)+1; s.gen[d]=g
            w=s.pending.pop(d,None); w and w.cancel()
            s.enqueue(d,("ws",),g,1)
    def enqueue(s,d,scope,g,attempt):
        def body():
            pre = s.gen.get(d)==g and s.stillOwns(d,scope)
            ok = s.engine_ok() if pre else False
            if not (s.gen.get(d)==g and s.stillOwns(d,scope)):
                return s.release(d) if scope[0]=="ws" else None
            if ok:
                s.gen.pop(d,None); w=s.pending.pop(d,None); w and w.cancel()
                return s.release(d) if scope[0]=="ws" else None
            if attempt >= s.maxAttempts:
                s.gen.pop(d,None); w=s.pending.pop(d,None); w and w.cancel()
                return s.release(d) if scope[0]=="ws" else None
            def fire():
                if s.gen.get(d)!=g: return None
                if not s.stillOwns(d,scope) or d not in s.outputIDs:
                    s.gen.pop(d,None); s.pending.pop(d,None)
                    return s.release(d) if scope[0]=="ws" else None
                s.pending.pop(d,None); s.enqueue(d,scope,g,attempt+1); return None
            w=Work(fire); old=s.pending.pop(d,None); old and old.cancel()
            s.pending[d]=w; s.timers.append(w); return None
        s.tail.append(body)
    # per-app paths
    def destSetsChanged(s, newBindings):
        for d,st in newBindings.items():
            old=s.streamBindings.get(d)
            if old is not None and old!=st:
                if FIX and d in s.rebindConverging: continue
                s.gen.pop(d,None); w=s.pending.pop(d,None); w and w.cancel()
        for d in list(s.streamBindings):
            if d not in newBindings:
                if FIX and d in s.rebindConverging: continue
                s.gen.pop(d,None); w=s.pending.pop(d,None); w and w.cancel()
        s.streamBindings=dict(newBindings)
    def routedReset(s, streams):
        for d,b in list(s.streamBindings.items()):
            if b in streams and d in s.outputIDs:
                if FIX and d in s.rebindConverging: continue
                g=s.gen.get(d,0)+1; s.gen[d]=g
                w=s.pending.pop(d,None); w and w.cancel()
                s.enqueue(d,("perApp",b),g,1)
    def drain(s):
        for _ in range(100):
            if s.tail:
                r=s.tail.pop(0)()
                if r: s.converges.append(r)
            elif s.timers:
                w=s.timers.pop(0)
                if not w.cancelled:
                    r=w.fn();
                    if r: s.converges.append(r)
            else: return

def scenario(trigger):
    b=B(); D="D"; b.outputIDs[D]=1; b.added.add(D); b.desiredOn[D]=True
    b.streamBindings[D]=2          # roadmap-008 contested window
    b.wsReset()
    b.tail.pop(0)()                # attempt 1 fails -> backoff armed
    assert D in b.pending and D in b.rebindConverging
    if trigger=="drop": b.destSetsChanged({})
    elif trigger=="move": b.destSetsChanged({D:3})
    else: b.routedReset({2})
    b.engine_ok=lambda: True
    b.drain()
    return D in b.converging

bad=False
for t in ("drop","move","recapture"):
    leaked=scenario(t)
    print(f"{t:10s} converging slot still held after everything settled: {leaked}")
    bad |= leaked
print("FAIL: slot leaked, device wedged" if bad else "PASS")
sys.exit(1 if bad else 0)
