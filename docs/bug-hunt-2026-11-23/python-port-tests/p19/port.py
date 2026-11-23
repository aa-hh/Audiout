# Port of NativeBackend+Bluetooth.swift probe start (~2034), apply (~2141-2209),
# Keep (endBTWizardLatencyPreview ~3061), demo (~2871) and BTSyncedSink
# setOffsetMs/setTrimMs: delay shift = -latency + trim.
import sys
FIX = "--fix" in sys.argv
def snap(x): return round(x)
class Backend:
    def __init__(s, latency, trim):
        s.lat = {} if latency is None else {"t": latency}
        s.trims = {"t": trim}
        s.sink_off = {"t": latency or 0}; s.sink_trim = {"t": trim}
        s.pre = {}
    def shift(s): return -s.sink_off["t"] + s.sink_trim["t"]
    def start_probe(s):
        s.run_trim0 = s.trims.get("t", 0); s.sink_trim["t"] = 0  # suspend
    def apply(s, offset):
        applied = s.lat.get("t", 0)
        kept = max(-1000, min(1000, snap(applied + offset)))  # replace decision
        s.pre["t"] = (applied - s.run_trim0) if FIX else applied
        v = max(0, round(kept)); s.lat["t"] = v; s.trims["t"] = 0
        s.sink_off["t"] = v; s.sink_trim["t"] = 0
    def demo(s):
        prev = s.pre.get("t"); cur = s.lat.get("t", 0); legs = []
        if prev is not None:
            s.sink_off["t"] = int(round(prev)); legs.append(s.shift())
            s.sink_off["t"] = int(round(cur)); legs.append(s.shift())
        return legs
b = Backend(None, -150)
before_actual = b.shift()
b.start_probe(); b.apply(150.0)
legs = b.demo()
print("shift before measurement:", before_actual, "demo legs (before, after):", legs)
assert legs[0] == before_actual, f"demo 'before' leg {legs[0]} != what played before {before_actual}"
print("PASS")
