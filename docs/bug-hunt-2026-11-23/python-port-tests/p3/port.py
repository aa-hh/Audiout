# Faithful port of NativeCaptureCoordinator start()/recreateTap()/updateRouting() gating.
# FIX=1 applies the proposed fix.
import os, sys
FIX = os.environ.get("FIX") == "1"

class Tap:
    def __init__(self, coord): self.coord = coord; self.excluded = None
    def createAndStart(self, excluded):
        self.excluded = set(excluded)
        hook = self.coord.during_create; self.coord.during_create = None
        if hook: hook()   # concurrent caller lands while state == creatingTap

class Coalescer:
    def __init__(self): self.pending = False
    def markPending(self): self.pending = True
    def takePending(self):
        p = self.pending; self.pending = False; return p

class Coord:
    def __init__(self):
        self.state = "idle"; self.tap = None; self.current = set()
        self.coal = Coalescer(); self.during_create = None; self.rebuilds = 0
    def resolve(self): return set(self.current)
    def start(self):
        if self.state not in ("idle", "failed"): return
        self.state = "creatingTap"; excl = self.resolve()
        t = Tap(self); t.createAndStart(excl)
        replay = False
        if self.state == "creatingTap":
            self.tap = t; self.state = "capturing"
            if FIX: replay = self.coal.takePending()
        if replay: self.recreateTap("exclusionChange")
    def recreateTap(self, cause):
        if self.state != "capturing":
            if self.state == "creatingTap": self.coal.markPending()
            return
        self.tap = None; self.state = "creatingTap"; excl = self.resolve(); self.rebuilds += 1
        t = Tap(self); t.createAndStart(excl)
        replay = False
        if self.state == "creatingTap":
            self.tap = t; self.state = "capturing"; replay = self.coal.takePending()
        if replay: self.recreateTap("deviceOrRateChange")
    def updateRouting(self, appRoutes, excludedBundleIDs):
        routed = {b for b, dest in appRoutes if dest in ("device", "group")}
        union = routed | excludedBundleIDs
        if union == self.current: return
        self.current = union
        capturing = self.state == "capturing"
        if not capturing and FIX and self.state == "creatingTap":
            self.coal.markPending()
        if capturing: self.recreateTap("exclusionChange")

def check(name, c):
    ok = "com.spotify.client" in c.tap.excluded
    print(f"{name}: tap excludes Spotify={ok} (current={sorted(c.current)}, tap={sorted(c.tap.excluded)})")
    return ok

route = [("com.spotify.client", "device")]
# Case 1: initial start in flight
c = Coord(); c.during_create = lambda: c.updateRouting(route, set()); c.start()
r1 = check("start-in-flight", c)
# Case 2: recreate in flight (e.g. device change)
c = Coord(); c.start(); c.during_create = lambda: c.updateRouting(route, set()); c.recreateTap("deviceOrRateChange")
r2 = check("recreate-in-flight", c)
sys.exit(0 if (r1 and r2) else 1)
