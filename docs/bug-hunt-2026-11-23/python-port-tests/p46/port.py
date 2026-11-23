# Faithful port of SyncedLocalSink start/applyUserOffsetDelta/enqueue anchor logic
# and NativeBackend.applyLocalSyncOffsetLive. FIX=1 applies the proposed fix.
import os, sys
FIX = os.environ.get("FIX") == "1"
MS = 1_000_000
class Sink:
    def __init__(s, off): s.off=off; s.started=False; s.anchored=False; s.released=False; s.target=0; s.cached=None
    def measure(s): return 100*MS + s.off()*MS   # presentation+latency+margin + userOffset
    def start(s):
        if s.started: return
        s.cached = s.measure(); s.started=True
    def apply_delta(s, d):
        if not s.anchored:
            if FIX: s.cached = None   # fix: drop stale cache so the anchor re-reads the offset
            return
        raise NotImplementedError
    def enqueue(s, pts):
        if not s.anchored:
            delay = s.cached if s.cached is not None else s.measure()
            s.cached = delay; s.anchored=True; s.target = pts + delay
class Backend:
    def __init__(s): s.setting=0; s.last=0.0; s.sink=Sink(lambda: s.setting)
    def set_offset(s, ms):
        s.setting=ms; eff=float(s.setting); d=eff-s.last; s.last=eff
        if d!=0: s.sink.apply_delta(d)
b=Backend(); b.sink.start(); b.set_offset(200); pts=1_000*MS; b.sink.enqueue(pts)
want = pts + b.sink.measure(); got=b.sink.target
print(f"target={got} expected={want} lastApplied={b.last}")
if got!=want: print("FAIL: +200 ms offset lost (target off by %d ms)"%((want-got)//MS)); sys.exit(1)
print("PASS")
