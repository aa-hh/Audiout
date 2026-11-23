# Faithful port of PerAppCaptureCoordinator start/beginStart/handleDeviceChange
# state + TapRebuildCoalescer logic (synchronous; queue.sync is a no-op lock here).
import sys
FIX = "--fix" in sys.argv

class Coalescer:
    def __init__(s): s.pending=False
    def markPending(s): s.pending=True
    def takePending(s):
        p=s.pending; s.pending=False; return p

class Slot:
    def __init__(s): s.state=("idle",); s.tap=None; s.co=Coalescer()

class Tap:
    def __init__(s,c): s.c=c; s.cb=None
    def createAndStart(s, procs):
        s.c.creates += 1
        if s.c.during_create: f=s.c.during_create; s.c.during_create=None; f()
        if s.c.throw_next: s.c.throw_next=False; raise RuntimeError("tap fail")
        return 48000
    def teardown(s): pass

class Coord:
    def __init__(s):
        s.slots={}; s.procs={"p1"}; s.creates=0; s.during_create=None; s.throw_next=False
    def transition(s, slot, st):
        slot.state=st
        if FIX and st[0]=="failed": slot.co.pending=False   # fix: drop stale flag on failure
    def start(s,b):
        slot=s.slots.setdefault(b,Slot())
        if slot.state[0] in ("idle","failed"):
            s.transition(slot,("resolvingProcess",)); s.beginStart(b)
    def beginStart(s,b):
        procs=set(s.procs)
        if not procs:
            sl=s.slots.get(b)
            if sl and sl.state[0]=="resolvingProcess": s.transition(sl,("failed",))
            return
        sl=s.slots[b]
        if sl.state[0]!="resolvingProcess": return
        s.transition(sl,("creatingTap",))
        tap=Tap(s)
        try:
            fmt=tap.createAndStart(procs)
            sl=s.slots.get(b)
            if not sl or sl.state[0]!="creatingTap": tap.teardown(); return
            sl.tap=tap; s.transition(sl,("capturing",fmt))
        except Exception:
            tap.teardown(); sl=s.slots.get(b)
            if sl and sl.state[0]=="creatingTap": sl.tap=None; s.transition(sl,("failed",))
    def handleDeviceChange(s,b):
        sl=s.slots.get(b)
        if not sl: return
        if sl.state[0]!="capturing":
            if sl.state[0]=="creatingTap": sl.co.markPending()
            return
        old=sl.tap; sl.tap=None; s.transition(sl,("creatingTap",))
        procs=set(s.procs)
        if not procs:
            if sl.state[0]=="creatingTap": s.transition(sl,("failed",))
            return
        tap=Tap(s)
        try:
            fmt=tap.createAndStart(procs)
            sl=s.slots.get(b)
            if not sl or sl.state[0]!="creatingTap": tap.teardown(); return
            sl.tap=tap; s.transition(sl,("capturing",fmt))
            replay=sl.co.takePending()
            if replay: s.handleDeviceChange(b)
        except Exception:
            tap.teardown(); sl=s.slots.get(b)
            if sl and sl.state[0]=="creatingTap": sl.tap=None; s.transition(sl,("failed",))

def scenario(fail_kind):
    c=Coord(); b="com.x"
    c.start(b); assert c.slots[b].state[0]=="capturing"
    # device change -> rebuild; a second device change arrives mid-rebuild (new tap's
    # listener is armed inside createAndStart), then the rebuild fails.
    if fail_kind=="throw":
        c.during_create=lambda: c.handleDeviceChange(b); c.throw_next=True
        c.handleDeviceChange(b)
    else:  # empty resolve: the coalesced change lands before resolve (old tap listener)
        sl=c.slots[b]; c.transition(sl,("creatingTap",)); c.handleDeviceChange(b)  # marks pending
        c.transition(sl,("capturing",48000)); sl.co.pending=True  # (state restored; flag set)
        c.procs=set(); c.handleDeviceChange(b); c.procs={"p1"}
    assert c.slots[b].state[0]=="failed"
    c.start(b); assert c.slots[b].state[0]=="capturing"   # backoff / process-list restart
    before=c.creates
    c.handleDeviceChange(b)                                # ONE real device change
    n=c.creates-before
    ok = n==1
    print(f"{fail_kind}: one real device change -> {n} tap rebuild(s) (expected 1) -> {'PASS' if ok else 'FAIL'}")
    return ok

r=[scenario("throw"), scenario("empty")]
sys.exit(0 if all(r) else 1)
