# Port of NativeBackend.applyStartBuffer's final re-push + pushVolume/issueVolumePush
# serialization. Engine fake records concurrent setVolume calls per output.
import asyncio, sys
FIX = "--fix" in sys.argv

class Engine:
    def __init__(s): s.inflight={}; s.max_conc=0; s.log=[]
    async def setVolume(s, oid, v):
        s.inflight[oid]=s.inflight.get(oid,0)+1
        s.max_conc=max(s.max_conc,s.inflight[oid]); s.log.append((oid,v))
        await asyncio.sleep(0.01)   # engine op takes time (virtual, small)
        s.inflight[oid]-=1

class Backend:
    def __init__(s, eng):
        s.engine=eng; s.volumeInFlight=set(); s.volumePending={}
        s.added={"A"}; s.outputIDs={"A":1}; s.known={"A":50}; s.muted=set(); s.stashed={}
    def engineVolume(s, ui): return ui/100.0
    # pushVolume (on stateQueue; single-threaded loop stands in for the serial queue)
    def pushVolume(s, oid, val, completion=None):
        if oid in s.volumeInFlight:
            prev=s.volumePending.get(oid); s.volumePending[oid]=(val,completion)
            if prev and prev[1]: prev[1](False)
            return
        s.volumeInFlight.add(oid); s.issue(oid,val,completion)
    def issue(s, oid, val, completion):
        async def t():
            await s.engine.setVolume(oid,val)
            nxt=s.volumePending.pop(oid,None)
            if nxt: s.issue(oid,nxt[0],nxt[1])
            else: s.volumeInFlight.discard(oid)
            if completion: completion(True)
        asyncio.get_event_loop().create_task(t())
    # public setVolume (user slider)
    def setVolume(s, ui, id="A"):
        s.known[id]=ui; s.pushVolume(s.outputIDs[id], s.engineVolume(ui))
    async def applyStartBuffer(s):
        # (teardown/re-add elided: they don't touch volume — seed suppressed by bufferReAdding)
        await asyncio.sleep(0)
        toPush=[(s.outputIDs[i], s.engineVolume(0 if i in s.muted else s.stashed.get(i,s.known[i]))) for i in s.added]
        for oid,val in toPush:
            if not FIX:
                await s.engine.setVolume(oid,val)          # current code: direct call
            else:
                fut=asyncio.get_event_loop().create_future()
                s.pushVolume(oid,val,lambda ok: fut.done() or fut.set_result(ok))
                await fut

async def main():
    eng=Engine(); b=Backend(eng)
    task=asyncio.create_task(b.applyStartBuffer())
    await asyncio.sleep(0.002)          # re-push is in flight...
    b.setVolume(70)                     # ...user drags the slider
    await task; await asyncio.sleep(0.05)
    print("max concurrent setVolume for output 1:", eng.max_conc, "log:", eng.log)
    assert eng.max_conc<=1, "FAIL: two setVolume calls in flight for one output"
    print("PASS")
asyncio.run(main())
