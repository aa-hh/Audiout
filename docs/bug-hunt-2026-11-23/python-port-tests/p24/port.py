# Faithful port of BTDeviceSink.enqueue + renderInterleaved release gate +
# catchUpToTargetLocked + SyncTiming.plan (BTSyncedSink.swift 1154-1186, 1404-1450, 1563; SyncCore.swift 68-100).
import collections, sys
SR=44100.0; NS=1e9/SR
class Sink:
    def __init__(s, delay_ns, fixed=False):
        s.ring=collections.deque(); s.anchored=False; s.released=False
        s.anchorPts=0; s.target=0; s.delay=delay_ns; s.fixed=fixed; s.lock_busy=False
    def enqueue(s, frames_pts, pts):   # frames carry their own capture pts as payload
        if not s.lock_busy:            # stateLock.try()
            if not s.anchored:
                s.anchored=True
                p=pts
                if s.fixed:            # FIX: back-date by frames already buffered
                    p=pts-int(round(len(s.ring)*NS))
                s.anchorPts=p
                s.target=s.anchorPts+s.delay
        s.ring.extend(frames_pts)      # delayLine.write runs regardless
    def render(s, n, cycle):
        out=[None]*n
        if not s.anchored: return out
        if s.released: silent=0
        else:
            d=s.target-cycle
            if d<=0: silent=0
            else:
                off=int(round(d/NS))
                if off>=n: return out
                silent=off
            s.released=True
            over=max(0,cycle-s.target); want=int(round(over/1e9*SR))
            for _ in range(min(want,len(s.ring))): s.ring.popleft()
        for i in range(silent,n):
            if s.ring: out[i]=s.ring.popleft()
        return out
def run(fixed):
    B=512; D=200_000_000; s=Sink(D,fixed); t0=10_000_000_000
    errs=[]
    for k in range(60):
        pts=t0+int(round(k*B*NS))
        s.lock_busy=(k==0)             # first enqueue: render/control holds stateLock
        s.enqueue([pts+int(round(i*NS)) for i in range(B)], pts)
        cyc=pts                        # render cycles on the same grid
        out=s.render(B,cyc)
        for i,fp in enumerate(out):
            if fp is not None: errs.append((cyc+int(round(i*NS)))-(fp+D))
    return errs
if __name__=="__main__":
    fixed = len(sys.argv)>1 and sys.argv[1]=="fixed"
    e=run(fixed); late=max(abs(x) for x in e)/1e6
    print(f"{'fixed' if fixed else 'current'}: max |playout - (pts+delay)| = {late:.3f} ms over {len(e)} frames")
    assert late < 0.1, f"FAIL: device plays late by {late:.3f} ms (one buffer)"
    print("PASS")
