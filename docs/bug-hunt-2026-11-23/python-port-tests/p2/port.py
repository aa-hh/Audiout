# Faithful port of NativeCaptureCoordinator start()/recreateTap() state + TapRebuildCoalescer.
import sys
FIX = "--fix" in sys.argv

class Coalescer:
    def __init__(s): s.pending=False
    def markPending(s): s.pending=True
    def takePending(s):
        p=s.pending; s.pending=False; return p

class FakeTap:
    def __init__(s, coord, rate_fn, during=None):
        s.coord=coord; s.rate_fn=rate_fn; s.during=during; s.onDefaultDeviceChanged=None
    def createAndStart(s):
        rate=s.rate_fn()                 # format read
        # subscribeToDefaultOutput() happens inside createAndStart; a device change
        # after it fires onDefaultDeviceChanged before start() commits.
        if s.during: d=s.during; s.during=None; d(s)
        return rate
    def teardown(s): pass

class Coord:
    def __init__(s):
        s.state=("idle",); s.co=Coalescer(); s.device_rate=44100
        s.resets=0; s.rebuilds=0; s.next_during=None
    def makeTap(s):
        d=s.next_during; s.next_during=None
        t=FakeTap(s, lambda: s.device_rate, d)
        t.onDefaultDeviceChanged=s.handleDeviceChange
        return t
    def start(s):
        if s.state[0] not in ("idle","failed"): return
        s.state=("creatingTap",)
        t=s.makeTap()
        fmt=t.createAndStart()
        if s.state[0]!="creatingTap": return
        s.tap=t; s.state=("capturing",fmt)
        replay = s.co.takePending() if FIX else False
        if replay: s.recreateTap("deviceOrRateChange")
    def handleDeviceChange(s): s.recreateTap("deviceOrRateChange")
    def updateRouting(s): s.recreateTap("exclusionChange")
    def recreateTap(s, cause):
        if s.state[0]!="capturing":
            if s.state[0]=="creatingTap": s.co.markPending()
            return
        prev=s.state[1]; s.state=("creatingTap",); s.rebuilds+=1
        t=s.makeTap(); fmt=t.createAndStart()
        if s.state[0]!="creatingTap": return
        s.tap=t; s.state=("capturing",fmt); replay=s.co.takePending()
        if cause=="deviceOrRateChange" or fmt!=prev: s.resets+=1
        if replay: s.recreateTap("deviceOrRateChange")

c=Coord()
def device_changes(tap):
    c.device_rate=48000           # default output moved to a 48 kHz device
    tap.onDefaultDeviceChanged()  # listener fires while start() is still .creatingTap
c.next_during=device_changes
c.start()
ok=True
if c.state!=("capturing",48000):
    print(f"FAIL: after start + mid-create device change, tap stuck on {c.state} (device now 48000)"); ok=False
# later unrelated exclusion rebuild on an unchanged device
r0=c.resets; c.updateRouting()
if c.resets-r0!=0:
    print(f"FAIL: unrelated exclusion rebuild caused {c.resets-r0} spurious AirPlay reset(s) via stale pending replay"); ok=False
print("PASS" if ok else "")
sys.exit(0 if ok else 1)
