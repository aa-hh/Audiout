# Turns red when one contended stateLock.try() on a released session zero-fills
# a cycle and leaves a content slip the 200 ppm loop needs tens of seconds to undo.
import sys; sys.path.insert(0, "/tmp/hunt/p47")
from port import Sink, N, NS_PER_FRAME
T0 = 1_000_000_000
sink = Sink(T0); out = [0.0]*N
cyc_ns = N * NS_PER_FRAME
fails = []
for k in range(400):  # warm up (~4 s): loop converges
    sink.render(out, T0 + round(k*cyc_ns))
k = 400
sink.lock_busy = True   # setGain / hasStartedRendering holds stateLock during this cycle
sink.render(out, T0 + round(k*cyc_ns)); sink.lock_busy = False
zeros = sum(1 for v in out if v == 0.0)
if zeros: fails.append(f"dropout: {zeros}/{N} zero samples in released cycle")
k += 1
sink.render(out, T0 + round(k*cyc_ns))
slip = sink.err / NS_PER_FRAME
# how long until |phase error| < 1 frame
t = None
for j in range(1, 100*94):
    sink.render(out, T0 + round((k+j)*cyc_ns))
    if abs(sink.err) < NS_PER_FRAME: t = j*cyc_ns/1e9; break
print(f"slip after contended cycle: {slip:.1f} frames; recovery to <1 frame: {t if t is None else round(t,1)} s")
if slip > 1: fails.append(f"content slip {slip:.1f} frames")
if fails: print("FAIL:", "; ".join(fails)); sys.exit(1)
print("PASS")
