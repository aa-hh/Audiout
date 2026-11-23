# Port of NativeBackend+PerAppRouting.swift: updateAppRoutes (leveled parts, ~L293-560),
# handleAppTerminated (L1503), handleAppLaunched (L1557), LeveledAppInjector.updateLeveled/handleBuffer.
import sys
FIX = "--fix" in sys.argv
class Injector:
    def __init__(s): s.vol = {}; s.conv = set(); s.active = False
    def updateLeveled(s, apps): s.vol = dict(apps)
    def setActive(s, a): s.active = a
    def handleStateChange(s, b, capturing):
        (s.conv.add if capturing else s.conv.discard)(b)
    def handleBuffer(s, b):  # True = audio injected into program
        return s.active and b in s.vol and b in s.conv
class Backend:
    def __init__(s):
        s.leveled=set(); s.dead=set(); s.captureRunning=True; s.lastRoutes=[]
        s.inj=Injector(); s.taps=set(); s.sysExcluded=set()
    def tapStart(s,b): s.taps.add(b); s.inj.handleStateChange(b,True)
    def tapStop(s,b): s.taps.discard(b); s.inj.handleStateChange(b,False)
    def updateAppRoutes(s, routes, excluded=frozenset()):
        s.lastRoutes = routes
        newLeveled = {b for (b,d,v) in routes if d=='noRedirect' and b not in excluded
                      and (v<100 or b in s.leveled)}
        prev = s.leveled; s.leveled = newLeveled
        present = {b for (b,_,_) in routes}
        s.dead = {b for b in s.dead if b in present}
        leveledRoutes = [(b,v) for (b,d,v) in routes if b in newLeveled and b not in s.dead]
        for b in newLeveled - prev: s.tapStart(b)
        for b in prev - newLeveled: s.tapStop(b)
        s.inj.updateLeveled(leveledRoutes); s.inj.setActive(s.captureRunning)
        s.sysExcluded = set(excluded) | newLeveled
    def handleAppTerminated(s,b):
        if b not in s.leveled: return
        s.tapStop(b); s.dead.add(b)
    def handleAppLaunched(s,b):
        if b not in s.leveled: return
        s.dead.discard(b)
        s.tapStart(b)
        # republishMixerTopology(): mixer only, no injector change
        if FIX:
            s.inj.updateLeveled([(r,v) for (r,d,v) in s.lastRoutes
                                 if r in s.leveled and r not in s.dead])
    def audible(s,b):  # muted tap: only path to the program is the injector
        if b in s.sysExcluded or b in s.taps: return s.inj.handleBuffer(b)
        return True
be = Backend()
routes=[("L","noRedirect",40)]
be.updateAppRoutes(routes)
assert be.audible("L"), "precondition"
be.handleAppTerminated("L")
be.updateAppRoutes(routes)   # e.g. rerunAppRoutesForReachabilityChange while L is quit
be.handleAppLaunched("L")
ok = be.audible("L")
print("L excluded from system tap:", "L" in be.sysExcluded, "| L muted-tapped:", "L" in be.taps,
      "| injector volumes:", be.inj.vol)
print("PASS: relaunched leveled app audible" if ok else "FAIL: relaunched leveled app silent")
sys.exit(0 if ok else 1)
