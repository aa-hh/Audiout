# Faithful port of NativeBackend+Bluetooth.swift: btDriftBaselines, driftTrackingRuns,
# refreshDriftTrackingLocked, resetBTAlignment(forDevice:source:) (stateQueue work run inline).
import sys
FIX = "--fix" in sys.argv

class Tracker:
    def __init__(s): s.baselines=[]; s.running=False
    def setBaselines(s,b): s.baselines=list(b)
    def start(s): s.running=True
    def stop(s): s.running=False

class Backend:
    def __init__(s):
        s.lat={}; s.trim={}; s.btSelectedUIDs=[]; s.expectedSelected=set(); s.known={}
        s.room=200.0; s.driftTracker=Tracker()
    def roomDelayLocked(s): return s.room
    @staticmethod
    def btDriftBaselines(uids, lat, trims, room):
        return [(u, room + trims.get(u,0)) for u in uids if u in lat]
    @staticmethod
    def driftTrackingRuns(bt, anchors): return bt>1 or (bt==1 and anchors>0)
    def refreshDriftTrackingLocked(s):
        t=s.driftTracker
        if t is None: return
        b=s.btDriftBaselines(s.btSelectedUIDs, s.lat, s.trim, s.roomDelayLocked())
        n=len(b)  # no AirPlay anchors in this scenario
        if not s.driftTrackingRuns(n, len(b)-n):
            t.setBaselines([]); t.stop(); return
        t.setBaselines(b); t.start()
    def updateBTReferenceBufferLocked(s): pass  # never reaches refreshDriftTrackingLocked
    def resetBTAlignment(s, id, source):
        s.lat.pop(id,None); s.trim.pop(id,None)
        # stateQueue.async {
        s.updateBTReferenceBufferLocked()
        if FIX: s.refreshDriftTrackingLocked()
        # }

b=Backend()
b.btSelectedUIDs=["A","B"]; b.lat={"A":120.0,"B":80.0}; b.trim={"A":15.0}
b.refreshDriftTrackingLocked()
print("before:", b.driftTracker.running, b.driftTracker.baselines)
b.resetBTAlignment("A","drawer")
expected=b.btDriftBaselines(b.btSelectedUIDs,b.lat,b.trim,b.room)
print("after reset:", b.driftTracker.running, b.driftTracker.baselines, "expected baselines:", expected,
      "expected running:", b.driftTrackingRuns(len(expected),0))
ok = b.driftTracker.baselines==[] and not b.driftTracker.running
print("PASS" if ok else "FAIL: tracker still running with stale baseline for reset speaker A")
sys.exit(0 if ok else 1)
