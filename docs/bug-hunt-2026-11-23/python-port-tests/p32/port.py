# Faithful port of LocalPlaybackEngine addApp / startEngineOnGraphQueue /
# reestablishGraphOnGraphQueue / receive, against a fake AVAudioEngine whose
# rules mirror AVFoundation: engine.stop() stops every player; play() on a
# stopped engine raises; scheduleBuffer on a stopped player just queues.
import sys
FIX = "--fix" in sys.argv

class ObjCExc(Exception): pass

class Player:
    def __init__(s, eng): s.eng=eng; s.playing=False; s.queued=0; s.connected=False
    def play(s):
        if s.eng.fail_next_play or not s.eng.isRunning:
            s.eng.fail_next_play=False; s.eng.isRunning=False  # engine stopped under us
            for p in s.eng.players: p.playing=False
            raise ObjCExc("play on stopped engine")
        s.playing=True
    def scheduleBuffer(s): s.queued+=1
    def stop(s): s.playing=False; s.queued=0

class Engine:
    def __init__(s): s.isRunning=False; s.players=[]; s.fail_next_play=False
    def attach(s,p): s.players.append(p)
    def detach(s,p): s.players.remove(p)
    def connect(s,p): p.connected=True
    def start(s): s.isRunning=True
    def stop(s):
        s.isRunning=False
        for p in s.players: p.playing=False

class LPE:
    def __init__(s): s.engine=Engine(); s.nodes={}; s.engineRunning=False
    def startEngine(s):
        if s.engineRunning: return
        s.engine.start(); s.engineRunning=s.engine.isRunning
    def reestablish(s, snap):
        for n in snap.values():
            try: s.engine.connect(n)
            except ObjCExc: s.engineRunning=False; return
        s.engine.start(); s.engineRunning=s.engine.isRunning
        if not s.engineRunning: return
        for n in snap.values():
            try: n.play()
            except ObjCExc: s.engineRunning=False; return
    def configChange(s):
        snap=dict(s.nodes)
        if not snap: s.engineRunning=False; return
        s.engineRunning=False
        s.engine.stop()   # AVAudioEngine has already stopped itself
        s.reestablish(snap)
    def addApp(s, bid):
        if bid in s.nodes: return
        wasRunning, existing = s.engineRunning, dict(s.nodes)  # FIX snapshot
        p=Player(s.engine); s.engine.attach(p); s.engine.connect(p)
        s.startEngine()
        if not s.engine.isRunning: s.engine.detach(p); raise RuntimeError("engineNotRunning")
        s.nodes[bid]=p
        p.play()
        if FIX and not wasRunning:
            for n in existing.values():
                try: s.engine.connect(n); n.play()
                except ObjCExc: pass
    def receive(s, bid):
        n = s.nodes.get(bid) if s.engineRunning else None
        if n is None: return
        n.scheduleBuffer()

e=LPE()
e.addApp("A")
e.engine.fail_next_play=True
e.configChange()            # replay play() raises -> engineRunning=False, A in nodes
e.addApp("B")
for _ in range(1000): e.receive("A")
A=e.nodes["A"]
print(f"engineRunning={e.engineRunning} A.playing={A.playing} A.queued={A.queued} B.playing={e.nodes['B'].playing}")
ok = A.playing
print("PASS" if ok else "FAIL: A stopped while receive() queued", A.queued, "buffers into it")
sys.exit(0 if ok else 1)
