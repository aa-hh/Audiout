import sys
FIX = "--fix" in sys.argv
class Unsupported(Exception): pass
class Engine:
    def __init__(s): s.running=False; s.attached=set()
class LPE:
    def __init__(s): s.e=Engine(); s.engineRunning=False; s.nodes={}
    def _start(s):
        if s.engineRunning: return
        s.e.running=True; s.engineRunning=s.e.running
    def start(s): s._start()
    def _stop_if_empty(s):
        if FIX and not s.nodes and s.engineRunning:
            s.e.running=False; s.engineRunning=False
    def addApp(s,b,fmt_ok=True,connect_ok=True,play_ok=True):
        if b in s.nodes: return
        if not fmt_ok:
            s._stop_if_empty(); raise Unsupported()
        p=object(); s.e.attached.add(p)
        if not connect_ok:
            s.e.attached.discard(p); s._stop_if_empty(); raise Unsupported()
        s._start()
        if not s.e.running:
            s.e.attached.discard(p); s._stop_if_empty(); raise Unsupported()
        s.nodes[b]=p
        if not play_ok:
            del s.nodes[b]; s.e.attached.discard(p); s._stop_if_empty(); raise Unsupported()
    def removeApp(s,b):
        n=s.nodes.pop(b,None)
        if n is None: return
        s.e.attached.discard(n)
        if not s.nodes and s.engineRunning:
            s.e.running=False; s.engineRunning=False
fails=0
for kw in [dict(fmt_ok=False),dict(connect_ok=False),dict(play_ok=False)]:
    l=LPE()
    try:
        l.start(); l.addApp("com.x",**kw)   # caller pattern, NativeBackend+PerAppRouting:515/632
    except Unsupported: pass
    l.removeApp("com.x")                    # capture stops -> handler removes
    ok = not l.e.running
    print(kw, "nodes=",len(l.nodes),"engine running=",l.e.running, "PASS" if ok else "FAIL")
    fails += not ok
sys.exit(1 if fails else 0)
