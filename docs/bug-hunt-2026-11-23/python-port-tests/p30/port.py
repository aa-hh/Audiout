# Faithful port of PerAppCaptureCoordinator.stop(bundleID:) / stopAll() (lines ~346-372).
import threading, sys
FIX = "--fix" in sys.argv

class Slot:
    def __init__(s): s.state = "idle"; s.tap = None

class FakeTap:
    def __init__(s):
        s.calls = 0; s.inside = 0; s.max_inside = 0; s.lock = threading.Lock()
        s.entered = threading.Event(); s.release = threading.Event()
    def teardown(s):  # blocks like Core Audio teardown can
        with s.lock:
            s.calls += 1; s.inside += 1; s.max_inside = max(s.max_inside, s.inside)
        s.entered.set(); s.release.wait(2)
        with s.lock: s.inside -= 1

class Coord:
    def __init__(s): s.q = threading.Lock(); s.slots = {}
    def transition(s, slot, bid, st):
        if st != slot.state: slot.state = st
    def stop(s, bid):
        with s.q:  # queue.sync
            slot = s.slots.get(bid)
            if slot is None: return_t = None; owned = False
            elif slot.state == "idle": return_t = None; owned = False
            elif FIX and slot.state == "stopping": return_t = None; owned = False
            else:
                return_t = slot.tap; owned = True
                s.transition(slot, bid, "stopping")
        if FIX and not owned: return
        if return_t: return_t.teardown()
        with s.q:
            slot = s.slots.get(bid)
            if slot is None: return
            slot.tap = None; s.transition(slot, bid, "idle"); del s.slots[bid]
    def stopAll(s):
        with s.q: ids = list(s.slots)
        for i in ids: s.stop(i)

c = Coord(); tap = FakeTap(); sl = Slot(); sl.state = "capturing"; sl.tap = tap; c.slots["x"] = sl
a = threading.Thread(target=c.stopAll); a.start()        # e.g. NativeBackend.stop()
tap.entered.wait(2)                                       # A is inside teardown, off the queue
b = threading.Thread(target=c.stop, args=("x",)); b.start()  # e.g. captureControlQueue / handleAppTerminated
b.join(0.5); tap.release.set(); a.join(3); b.join(3)
print(f"teardown calls={tap.calls} max concurrent={tap.max_inside} slots={list(c.slots)}")
ok = tap.calls == 1 and tap.max_inside == 1
print("PASS" if ok else "FAIL: same tap torn down by two concurrent stop() calls")
sys.exit(0 if ok else 1)
