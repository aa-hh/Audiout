import threading, sys
# Faithful port: LogStreamProcess (process slot, guard) + Watcher gen/running logic. Child = fake with manual exit.
class Child:
    def __init__(s): s.alive=True
class Spawn:
    def __init__(s): s.lock=threading.Lock(); s.process=None; s.launches=0; s.term=None
    def start(s,onTerm):
        with s.lock:
            if s.process is not None: return   # line 99
            c=Child(); s.launches+=1; s.process=c; s.term=(c,onTerm)
    def stop(s):
        with s.lock: p=s.process
        with s.lock: s.process=None
    def child_exits(s):
        c,h=s.term; c.alive=False
        with s.lock:
            if s.process is c: s.process=None
        h()
class W:
    def __init__(s,sp): s.sp=sp; s.running=False; s.gen=0
    def start(s):
        if s.running: return
        s.running=True; s.gen+=1; s.spawn()
    def stop(s): s.running=False; s.gen+=1; s.sp.stop()
    def spawn(s):
        g=s.gen; s.sp.start(lambda: s.term(g))
    def term(s,g):
        if s.running and g==s.gen: s.spawn()  # respawn (backoff elided)
sp=Spawn(); w=W(sp)
w.start(); w.stop(); w.start()   # old child still exiting
sp.child_exits()                  # old child dies late
assert sp.process is not None and sp.process.alive, "no live child after stop()+start(): watcher dead (running=%s launches=%d)"%(w.running,sp.launches)
print("PASS")
