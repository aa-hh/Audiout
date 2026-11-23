# Faithful port of MockBackend.start()/updateLocalDeviceName (MockBackend.swift:199-230, 542-548)
import sys
FIX = "--fix" in sys.argv
class Obs:
    def __init__(s, name): s.currentDeviceName=name; s.onChange=None
    def start(s): pass
class Mock:
    def __init__(s, fleet, stagger=True, obs=None):
        s.fleet=fleet; s.stagger=stagger; s.obs=obs; s.live={}; s.started=False; s.events=[]; s.pending=[]
    def emit(s,e): s.events.append(e)
    def delayClock(s, delay, work): s.pending.append((delay, work))
    def start(s):
        if s.started: return
        s.started=True
        for i,d in enumerate(s.fleet):
            if s.stagger:
                def work(d=d):
                    if not s.started or d['id'] in s.live: return
                    dev=dict(d)
                    if FIX and dev['isLocal'] and s.obs: dev['name']=s.obs.currentDeviceName  # fix
                    s.live[d['id']]=dev; s.emit(('added',dict(dev)))
                s.delayClock(0.2+i*0.35, work)
            else:
                if d['id'] in s.live: continue
                s.live[d['id']]=dict(d); s.emit(('added',dict(d)))
        if s.obs:
            s.obs.onChange=lambda n: s.updateLocal(n)
            s.obs.start()
            s.updateLocal(s.obs.currentDeviceName)
    def updateLocal(s,name):
        dev=next((d for d in s.live.values() if d['isLocal']),None)
        if dev is None: return
        if dev['name']==name: return
        dev['name']=name; s.emit(('updated',dict(dev)))
    def run_clock(s):
        for _,w in sorted(s.pending,key=lambda p:p[0]): w()
        s.pending=[]
fleet=[{'id':'local-mac','name':'MacBook Pro Speakers','isLocal':True},{'id':'sonos-move','name':'Sonos Move','isLocal':False}]
obs=Obs("External Headphones")
m=Mock(fleet,obs=obs); m.start(); m.run_clock()
got=m.live['local-mac']['name']
print("local-mac name after discovery:", got)
assert got=="External Headphones", f"FAIL: expected 'External Headphones', got {got!r}"
print("PASS")
