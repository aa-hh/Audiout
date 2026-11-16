# Port of browseOne. Swift withTaskGroup awaits ALL children before returning;
# cancelAll only sets cancel flag; withCheckedContinuation is not cancellation-aware
# (modelled by asyncio.shield on the future). Simplification: NWBrowser is a fake.
import asyncio, sys
class Browser:
    def __init__(s): s.state=None
    def start(s): pass
    def cancel(s):  # real NWBrowser delivers .cancelled to the handler
        if s.state: s.state("cancelled")
async def browse_one(timeout, fixed):
    loop=asyncio.get_running_loop(); b=Browser(); fut=loop.create_future()
    def state(st):
        if st=="failed" or (fixed and st=="cancelled"):
            if not fut.done(): fut.set_result(None)
    b.state=state
    async def child1():  # continuation ignores cancellation: keep waiting on fut
        while True:
            try: return await asyncio.shield(fut)
            except asyncio.CancelledError: continue
    async def child2(): await asyncio.sleep(timeout); return None
    tasks=[asyncio.ensure_future(child1()),asyncio.ensure_future(child2())]
    done,_=await asyncio.wait(tasks,return_when=asyncio.FIRST_COMPLETED)  # group.next()
    for t in tasks: t.cancel()          # cancelAll
    b.cancel()
    # group exit: await all children (swallow cancellation like Swift child that ignores it)
    await asyncio.gather(*tasks,return_exceptions=True)
    return None
async def main(fixed):
    try: await asyncio.wait_for(browse_one(0.2,fixed),3); print("OK returned"); return 0
    except asyncio.TimeoutError: print("FAIL: hung (>3s)"); return 1
sys.exit(asyncio.run(main(len(sys.argv)>1)))
