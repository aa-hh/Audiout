# Port of BTSyncedSink.setOffsetMs / setTrimMs / BTDeviceSink.applyTrimDelta (released path)
# and SyncTiming.totalDelayNanos (BT-only composition). Ring delay R is the read position's
# distance behind write; forward room = R + device buffering (used frames).
import sys
FIX = "--fix" in sys.argv
SR = 48000.0; MARGIN_MS = 100.0; DEV_BUF_MS = 20.0

def formula(ref, off, trim):  # SyncTiming.totalDelayNanos, in ms
    return max(0.0, ref - off + trim)

class Sink:
    def __init__(self, delay_ms): self.ring_ms = delay_ms  # anchored + released at formula delay
    def applyTrimDelta(self, delta_ms):
        req = int(round(delta_ms / 1000 * SR)); margin = int(round(MARGIN_MS / 1000 * SR))
        used = int(round((self.ring_ms + DEV_BUF_MS) / 1000 * SR))
        frames = -min(-req, max(0, used - margin)) if req < 0 else req
        self.ring_ms += frames / SR * 1000

class Manager:
    def __init__(self, ref, off, trim=0.0):
        self.ref, self.off, self.trim = ref, off, trim
        self.sink = Sink(formula(ref, off, trim))
    def setOffsetMs(self, ms):
        if ms == self.off: return
        before = formula(self.ref, self.off, self.trim)
        prev = self.off; self.off = ms
        if FIX: self.sink.applyTrimDelta(formula(self.ref, self.off, self.trim) - before)
        else:   self.sink.applyTrimDelta(-(ms - prev))

fails = 0
def check(name, m):
    global fails
    f = formula(m.ref, m.off, m.trim); ok = abs(m.sink.ring_ms - f) < 0.05
    fails += not ok
    print(f"{'PASS' if ok else 'FAIL'} {name}: ring={m.sink.ring_ms:.1f}ms formula={f:.1f}ms")

# Reachable: per-app-only BT speaker (not in btSelectedUIDs, so the BT-only reference stays
# at the 500 ms default) with a stored latency of 700 ms; the drawer's Reset
# (resetBTAlignment -> setOffsetMs(0)) does not move the floor, so no rebuild.
m = Manager(ref=500, off=700); m.setOffsetMs(0); check("per-app reset 700->0, ref 500", m)
# The claim's own sequence.
m = Manager(ref=500, off=600); m.setOffsetMs(700); m.setOffsetMs(500); check("claim 600->700->500, ref 500", m)
sys.exit(1 if fails else 0)
