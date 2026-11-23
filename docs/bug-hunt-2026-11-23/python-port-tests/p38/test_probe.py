# Port of NetworkFrameworkBrowser.resolve/probeIPv4First/probeUnconstrainedFallback/remove
# (NativeDiscovery.swift ~1001-1143). Serial DispatchQueue = FIFO; NWConnection modeled:
# cancel() delivers .cancelled to stateUpdateHandler on the queue (unless already cancelled).
import sys
from collections import deque
FIX = "--fix" in sys.argv
q = deque()
def run():
    while q: q.popleft()()
class Conn:
    n=0
    def __init__(s, kind): Conn.n+=1; s.id=f"{kind}{Conn.n}"; s.handler=None; s.cancelled=False
    def start(s): pass
    def cancel(s):
        if s.cancelled: return
        s.cancelled=True; q.append(lambda: s.handler("cancelled"))
    def become_ready(s):  # network makes it ready; handler invoked on queue
        if not s.cancelled: q.append(lambda: s.handler("ready"))
class Browser:
    def __init__(s): s.probes={}; s.resultTXT={}; s.log=[]; s.conns=[]
    def onResolve(s,c): s.log.append(("resolve",c.id))
    def onRemove(s): s.log.append(("remove",))
    def resolve(s,key,did):
        s.resultTXT[key]=(key,did); s.probeIPv4First(key)
    def _install(s,key,c,fallback):
        if FIX and s.probes.get(key) is not None: s.probes[key].cancel()
        s.probes[key]=c; s.conns.append(c)
        def h(state):
            if state=="ready":
                def blk():
                    if FIX and s.probes.get(key) is not c: c.cancel(); return
                    s.onResolve(c); c.cancel(); s.probes[key]=None
                q.append(blk)
            elif state in ("failed","cancelled"):
                def blk():
                    if FIX and s.probes.get(key) is not c: return
                    s.probes[key]=None
                    if not fallback: s.fallback(key)
                q.append(blk)
        c.handler=h; c.start()
    def probeIPv4First(s,key): s._install(key,Conn("v4_"),False)
    def fallback(s,key):
        if s.resultTXT.get(key) is None: return
        s._install(key,Conn("fb_"),True)
    def remove(s,key):
        p=s.probes.get(key)
        if p: p.cancel()
        s.probes[key]=None; s.resultTXT.pop(key,None); s.onRemove()

b=Browser(); K="airplay|Spk|_airplay._tcp|local."
q.append(lambda: b.resolve(K,"AA"))     # .added -> probe A
q.append(lambda: b.resolve(K,"AA"))     # .changed (TXT) -> probe B
run()
A,B=b.conns[0],b.conns[1]
A.become_ready(); run()                  # first probe ready
q.append(lambda: b.remove(K)); run()     # .removed
B.become_ready(); run()                  # second probe ready
for c in b.conns: c.become_ready()       # any other live probe too
run()
print("log:",b.log)
ri=b.log.index(("remove",))
late=[e for e in b.log[ri+1:] if e[0]=="resolve"]
if late: print("FAIL: onResolve after onRemove:",late); sys.exit(1)
print("PASS"); sys.exit(0)
