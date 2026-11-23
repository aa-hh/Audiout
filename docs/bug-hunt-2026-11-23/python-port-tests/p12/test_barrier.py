# Port of NativeBackend.applyStartBuffer / convergeToTarget / convergeDevice (simplified)
# and the whole-system rebind recovery chain (resetAirPlaySessionForWholeSystem ->
# enqueueRebindRecovery -> performRebindRecovery remove->add -> releaseRebindConverging).
import asyncio, sys
FIX = "--fix" in sys.argv

class Engine:
    def __init__(s): s.start_buffer=100; s.attached={}; s.session_buf=None
    async def add(s, oid):
        await asyncio.sleep(0)
        if not s.attached: s.session_buf = s.start_buffer   # new master session reads buffer
        s.attached[oid] = s.session_buf
    async def remove(s, oid):
        await asyncio.sleep(0)
        s.attached.pop(oid, None)
        if not s.attached: s.session_buf = None
    async def set_start_buffer(s, ms):
        await asyncio.sleep(0); s.start_buffer = ms

class Backend:
    def __init__(s):
        s.e=Engine(); s.added=set(); s.desired={}; s.converging=set(); s.rebind_conv=set()
        s.outputIDs={}
    async def converge_device(s, id):
        try:
            while True:
                want = s.desired.get(id); have = id in s.added
                if want == have: return
                if want: await s.e.add(id); s.added.add(id)
                else: await s.e.remove(id); s.added.discard(id)
        finally:
            s.converging.discard(id)
    def release_rebind(s, id):           # releaseRebindConverging -> releaseConvergingAndRequeueIfNeeded
        s.rebind_conv.discard(id); s.converging.discard(id)
        if s.desired.get(id) is not None and s.desired[id] != (id in s.added):
            s.converging.add(id); return id
        return None
    async def rebind_chain(s, id, gate):  # performRebindRecovery: remove -> add, on bindTail
        await gate.wait()                 # chain queued behind an earlier op on bindTail
        await s.e.remove(id)
        await s.e.add(id)
        if id in s.added:                 # stillOwnsRebind(.wholeSystem)
            rq = s.release_rebind(id)
            if rq: asyncio.ensure_future(s.converge_device(rq))
        else:
            rq = s.release_rebind(id)
            if rq: asyncio.ensure_future(s.converge_device(rq))
    def reset_whole_system(s, gate):
        for id in list(s.added):
            if id in s.converging: continue
            s.converging.add(id); s.rebind_conv.add(id)
            asyncio.ensure_future(s.rebind_chain(id, gate))
    async def converge_to_target(s, id, on):
        while True:
            s.desired[id] = on
            if id not in s.converging:
                s.converging.add(id); break
            if not FIX: return              # current Swift: guard ... else { return false }
            await asyncio.sleep(0.001)       # fix: wait for the holder to release the slot
        await s.converge_device(id)
    async def apply_start_buffer(s, ms, gate):
        streaming = list(s.added)
        await asyncio.gather(*[s.converge_to_target(i, False) for i in streaming])
        await s.e.set_start_buffer(ms)
        await asyncio.gather(*[s.converge_to_target(i, True) for i in streaming])

async def main():
    b=Backend()
    for i in ("A","B"):
        b.desired[i]=True; await b.e.add(i); b.added.add(i)
    gate=asyncio.Event()
    # whole-system rebind recovery claims A's slot; its op waits on bindTail
    b.converging.add("A"); b.rebind_conv.add("A")
    asyncio.ensure_future(b.rebind_chain("A", gate))
    async def bindtail_prev():           # the earlier bindTail op finishes a little later
        await asyncio.sleep(0.02); gate.set()
    asyncio.ensure_future(bindtail_prev())
    await asyncio.sleep(0)
    await b.apply_start_buffer(300, gate)
    await asyncio.sleep(0.05)
    print("attached:", b.e.attached, "added:", sorted(b.added))
    bad = {k:v for k,v in b.e.attached.items() if v != 300}
    assert not bad, f"FAIL: outputs still on old-buffer session: {bad}"
    print("PASS")

asyncio.run(asyncio.wait_for(main(), 5))
