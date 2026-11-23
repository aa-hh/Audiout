# Port of NativeCaptureCoordinator handleBuffer gap arms + FeedGapTracker + recreateTap arm.
import sys
FIX = '--fix' in sys.argv
MAX_FEED_GAP = 2_000_000_000; MAX_DROPPED = 50_000_000; RATE=44100
class Tracker:
    def __init__(s): s.last=0; s.armed=0; s.epoch=0
    def arm(s,cause,e): s.epoch=e; s.armed=cause
    def consume(s,de):
        if s.armed==0 or de < s.epoch: return None
        c=s.armed; s.armed=0; return (c,s.last)
class Coord:
    def __init__(s): s.fg=Tracker(); s.tapEpoch=0; s.filled=0
    def recreate_tap(s, now, wizard=False):
        idle = FIX and now - s.fg.last > MAX_DROPPED   # fix: tap already idle -> no feed hole to patch
        if not wizard and not idle: s.fg.arm(1, s.tapEpoch+1)
        s.tapEpoch+=1
    def deliver(s,pts,frames):
        s.fg.noteEnd = None
        s.fg.last = pts + round(frames*1e9/RATE)
    def handle(s,pts,frames):
        g=s.fg.consume(s.tapEpoch)
        if g and g[1]!=0:
            gap=pts-g[1]
            lim = MAX_FEED_GAP
            if 0<gap<=lim: s.filled+=gap
        else:
            last=s.fg.last; gap=pts-last
            block=int(frames*1e9/RATE)
            if last!=0 and gap>=block//2 and gap<=MAX_DROPPED: s.filled+=gap
        s.deliver(pts,frames)
def run(rebuild):
    c=Coord(); t=0; blk=512; dt=round(blk*1e9/RATE)
    for _ in range(100): c.handle(t,blk); t+=dt      # playing
    pause_start=t
    if rebuild: c.recreate_tap(pause_start + 300_000_000)                    # exclusionChange 0.3 s into pause
    t = pause_start + 1_500_000_000                  # resume 1.5 s later (tap idle meanwhile)
    for _ in range(10): c.handle(t,blk); t+=dt
    return c.filled
base=run(False); rb=run(True)
# sanity: a rebuild while playing still gets its ~200 ms hole filled
c=Coord(); t=0; dt=round(512*1e9/RATE)
for _ in range(100): c.handle(t,512); t+=dt
c.recreate_tap(t); t+=200_000_000; c.handle(t,512)
assert abs(c.filled-200_000_000)<1e6, c.filled
print(f"fix={FIX} silence injected: no-rebuild={base/1e6:.1f}ms  rebuild-during-pause={rb/1e6:.1f}ms")
assert rb==base, f"FAIL: rebuild during pause injected {(rb-base)/1e6:.1f} ms of extra silence (later blocks play that late)"
print("PASS")
