# Port of enqueueRebindRecovery(.perApp) -> performRebindRecovery and convergeDevice
# (NativeBackend+PerAppRouting.swift ~1000-1300, NativeBackend.swift ~3540).
import asyncio, sys
FIX = "--fix" in sys.argv

class Engine:
    def __init__(s): s.bound = {}; s.log = []
    async def boundStreamId(s, o): await asyncio.sleep(0); return s.bound.get(o)
    async def removeOutput(s, o): await asyncio.sleep(0); s.log.append(("remove", o)); s.bound.pop(o, None)
    async def addOutput(s, o, stream):
        await asyncio.sleep(0); s.log.append(("add", o, stream))
        s.bound.setdefault(o, stream)   # alreadyBound -> silent no-op
    async def rebindOutput(s, o, stream): await asyncio.sleep(0); s.log.append(("rebind", o, stream)); s.bound[o] = stream

class Backend:
    def __init__(s):
        s.engine = Engine(); s.D = "D"; s.out = 7
        s.streamBindings = {"D": 1}; s.desiredOn = {}; s.converging = set(); s.added = set()
        s.rebindRecoveryGen = {"D": 1}; s.ptp = asyncio.Event()
    def wsClaimed(s, i): return s.desiredOn.get(i) is True or i in s.converging or i in s.added
    def stillOwnsRebind(s, i, stream): return s.streamBindings.get(i) == stream and not s.wsClaimed(i)
    async def ensurePTPTakeover(s): await s.ptp.wait(); return True
    async def bindOutput(s, o, stream):
        live = await s.engine.boundStreamId(o)
        if live is not None:
            if live != stream: await s.engine.rebindOutput(o, stream)
            return
        await s.engine.addOutput(o, stream)
    async def performRebindRecovery(s, stream):
        await s.ensurePTPTakeover()
        if FIX and not s.stillOwnsRebind(s.D, stream):   # proposed fix
            return False
        s.claim_at_fire = s.wsClaimed(s.D)
        await s.engine.removeOutput(s.out)
        await s.engine.addOutput(s.out, stream)
        return True
    async def recoveryChain(s, gen, stream):
        s.claim_at_fire = None
        if s.rebindRecoveryGen.get(s.D) == gen and s.stillOwnsRebind(s.D, stream):  # preflight
            await s.performRebindRecovery(stream)
    def setOutputSet(s, ids):
        s.desiredOn["D"] = "D" in ids; s.converging.add("D")
        return asyncio.ensure_future(s.convergeDevice())
    async def convergeDevice(s):
        await s.ensurePTPTakeover()
        await s.bindOutput(s.out, 0)
        s.added.add("D"); s.converging.discard("D")

async def main():
    b = Backend(); b.engine.bound[b.out] = 1
    rec = asyncio.ensure_future(b.recoveryChain(1, 1))
    await asyncio.sleep(0)                 # recovery now parked in ensurePTPTakeover
    conv = b.setOutputSet({"D"})           # user selects D whole-system mid-wait
    await asyncio.sleep(0); b.ptp.set()
    await asyncio.gather(rec, conv)
    print("engine log:", b.engine.log, "| bound:", b.engine.bound, "| added:", b.added)
    perapp_ops = [e for e in b.engine.log if e == ("remove", 7) or e == ("add", 7, 1)]
    assert not perapp_ops, f"FAIL: per-app recovery fired {perapp_ops} on a whole-system-claimed device (claimed at fire={b.claim_at_fire})"
    print("PASS")
asyncio.run(main())
