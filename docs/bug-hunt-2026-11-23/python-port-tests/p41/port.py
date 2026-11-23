# Faithful port of CastOutputManager setDevices/retry/teardown/teardownFinished/startRecipe/fail.
# Serial queue = FIFO list; receiver STOP replies are held until the test releases them.
import sys
FIX = '--fix' in sys.argv
class Channel:
    n=0
    def __init__(s): Channel.n+=1; s.name=f"ch{Channel.n}"; s.closed=False; s.onClose=None
    def close(s): s.closed=True
class Client:
    def __init__(s,log): s.log=log; s.pending=[]
    def stopApplication(s,cb): s.log.append("STOP"); s.pending.append(cb)
class Session:
    def __init__(s,id): s.id=id; s.channel=None; s.client=None; s.application=None; s.generation=0; s.awaitingTeardown=False; s.state='idle'
class Mgr:
    def __init__(s): s.q=[]; s.sessions={}; s.tif={}; s.log=[]; s.channels=[]; s.clients=[]
    def run(s):
        while s.q: s.q.pop(0)()
    def setDevices(s,ids):
        def body():
            for id in list(s.sessions):
                if id not in ids: s.teardown(s.sessions[id]); del s.sessions[id]
            for id in ids:
                if id not in s.sessions:
                    se=Session(id); s.sessions[id]=se
                    if id in s.tif: se.awaitingTeardown=True; se.state='connecting'
                    else: s.startRecipe(se)
        s.q.append(body)
    def retry(s,id):
        def body():
            se=s.sessions.get(id)
            if not se: return
            s.teardown(se)
            if FIX and id in s.tif:
                se.awaitingTeardown=True; se.state='connecting'
            else:
                s.startRecipe(se)
        s.q.append(body)
    def startRecipe(s,se):
        se.generation+=1; se.state='connecting'
        ch=Channel(); se.channel=ch; s.channels.append(ch)
        se.client=Client(s.log); s.clients.append(se.client)
        s.log.append(f"LAUNCH-path connect {ch.name} (tif={s.tif.get(se.id,0)})")
        # pretend connect+launch succeeded synchronously so a later teardown has app to STOP
        se.application='app'
    def fail(s,se): s.teardown(se); se.state='failed'
    def teardown(s,se):
        id=se.id; s.tif[id]=s.tif.get(id,0)+1; se.generation+=1
        ch,cl,app=se.channel,se.client,se.application
        se.channel=se.client=se.application=None
        def finish():
            if ch: ch.close()
            s.q.append(lambda: s.teardownFinished(id))
        if cl is None or app is None: finish(); return
        cl.stopApplication(lambda: finish())
    def teardownFinished(s,id):
        r=s.tif.get(id)
        if r is None: return
        if r>1: s.tif[id]=r-1; return
        del s.tif[id]
        se=s.sessions.get(id)
        if not se or not se.awaitingTeardown: return
        se.awaitingTeardown=False; s.startRecipe(se)
    def releaseStops(s):
        for c in s.clients:
            while c.pending: c.pending.pop(0)()
        s.run()

ok=True
# Scenario A: deselect while playing, reselect (awaitingTeardown), user retries the connecting row, STOP answers.
m=Mgr(); m.setDevices(['tv']); m.run(); m.setDevices([]); m.run(); m.setDevices(['tv']); m.run()
assert m.sessions['tv'].awaitingTeardown
m.retry('tv'); m.run()
launches_during_stop=[l for l in m.log if 'connect' in l and '(tif=0)' not in l]
m.releaseStops()
se=m.sessions['tv']
live=[c for c in m.channels if not c.closed]
print("A log:", m.log)
print("A open channels:", [c.name for c in live], "session holds:", se.channel.name if se.channel else None)
if len(live)!=1: print("FAIL A: leaked channel(s)", [c.name for c in live if c is not se.channel]); ok=False
if launches_during_stop: print("FAIL A: recipe started while STOP in flight:", launches_during_stop); ok=False
# Scenario B: session fails (STOP chain running), user hits retry immediately.
m=Mgr(); m.setDevices(['tv']); m.run(); m.q.append(lambda: m.fail(m.sessions['tv'])); m.run()
m.retry('tv'); m.run()
bad=[l for l in m.log if 'connect' in l and '(tif=0)' not in l]
m.releaseStops()
print("B log:", m.log)
if bad: print("FAIL B: recipe started while STOP in flight:", bad); ok=False
if sum(1 for c in m.channels if not c.closed)!=1: print("FAIL B: channel count"); ok=False
print("PASS" if ok else "FAILED"); sys.exit(0 if ok else 1)
