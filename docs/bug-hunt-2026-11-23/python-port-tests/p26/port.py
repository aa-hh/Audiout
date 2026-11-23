# Faithful port of BTDeviceSink.enqueue / clearSessionStateLocked / BTFrameRing, with
# the tap thread's enqueue interleaved deterministically into the rebuild window.
import sys
FIX = "--fix" in sys.argv
class Ring:
    def __init__(s): s.buf={}; s.w=0; s.r=0
    def write(s,frames):
        for i,f in enumerate(frames): s.buf[s.w+i]=f
        s.w+=len(frames)
    def reset(s): s.r=s.w
    def read(s):
        if s.w-s.r<=0: return None
        v=s.buf[s.r]; s.r+=1; return v
class Sink:
    def __init__(s): s.ring=Ring(); s.anchored=False; s.anchorPts=None; s.locked=False
    def enqueue(s,pts,n=480):
        frames=[pts*1000+i for i in range(n)]   # frame id encodes its capture pts
        if not s.locked:          # stateLock.try()
            if not s.anchored:
                s.anchored=True; s.anchorPts=pts
                if FIX: s.ring.reset()          # fix: anchor starts an empty ring
        s.ring.write(frames)
    def clear_session_part1(s):  # stateLock.withLock { anchored = false ... }
        s.locked=True; s.anchored=False; s.anchorPts=0
        if FIX: s.ring.reset()                  # fix: reset inside the lock
        s.locked=False
    def clear_session_part2(s):  # delayLine.reset() -- outside the lock
        if not FIX: s.ring.reset()              # fix: no reset outside the lock
s=Sink()
s.enqueue(1); s.enqueue(2)            # music playing, session anchored on pts 1
s.clear_session_part1()               # rebuild (config_change) on graphQueue
s.enqueue(3)                          # tap thread lands in the window: anchors on pts 3
s.clear_session_part2()               # delayLine.reset() discards pts 3's buffer
s.enqueue(4); s.enqueue(5)
first=s.ring.read()
print(f"anchorPts={s.anchorPts} first released frame from pts={first//1000}")
ok = first//1000 == s.anchorPts
print("PASS" if ok else "FAIL: first frame released belongs to a later pts than the anchor -> device plays early by one buffer")
sys.exit(0 if ok else 1)
