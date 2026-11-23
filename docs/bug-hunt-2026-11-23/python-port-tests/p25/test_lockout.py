# Port of BTDeviceSink.renderInterleaved + realignToDevicePulls (BTSyncedSink.swift 1404-1532),
# released state, with a FIFO ring written on wall time. FIX=1 applies the fix.
import sys
FIX = len(sys.argv) > 1 and sys.argv[1] == "fix"
SR = 48000.0; FC = 512; THRESH_MS = 20.0; MARGIN_MS = 100.0; LOST_MS = 1000.0
cyc_ns = FC / SR * 1e9

class Ring:
    def __init__(s, held): s.w = held; s.r = 0
    def used(s): return s.w - s.r
    def read(s):
        if s.w - s.r > 0: s.r += 1; return True
        return False
    def shift(s, d):  # clamp forward at write, backward ignored (history ample)
        if d > 0: d = min(d, s.used())
        s.r += d; return d

class Sink:
    def __init__(s, held):
        s.ring = Ring(held); s.origin = None; s.last = 0; s.pulled = 0; s.realigned = 0
        s.steady = 0; s.released = False
    def realign(s, t, fc):
        if s.origin is None: return
        gap = t - s.last; s.last = t
        if gap < 0 or gap >= LOST_MS*1e6:
            s.origin = t; s.pulled = fc; s.realigned = 0; return
        pulled_ns = int(round(s.pulled / SR * 1e9))
        s.pulled += fc
        pending = (t - s.origin) - pulled_ns - s.realigned
        if abs(pending) < THRESH_MS*1e6: return
        frames = int(round(pending/1e9*SR))
        if frames > 0:
            held = s.ring.used()
            margin = min(int(round(MARGIN_MS/1000*SR)), s.steady)
            room = max(0, held - margin)
            if frames > room:
                excess = gap - int(fc/SR*1e9)
                if not (excess < THRESH_MS*1e6):
                    s.ring.shift(max(0, held - (s.steady+fc))); s.origin=t; s.pulled=fc; s.realigned=0; return
                frames = room
        applied = s.ring.shift(frames)
        s.realigned += int(round(applied/SR*1e9))
    def render(s, t, fc, lock_free):
        s.realign(t, fc)
        if not lock_free:
            if FIX and s.origin is not None: s.pulled -= fc   # the fix
            return False
        if not s.released:
            s.released = True; s.origin = t; s.last = t; s.pulled = fc; s.realigned = 0
            s.steady = max(0, s.ring.used() - fc)
        for _ in range(fc): s.ring.read()
        return True

H = 9600  # 200 ms held at release
s = Sink(H)
lockouts = {500, 1500, 2500, 3500, 4500}   # five cycles find stateLock held
for i in range(6000):
    t = int(round(i*cyc_ns))
    s.render(t, FC, i not in lockouts)
    s.ring.w += FC                         # capture writes on wall time
late_ms = (s.ring.used() - H) / SR * 1000
print(f"lateness at end: {late_ms:.1f} ms (bound {THRESH_MS} ms)")
assert abs(late_ms) < THRESH_MS, "FAIL: lateness from lock-turned-away cycles persists unmeasured"
print("PASS")
