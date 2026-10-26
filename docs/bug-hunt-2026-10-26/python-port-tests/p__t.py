import asyncio,time,sys
S=0.1  # 1 virtual second = 0.1s
async def browse_one(t): await asyncio.sleep(t*S); return None   # absent: timeout path
async def browse(fix):
    types=["_airplay._tcp","_raop._tcp"]
    if fix:
        r=await asyncio.gather(*[browse_one(2.0) for _ in types]); return next((x for x in r if x),None)
    for _ in types:
        e=await browse_one(2.0)
        if e: return e
async def main(fix):
    t=time.monotonic(); await browse(fix); return (time.monotonic()-t)/S
fix=len(sys.argv)>1
d=asyncio.run(main(fix)); print("virtual secs",round(d,2))
assert d<2.5, "browse took %.1fs, doc says ~2s"%d
