# Faithful port of NativeBackend.handlePerAppCaptureHealthChange (.failed branch)
# and the updateAppRoutes set computation (routed/local/leveled), Swift lines 324-376, 766-790.
import sys
FIX = "--fix" in sys.argv

class Backend:
    def __init__(s):
        s.routed=set(); s.local=set(); s.leveled=set()
        s.dead=set(); s.retryCounts={}; s.pendingRetries={}; s.scheduled=[]
        s.started=[]
    def wants(s,b): return b in s.routed or b in s.local or b in s.leveled
    def updateAppRoutes(s, routes, excluded=frozenset()):
        newRouted={r['b'] for r in routes if r['dest'][0] in ('device','group')}  # routedApps (reachable)
        newLocal={r['b'] for r in routes if r['dest'][0]=='currentDevice'}
        newLeveled={r['b'] for r in routes if r['dest'][0]=='noRedirect' and r['b'] not in excluded
                    and (r['vol']<100 or r['b'] in s.leveled)}
        prevU=s.routed|s.local|s.leveled
        s.routed,s.local,s.leveled=newRouted,newLocal,newLeveled
        for b in sorted((newRouted|newLocal|newLeveled)-prevU):
            s.started.append(b); s.onState(b, ('failed','processNotYetAudible'))  # paused app
    def onState(s,b,state):
        if state[0]=='failed':
            justDied = b not in s.dead; s.dead.add(b)
            gate = s.wants(b) if FIX else (b in s.routed)
            if not (gate and state[1]=='processNotYetAudible'):
                s.pendingRetries.pop(b,None); return
            a=s.retryCounts.get(b,0)+1; s.retryCounts[b]=a
            s.scheduled.append((b,a)); s.pendingRetries[b]=True

fails=0
for name,route in [("leveled",{'b':'com.app.paused','dest':('noRedirect',),'vol':40}),
                   ("currentDevice",{'b':'com.app.paused','dest':('currentDevice',),'vol':100}),
                   ("device(control)",{'b':'com.app.paused','dest':('device','d1'),'vol':100})]:
    be=Backend(); be.updateAppRoutes([route])
    ok = any(b=='com.app.paused' for b,_ in be.scheduled)
    print(f"{name}: dead={sorted(be.dead)} retryScheduled={ok} -> {'PASS' if ok else 'FAIL'}")
    fails += not ok
sys.exit(1 if fails else 0)
