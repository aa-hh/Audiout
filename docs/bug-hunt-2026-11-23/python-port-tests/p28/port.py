# Faithful port of BTFrameRing (mono) + BTDelayLine.shift's ring moves (crossfade omitted:
# it only mixes output, the read-pointer moves are peek-rewind then seek(delta)).
import sys
FIX = "--fix" in sys.argv
class Ring:
    def __init__(s, minCap):
        c=1
        while c < max(2,minCap): c<<=1
        s.cap=c; s.mask=c-1; s.samples=[0.0]*c; s.w=0; s.r=0; s.floor=0
    def write(s, src):
        used=s.w-s.r
        if len(src) > s.cap-used: return False
        for i,v in enumerate(src): s.samples[(s.w+i)&s.mask]=v
        s.w+=len(src); return True
    def readFrame(s):
        if s.w-s.r<=0: return None
        v=s.samples[s.r&s.mask]; s.r+=1; return v
    def seek(s, frames):
        if frames==0: return 0
        used=s.w-s.r
        back = s.cap-used
        if FIX: back = min(back, s.r - s.floor)   # fix: never behind this session's first frame
        applied = -min(-frames, back) if frames<0 else min(frames, used)
        s.r+=applied; return applied
    def reset(s):
        s.r=s.w
        if FIX: s.floor=s.w
def shift(ring, delta, xfade=240):
    cap=0
    while cap<xfade and ring.readFrame() is not None: cap+=1
    ring.seek(-cap); return ring.seek(delta)

ring=Ring(64)
# Session 1: audio tagged 1.x, played out
ring.write([1.0]*40); [ring.readFrame() for _ in range(40)]
ring.reset()                         # config_change / trim_clamped rebuild
ring.write([2.0]*16)                 # session 2 pre-roll (anchor .. release)
out=[ring.readFrame() for _ in range(4)]   # released, plays 4 frames
ring.write([2.0]*8)
# applyTrimDelta(+20 frames) -> requestShift(-20) -> shift(-20)
applied=shift(ring,-20)
nxt=[ring.readFrame() for _ in range(20)]
stale=[v for v in nxt if v!=2.0]
print("applied",applied,"next frames",nxt)
assert not stale, f"FAIL: {len(stale)} frames from session 1 replayed after trim: {stale}"
print("PASS")
