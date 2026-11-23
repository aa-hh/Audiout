# Faithful port of SystemOutputVolume retarget/handleDeviceChangeLocked logic.
from collections import deque
UNKNOWN = 0
class HAL:
    def __init__(s): s.default=UNKNOWN; s.vol={}; s.mute={}; s.listeners={}; s.sys_listener=None; s.q=deque()
    def add(s,dev,blk): s.listeners.setdefault(dev,[]).append(blk)
    def remove(s,dev): s.listeners.pop(dev,None)
    def notify_dev(s,dev):  # HAL dispatch to queue (async)
        for b in list(s.listeners.get(dev,[])): s.q.append(b)
    def notify_default(s):
        if s.sys_listener: s.q.append(s.sys_listener)
    def drain(s):
        while s.q: s.q.popleft()()

class SystemOutputVolume:
    def __init__(s,hal,fixed=False): s.h=hal; s.lv=None; s.lm=None; s.reg=None; s.fired=[]; s.fixed=fixed
    def currentVolume(s):
        d=s.h.default; return None if d==UNKNOWN else s.h.vol.get(d)
    def currentMuted(s):
        d=s.h.default; return None if d==UNKNOWN else s.h.mute.get(d)
    def start(s):
        s.h.sys_listener=lambda: s.retarget(s.h.default,True); s.retarget(s.h.default,False)
    def retarget(s,dev,report):
        if s.reg is not None: s.h.remove(s.reg); s.reg=None
        if dev==UNKNOWN:
            s.lv=s.lm=None
            if report: s.fired.append((None,None,True)); return
            return
        s.reg=dev
        s.h.add(dev, (lambda d=dev: s.handle(d)))
        s.lv=s.h.vol.get(dev); s.lm=s.h.mute.get(dev)
        if report: s.fired.append((s.lv,s.lm,True))
    def handle(s,dev):
        if s.fixed and dev!=s.reg: return  # FIX: ignore notifications from a device we no longer target
        if s.fixed and s.h.default!=dev: return  # FIX: default moved; system listener will report
        v=s.currentVolume(); m=s.currentMuted()
        if not (v!=s.lv or m!=s.lm): return
        s.lv=v; s.lm=m; s.fired.append((v,m,False))
