# Port of SyncedLocalSink enqueue / clearSessionState / InterleavedFloatRing (write, reset).
# Deterministic interleaving: the tap thread's enqueue lands between
# clearSessionState's locked `anchored = false` (line 329) and `ring.reset()` (line 347).
import sys
FIX = "--fix" in sys.argv
CH, CHUNK = 2, 480            # 10 ms at 48 kHz
NS_PER_FRAME = 1e9/48000

class Ring:
    def __init__(s, cap=1<<20): s.cap=cap; s.mask=cap-1; s.head=0; s.tail=0; s.data={}
    def write(s, chunk_id, count):
        used=(s.head-s.tail)&s.mask
        if count > s.cap-1-used: return False
        for i in range(count): s.data[(s.head+i)&s.mask]=(chunk_id,i)
        s.head=(s.head+count)&s.mask; return True
    def reset(s): s.tail=s.head                     # line ~1037
    def first_sample(s): return s.data.get(s.tail) if s.head!=s.tail else None

class Sink:
    def __init__(s): s.ring=Ring(); s.anchored=False; s.anchor_pts=None
    def enqueue(s, chunk_id, pts):                   # lines 607-645 (try() succeeds)
        if not s.anchored:
            if FIX: s.ring.reset()                   # fix: drop pre-anchor leftovers under the lock
            s.anchored=True; s.anchor_pts=pts
        s.ring.write(chunk_id, CHUNK*CH)
    def clear_part1(s):                              # line 329 (inside stateLock)
        if FIX: s.ring.reset()                       # fix: reset before anchored=false is published
        s.anchored=False
    def clear_part2(s):
        if not FIX: s.ring.reset()                   # line 347 (after Telemetry.log)

s=Sink(); pts=lambda k: int(k*CHUNK*NS_PER_FRAME)
for k in range(5): s.enqueue(k, pts(k))              # streaming session
# requestReanchor -> performLifecycleRebuild: teardownEngine, remeasure, clearSessionState
s.clear_part1()
s.enqueue(5, pts(5))                                 # tap chunk lands in the window
s.clear_part2()
s.enqueue(6, pts(6))                                 # next tap chunk, engine restarts
first_chunk,_ = s.ring.first_sample()
err_ns = pts(first_chunk) - s.anchor_pts
print(f"anchor pts={s.anchor_pts} chunk-at-ring-sample-0={first_chunk} pts={pts(first_chunk)} error={err_ns/1e6:.2f} ms")
assert err_ns == 0, f"FAIL: session anchored {err_ns/1e6:.2f} ms off (anchor chunk discarded by reset)"
print("PASS")

# second interleaving for the fix: an old-session chunk written after the reset but
# before anchored=false is published must not become ring sample 0
if FIX:
    s=Sink()
    for k in range(3): s.enqueue(k, pts(k))
    s.ring.reset()                                   # clear_part1's reset ...
    s.ring.write(3, CHUNK*CH)                        # ... old-session enqueue's write (saw anchored=true)
    s.anchored=False                                 # ... then anchored=false
    s.enqueue(4, pts(4))
    fc,_=s.ring.first_sample(); assert pts(fc)==s.anchor_pts, "FAIL second interleaving"
    print("PASS second interleaving")
