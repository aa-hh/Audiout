# Faithful port of NativeBackend.applyStartBuffer / convergeToTarget / convergeDevice
# (desiredOn loop) / setOutputSet (desiredOn + kick part), asyncio for awaits.
import asyncio, sys
FIX = "--fix" in sys.argv
class Engine:
    def __init__(s): s.hook=None; s.outputs=set()
    async def setStartBufferMs(s, ms):
        await asyncio.sleep(0)
        if s.hook: s.hook()          # user deselects while this is awaited
    async def addOutput(s,o): await asyncio.sleep(0); s.outputs.add(o)
    async def removeOutput(s,o): await asyncio.sleep(0); s.outputs.discard(o)
class B:
    def __init__(s):
        s.engine=Engine(); s.added=set(); s.outputIDs={}; s.desiredOn={}
        s.converging=set(); s.expectedSelected=set(); s.failedGate=set(); s.order=[]; s.tasks=[]
    async def convergeDevice(s,id,oid):
        while True:
            want=s.desiredOn.get(id)
            if id in s.failedGate or want is None or want==(id in s.added):
                s.converging.discard(id); return
            if want: await s.engine.addOutput(oid); s.added.add(id)
            else: await s.engine.removeOutput(oid); s.added.discard(id)
    async def convergeToTarget(s,id,oid,target):
        if FIX and target and id not in s.expectedSelected: return   # proposed fix
        if target: s.failedGate.discard(id)
        s.desiredOn[id]=target
        if id in s.converging: return
        s.converging.add(id)
        await s.convergeDevice(id,oid)
    def setOutputSet(s,ids):
        s.expectedSelected=set(ids)
        for id in s.order:
            oid=s.outputIDs[id]; want=id in ids; prev=s.desiredOn.get(id); s.desiredOn[id]=want
            if prev!=want and id not in s.converging:
                s.converging.add(id); s.tasks.append(asyncio.ensure_future(s.convergeDevice(id,oid)))
    async def applyStartBuffer(s,ms):
        streaming=[(i,s.outputIDs[i]) for i in s.added if i in s.outputIDs]
        await asyncio.gather(*[s.convergeToTarget(i,o,False) for i,o in streaming])
        await s.engine.setStartBufferMs(ms)
        await asyncio.gather(*[s.convergeToTarget(i,o,True) for i,o in streaming])
async def main():
    b=B(); b.order=["A"]; b.outputIDs={"A":1}
    b.setOutputSet({"A"}); await asyncio.gather(*b.tasks)
    assert "A" in b.added
    b.engine.hook=lambda: b.setOutputSet(set())   # user deselects A mid-apply
    await b.applyStartBuffer(300); await asyncio.gather(*b.tasks)
    print("expectedSelected=",b.expectedSelected,"added=",b.added,"desiredOn=",b.desiredOn,"engine=",b.engine.outputs)
    assert "A" not in b.added and 1 not in b.engine.outputs, "FAIL: deselected A re-added and streaming"
    print("PASS")
asyncio.run(main())
