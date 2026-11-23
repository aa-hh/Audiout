# Port of NativeBackend+Tone.swift setOutputSet loop (:375-463) and
# setPerAppConnectionStateLocked (PerAppRouting.swift:58-70).
import sys
FIX = "--fix" in sys.argv
class B:
    def __init__(s):
        s.order=[]; s.known={}; s.outputIDs={}; s.desiredOn={}; s.failedGate=set()
        s.added=set(); s.converging=set(); s.state={}; s.kicks=[]
    def discover(s,id):
        s.order.append(id); s.known[id]=True; s.outputIDs[id]="out-"+id; s.state[id]="off"
    def claimed(s,id):
        return s.desiredOn.get(id)==True or id in s.converging or id in s.added
    def setPerAppState(s,st,id):
        if s.claimed(id): return
        s.state[id]=st
    def setOutputSet(s,ids):
        for id in s.order:
            wantOn = id in ids
            previous = s.desiredOn.get(id)
            if FIX and previous is None: previous=False   # fix: `?? false`
            s.desiredOn[id]=wantOn
            if previous!=wantOn: s.failedGate.discard(id)
            if previous!=wantOn: s.state[id] = "connecting" if wantOn else "off"
            if previous!=wantOn and id not in s.converging:
                s.converging.add(id); s.kicks.append(id)
    def converge(s,id):  # convergeDevice: want false, not added -> no op; release
        s.converging.discard(id)
b=B(); b.discover("A"); b.discover("P")      # P discovered after launch, never selected
b.setPerAppState("connected","P")            # per-app bind connects P
b.failedGate  # (no park needed for the state part)
b.setOutputSet({"A"})
for k in list(b.kicks): b.converge(k)
print("P state:", b.state["P"], "kicked P:", "P" in b.kicks)
assert b.state["P"]=="connected", "FAIL: per-app-connected P reset to .off by unrelated setOutputSet([A])"
print("PASS")
