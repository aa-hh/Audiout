# Faithful port of CastOutputManager generation logic (setDevices, startRecipe,
# afterConnect, fail, teardown, teardownFinished, live). Manager `queue` and the
# channel's own network queue are explicit FIFOs driven deterministically.
import sys
from collections import deque
FIX = "--fix" in sys.argv

class Channel:
    def __init__(self, net): self.net=net; self.onClose=None; self.pending=None
    def connect(self, cb): self.pending=cb            # connect in flight
    def close(self):
        # closing a channel with a connect in flight fails it; the completion
        # is delivered on the channel's own queue (async), like NWConnection.
        cb=self.pending; self.pending=None
        if cb: self.net.append(lambda: cb(("failure","cancelled")))

class Session:
    def __init__(self, id): self.id=id; self.generation=0; self.state="idle"; self.channel=None; self.awaitingTeardown=False

class Manager:
    def __init__(self):
        self.q=deque(); self.net=deque(); self.sessions={}; self.inflight={}; self.log=[]; self.nextGen=0
    def setDevices(self, ids):
        def body():
            for id,s in list(self.sessions.items()):
                if id not in ids:
                    self.teardown(s); del self.sessions[id]; self.setState(s,"idle")
            for id in ids:
                if id not in self.sessions:
                    s=Session(id); self.sessions[id]=s
                    if id in self.inflight: s.awaitingTeardown=True; self.setState(s,"connecting")
                    else: self.startRecipe(s)
        self.q.append(body)
    def bump(self, s):
        if FIX: self.nextGen+=1; s.generation=self.nextGen
        else: s.generation+=1
    def startRecipe(self, s):
        self.bump(s); gen=s.generation; id=s.id
        self.setState(s,"connecting")
        ch=Channel(self.net); s.channel=ch
        ch.onClose=lambda err: self.q.append(lambda: None)
        ch.connect(lambda r: self.q.append(lambda: self.afterConnect(r,id,gen)))
    def afterConnect(self, r, id, gen):
        s=self.live(id,gen)
        if s is None: return
        if r[0]=="failure": self.fail(s, r[1]); return
    def fail(self, s, err): self.teardown(s); self.setState(s, "failed(%s)"%err)
    def teardown(self, s):
        self.inflight[s.id]=self.inflight.get(s.id,0)+1
        self.bump(s)
        ch=s.channel; s.channel=None
        if ch: ch.onClose=None
        # no client/application yet -> finish() synchronously
        if ch: ch.close()
        self.q.append(lambda: self.teardownFinished(s.id))
    def teardownFinished(self, id):
        if id not in self.inflight: return
        if self.inflight[id]>1: self.inflight[id]-=1; return
        del self.inflight[id]
        s=self.sessions.get(id)
        if not s or not s.awaitingTeardown: return
        s.awaitingTeardown=False; self.startRecipe(s)
    def live(self, id, gen):
        s=self.sessions.get(id)
        return s if s and s.generation==gen else None
    def setState(self, s, st):
        if s.state!=st: s.state=st; self.log.append((id(s),s.id,st))
    def drain_q(self):
        while self.q: self.q.popleft()()
    def drain_net(self):
        while self.net: self.net.popleft()()

m=Manager()
m.setDevices(["A"]); m.drain_q()              # select A: gen 1, connect pending
first=m.sessions["A"]
m.setDevices([]); m.setDevices(["A"])         # deselect then re-select A
m.drain_q()                                   # teardown, teardownFinished -> new startRecipe gen 1
m.drain_net(); m.drain_q()                    # old channel's connect failure hops onto queue
new=m.sessions["A"]
print("new session is a new object:", new is not first, " old gen", first.generation, " new gen", new.generation)
print("new session state:", new.state)
assert new.state=="connecting", "FAIL: late completion of the deselected attempt acted on the re-selected session -> "+new.state
print("PASS")
