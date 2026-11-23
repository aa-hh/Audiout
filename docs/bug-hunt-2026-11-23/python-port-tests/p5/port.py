# Faithful port of PerAppCaptureCoordinator start/beginStart/handleDeviceChange
# (PerAppCaptureCoordinator.swift:322-341, 400-450, 497-628) and TapRebuildCoalescer.
import threading
FIX = False
class Coalescer:
    def __init__(s): s.pending=False
    def markPending(s): s.pending=True
    def takePending(s):
        p=s.pending; s.pending=False; return p
class Slot:
    def __init__(s): s.state=('idle',); s.tap=None; s.co=Coalescer()
class World:  # the HAL: current default output device
    device='A'
class FakeTap:
    built=[]
    def __init__(s, world, fire_in_window): s.world=world; s.fire=fire_in_window; s.onDefaultDeviceChanged=None; s.device=None
    def createAndStart(s):
        s.device=s.world.device   # aggregate pinned to current default
        FakeTap.built.append(s.device)
        # subscribeToDefaultOutput (line 1120) happened; now the default moves
        if s.fire:
            s.fire=False; s.world.device='B'; s.onDefaultDeviceChanged()
        return 48000
    def teardown(s): pass
class Coord:
    def __init__(s, world, fire_first):
        s.q=threading.RLock(); s.slots={}; s.world=world; s.fire_first=fire_first
    def makeTap(s):
        f=s.fire_first; s.fire_first=False; return FakeTap(s.world,f)
    def start(s,b):
        with s.q:
            sl=s.slots.setdefault(b,Slot())
            if sl.state[0] in('idle','failed'): sl.state=('resolvingProcess',)
            else: return
        s.beginStart(b)
    def beginStart(s,b):
        with s.q:
            sl=s.slots.get(b)
            if not sl or sl.state[0]!='resolvingProcess': return
            sl.state=('creatingTap',)
        tap=s.makeTap(); tap.onDefaultDeviceChanged=lambda: s.handleDeviceChange(b)
        fmt=tap.createAndStart()
        replay=False
        with s.q:
            sl=s.slots.get(b)
            if not sl or sl.state[0]!='creatingTap': tap.teardown(); return
            sl.tap=tap; sl.state=('capturing',fmt)
            if FIX: replay=sl.co.takePending()
        if replay: s.handleDeviceChange(b)
    def handleDeviceChange(s,b):
        with s.q:
            sl=s.slots.get(b)
            if not sl: return
            if sl.state[0]!='capturing':
                if sl.state[0]=='creatingTap': sl.co.markPending()
                return
            old=sl.tap; sl.tap=None; sl.state=('creatingTap',)
        old.teardown()
        nt=s.makeTap(); nt.onDefaultDeviceChanged=lambda: s.handleDeviceChange(b)
        fmt=nt.createAndStart()
        with s.q:
            sl=s.slots.get(b)
            if not sl or sl.state[0]!='creatingTap': nt.teardown(); return
            sl.tap=nt; sl.state=('capturing',fmt); replay=sl.co.takePending()
        if replay: s.handleDeviceChange(b)
