import sys
# Port of CompanionCoordinator engage/releaseEngaged/audition start+stop (simplified: no backend, no leases).
class C:
    def __init__(s, fix=False):
        s.main_out=set(); s.engaged={}; s.fix=fix; s.owner=None
    def engage(s,t,id_):
        if id_ in s.main_out: return
        s.main_out.add(id_); s.engaged.setdefault(t,[]).append(id_)
    def release(s,t):
        for i in reversed(s.engaged.pop(t,[])): s.main_out.discard(i)
    def start(s,t,ref):
        s.engage(t,t); s.engage(t,ref); s.owner=t
    def stop(s,t):   # setAlignmentTick active=false; backend then fires onReleased -> owners.release
        s.owner=None
        if s.fix: s.release(t)   # FIX: give selections back on explicit stop
def run(fix):
    c=C(fix); c.main_out={"other"}
    c.start("T","R"); c.stop("T")
    assert c.main_out=={"other"} and not c.engaged, (c.main_out,c.engaged)
for fix in (False,True):
    try: run(fix); print("fix=%s PASS"%fix)
    except AssertionError as e: print("fix=%s FAIL"%fix,e); 
