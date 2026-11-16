# Faithful asyncio port of AirPlayEngine stop()/start() (actor reentrancy == await points).
import asyncio, sys
class Thread:
    def __init__(s): s.alive=True
    async def run(s, fn):
        await asyncio.sleep(0)   # hop to engine thread: suspension point
        await asyncio.sleep(0)
        fn()
    def stop(s): s.alive=False
class Engine:
    def __init__(s, fixed=False):
        s.started=False; s.starting=False; s.holder=None; s.cstr=None
        s.known={}; s.fixed=fixed; s.gen=0
    async def start(s):
        if s.started or s.starting: return
        s.starting=True
        try:
            t=Thread(); s.holder=t; s.gen+=1
            await t.run(lambda: None)          # init on engine thread
            s.cstr="conffile-strings"; s.known['dev']=1
            s.started=True
        finally: s.starting=False
    async def stop(s):
        if not s.started: return
        s.started=False
        t=s.holder
        if t: await t.run(lambda: None); t.stop()
        if s.fixed and s.holder is not t: return   # fix: a newer start() owns state
        s.holder=None; s.cstr=None; s.known.clear()
async def main(fixed):
    e=Engine(fixed)
    await e.start()
    st=asyncio.create_task(e.stop())
    await asyncio.sleep(0)       # stop() now suspended in engineThread.run
    await e.start()              # start() from another task
    await st
    assert e.started and e.holder is not None and e.holder.alive and e.cstr and e.known, \
        f"started={e.started} thread={e.holder} cstr={e.cstr} known={e.known}"
    print("PASS")
try: asyncio.run(asyncio.wait_for(main(len(sys.argv)>1),5))
except AssertionError as ex: print("FAIL:",ex); sys.exit(1)
