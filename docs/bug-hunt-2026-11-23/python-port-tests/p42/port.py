# Faithful port of CastOutputManager drop/reconnect/fail path (virtual-time serial queue).
import heapq, sys
FIXED = "--fixed" in sys.argv

class Q:
    def __init__(s): s.t=0; s.h=[]; s.n=0
    def async_(s,f,d=0): s.n+=1; heapq.heappush(s.h,(s.t+d,s.n,f))
    def run(s,limit=1000):
        while s.h and limit:
            limit-=1; s.t,_,f=heapq.heappop(s.h); f()

class Channel:  # fake receiver: connect results scripted
    def __init__(s,rx): s.rx=rx; s.onClose=None
    def connect(s,cb): s.rx.connects+=1; cb(s.rx.connect_results.pop(0) if s.rx.connect_results else "ok")
    def close(s): pass

class Receiver:
    def __init__(s,results): s.connect_results=list(results); s.connects=0

class Session:
    def __init__(s): s.generation=0; s.state="idle"; s.autoRetryCount=0; s.channel=None; s.states=[]

class Manager:
    def __init__(s,rx,reconnectDelay=2):
        s.q=Q(); s.rx=rx; s.reconnectDelay=reconnectDelay; s.sessions={}; s.tif={}
    def setState(s,se,st):
        if se.state!=st: se.state=st; se.states.append(st)
    def live(s,id,g):
        se=s.sessions.get(id); return se if se and se.generation==g else None
    def startRecipe(s,se):
        se.generation+=1; g=se.generation; id="tv"
        s.setState(se,"connecting")
        ch=Channel(s.rx); se.channel=ch
        ch.onClose=lambda err: s.q.async_(lambda: s.handleDrop(id,g,err))
        ch.connect(lambda r: s.q.async_(lambda: s.afterConnect(r,id,g)))
    def afterConnect(s,r,id,g):
        se=s.live(id,g)
        if not se: return
        if r!="ok": s.fail(se,r,"connect"); return
        # rest of recipe collapsed: receiver status/launch/load -> PLAYING
        se.autoRetryCount=0; s.setState(se,"playing")
    def handleDrop(s,id,g,reason):
        se=s.live(id,g)
        if not se: return
        s.teardown(se); se.autoRetryCount+=1
        if not se.autoRetryCount<=3: s.setState(se,("failed","dropped",reason)); return
        s.setState(se,"connecting"); waiting=se.generation
        def later():
            se2=s.live(id,waiting)
            if se2: s.startRecipe(se2)
        s.q.async_(later,s.reconnectDelay)
    def fail(s,se,err,stage):
        if FIXED and 1<=se.autoRetryCount<3:
            s.handleDrop("tv",se.generation,err); return
        s.teardown(se); s.setState(se,("failed",stage,err))
    def teardown(s,se):
        se.generation+=1
        if se.channel: se.channel.onClose=None; se.channel=None

def test_drop_then_first_reconnect_connect_fails():
    rx=Receiver(["ok","connectionFailed: refused (rebooting)","ok"])
    m=Manager(rx); se=Session(); m.sessions["tv"]=se
    m.q.async_(lambda: m.startRecipe(se)); m.q.run()
    assert se.state=="playing"
    ch=se.channel; m.q.async_(lambda: ch.onClose("closed")); m.q.run(); 
    print("states:",se.states,"connects:",rx.connects)
    assert se.state=="playing", f"run ended after one failed reconnect: {se.state} (connects={rx.connects})"
    print("PASS")

test_drop_then_first_reconnect_connect_fails()
