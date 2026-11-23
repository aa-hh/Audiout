import asyncio, sys, port
async def scenario():
    h = port.Helper(); act = port.SelfHealing(port.Inner(h), h)
    res = {}
    async def deviceB():  # Device B connects while A's cycle is between unregister() and register()
        res['B_task'] = asyncio.ensure_future(act.activate(10))
        await asyncio.sleep(0)
    h.on_unregister = deviceB
    a = await act.activate(10)
    b = await res['B_task']
    return a, b
a, b = asyncio.run(asyncio.wait_for(scenario(), 5))
print("A:", a, " B:", b)
ok = (b == "ready")
print("PASS" if ok else "FAIL: device B got %r mid-cycle (helper is approved; cycle succeeded)" % (b,))
sys.exit(0 if ok else 1)
