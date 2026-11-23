import math, sys
FIX = "--fix" in sys.argv
def clamp(v): return max(0, min(100, v))
def volumeInt(s):
    if not math.isfinite(s): return 0
    b = min(1.0, max(0.0, s)); return clamp(int(round_half_away(b*100)))
def round_half_away(x): return math.floor(x+0.5) if x>=0 else -math.floor(-x+0.5)
def scalar(v): return clamp(v)/100.0
class HW:  # device with 64 hardware steps
    def __init__(s, steps): s.steps=steps; s.v=0.5
    def write(s, f): s.v = round(f*s.steps)/s.steps; return True
    def read(s): return volumeInt(s.v)
class SOV:
    def __init__(s, hw): s.hw=hw; s.lastKnownVolume=hw.read(); s.lastKnownMuted=False; s.fired=[]
    def setVolume(s, v):  # default-device path (resolvingTarget -> nil)
        c = clamp(v); s.lastKnownVolume = c
        wrote = s.hw.write(scalar(c))
        if FIX and wrote: s.lastKnownVolume = s.hw.read()   # fix: memo the read-back
        if not wrote: s.lastKnownVolume = s.hw.read()
        s.pending = True
    def handleDeviceChangeLocked(s):
        vol = s.hw.read(); muted = False
        if vol == s.lastKnownVolume and muted == s.lastKnownMuted: return
        s.lastKnownVolume = vol; s.lastKnownMuted = muted
        s.fired.append((vol, muted, False))
hw = HW(64); o = SOV(hw)
o.setVolume(1)
for _ in range(16): o.handleDeviceChangeLocked()   # HAL echo burst of our own write
print("readback", hw.read(), "fired", o.fired)
assert o.fired == [], "own write echo reported as external gesture: %r" % o.fired
print("PASS")
