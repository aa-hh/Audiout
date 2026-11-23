# Port of NativeDiscovery.start/stop + NetworkFrameworkBrowser.start/stop/makeBrowser,
# driven through NativeBackend.start/stop with the engine.start() await still pending.
import sys
FIX = "--fix" in sys.argv
class Q:  # serial DispatchQueue, drained explicitly
    def __init__(s): s.items=[]
    def async_(s,f): s.items.append(f)
    def drain(s):
        while s.items: s.items.pop(0)()
class NWBrowser:
    live=[]
    def __init__(s): s.cancelled=False
    def start(s): NWBrowser.live.append(s)
    def cancel(s): s.cancelled=True
class NFBrowser:
    def __init__(s): s.queue=Q(); s.browsers={}
    def start(s):
        s.queue.async_(lambda: (s.makeBrowser("_airplay._tcp"), s.makeBrowser("_raop._tcp")))
    def stop(s):
        def f():
            for b in s.browsers.values(): b.cancel()
            s.browsers.clear()
        s.queue.async_(f)
    def makeBrowser(s,t):
        b=NWBrowser()
        if FIX and t in s.browsers: s.browsers[t].cancel()   # the fix
        s.browsers[t]=b; b.start()
class NativeDiscovery:
    def __init__(s): s.queue=Q(); s.started=False; s.browser=NFBrowser()
    def start(s):
        def f():
            if s.started: return
            s.started=True
        s.queue.async_(f); s.browser.start()
    def stop(s):
        s.browser.stop()
        def f(): s.started=False
        s.queue.async_(f)
class Backend:  # only the parts on the discovery path
    def __init__(s): s.sq=Q(); s.started=False; s.discovery=NativeDiscovery(); s.pending=[]
    def start(s):
        def f():
            if s.started: return
            s.started=True
            s.pending.append(lambda: s.discovery.start())  # Task: await engine.start(); discovery.start()
        s.sq.async_(f)
    def stop(s):
        s.discovery.stop()
        def f(): s.started=False
        s.sq.async_(f)
def drain(b):
    b.sq.drain(); b.discovery.queue.drain(); b.discovery.browser.queue.drain()
b=Backend()
b.start(); drain(b)          # Task1 now awaiting engine.start()
b.stop(); drain(b)
b.start(); drain(b)          # Task2 awaiting engine.start()
for t in b.pending: t()      # both engine.start() calls resolve -> discovery.start() twice
drain(b)
b.stop(); drain(b)           # final stop: every browser should be cancelled
leaked=[x for x in NWBrowser.live if not x.cancelled]
print(f"browsers created={len(NWBrowser.live)} still running after stop={len(leaked)}")
assert not leaked, "FAIL: NWBrowsers leaked past stop()"
print("PASS")
