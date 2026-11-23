# Faithful port of NativeBackend.applyBTSnapshots (+ beginBTConnectingLocked,
# btArmingLocked, reapplyBTSinkLocked, markBTDeviceLostLocked) state logic.
import sys
FIX = "--fix" in sys.argv

class Backend:
    def __init__(s):
        s.known = {}; s.order = []; s.expectedSelected = set()
        s.btPerAppClaimedUIDs = []; s.btSelectedUIDs = []; s.btSinkEnabled = False
        s.state = {}; s.deadlines = {}; s.applied = []  # sink transitions applied
    def setConnectionState(s, st, id): s.state[id] = st
    def beginBTConnectingLocked(s, id, perApp=False):
        claimed = id in s.btPerAppClaimedUIDs if perApp else id in s.expectedSelected
        if not (claimed and s.known.get(id, {}).get("bt")): return
        s.setConnectionState("connecting", id); s.deadlines[id] = 1
    def btArmingLocked(s):
        return (s.btSinkEnabled or bool(s.btPerAppClaimedUIDs),
                sorted(u for u in set(s.btSelectedUIDs) | set(s.btPerAppClaimedUIDs)
                       if s.known.get(u, {}).get("avail") is not False))
    def reapplyBTSinkLocked(s):
        armed, uids = s.btArmingLocked()
        if not armed: return
        s.applied.append(uids)
    def markBTDeviceLostLocked(s, id):
        d = s.known[id]; d["avail"] = False; s.deadlines.pop(id, None)
        if s.state.get(id) != "failed": s.setConnectionState("off", id)
    def claimed(s, id):
        return id in s.expectedSelected or (FIX and id in s.btPerAppClaimedUIDs)
    def applyBTSnapshots(s, snaps):
        seen = set(); moved = False
        for id, connected in snaps:
            seen.add(id)
            ex = s.known[id]
            if ex["avail"] != connected:
                if s.claimed(id): moved = True
                ex["avail"] = connected
                if connected:
                    if id in s.expectedSelected: s.beginBTConnectingLocked(id)
                    elif FIX and id in s.btPerAppClaimedUIDs: s.beginBTConnectingLocked(id, perApp=True)
                    else: s.setConnectionState("off", id)
                else:
                    s.markBTDeviceLostLocked(id)
        if moved: s.reapplyBTSinkLocked()

b = Backend()
b.known["X"] = {"bt": True, "avail": True}; b.order = ["X"]
b.btPerAppClaimedUIDs = ["X"]  # per-app route targets X; not selected whole-system
b.state["X"] = "connected"
b.applyBTSnapshots([("X", False)])
b.applyBTSnapshots([("X", True)])
print("state:", b.state["X"], "reapplies:", b.applied)
ok = b.state["X"] == "connecting" and b.applied and "X" in b.applied[-1]
print("PASS" if ok else "FAIL: per-app speaker back up but state=%s, sink never rebuilt" % b.state["X"])
sys.exit(0 if ok else 1)
