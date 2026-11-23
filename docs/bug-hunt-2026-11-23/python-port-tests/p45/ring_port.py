# Faithful port of InterleavedFloatRing + SyncedLocalSink.applyUserOffsetDelta (released path).
import sys
FIX = '--fix' in sys.argv

class Ring:
    def __init__(self, min_cap):
        cap = 1
        while cap < max(2, min_cap): cap <<= 1
        self.capacity = cap; self.mask = cap - 1
        self.storage = [0.0] * cap
        self.head = 0; self.tail = 0
        self.req = 0; self.app = 0
        self.consumed = 0  # FIX: samples of THIS session behind tail
    def write(self, src):
        h, t = self.head, self.tail
        used = (h - t) & self.mask
        if len(src) > self.capacity - 1 - used: return False
        for i, v in enumerate(src): self.storage[(h + i) & self.mask] = v
        self.head = (h + len(src)) & self.mask
        return True
    def seek_room(self):
        used = (self.head - self.tail) & self.mask
        back = self.capacity - 1 - used
        if FIX: back = min(back, self.consumed)
        return used, back
    def request_shift(self, s):
        if s: self.req += s
    def apply_pending_shift(self):
        delta = self.req - self.app
        if delta == 0: return
        self.app = self.req
        t = self.tail
        used = (self.head - t) & self.mask
        back = self.capacity - 1 - used
        if FIX: back = min(back, self.consumed)
        applied = -min(-delta, back) if delta < 0 else min(delta, used)
        if applied == 0: return
        if FIX: self.consumed += applied
        self.tail = (t + applied) & self.mask
    def read(self, n):
        self.apply_pending_shift()
        t, h = self.tail, self.head
        avail = (h - t) & self.mask
        c = min(avail, n)
        out = [self.storage[(t + i) & self.mask] for i in range(c)]
        self.tail = (t + c) & self.mask
        if FIX: self.consumed += c
        return out
    def reset(self):
        self.tail = self.head; self.app = self.req
        if FIX: self.consumed = 0

SR, CH = 1000.0, 1
ring = Ring(int(round(10 * SR)) * CH)   # maxBufferedSeconds = 10

def apply_user_offset_delta(ms):  # released path
    d = int(round(ms / 1000 * SR)) * CH
    if d == 0: return 'noop'
    shift = -d
    fwd, back = ring.seek_room()
    if not ((-shift <= back) if shift < 0 else (shift <= fwd)):
        return 'reanchor'
    ring.request_shift(shift); return 'shift'

# Session 1: previous song (value 1.0) plays out, then a rebuild resets the ring.
ring.write([1.0] * 3000); ring.read(3000)
ring.reset()
# Session 2 (value 2.0): 2 s pre-roll buffered, gate releases, 100 ms plays.
ring.write([2.0] * 2000)
ring.read(100)
res = apply_user_offset_delta(+300)     # +300 ms, 100 ms after release
out = ring.read(300)
stale = sum(1 for v in out if v != 2.0)
print(f"fix={FIX} action={res} stale_samples_replayed={stale}")
assert stale == 0, "replayed previous-session audio from behind the session anchor"
print("PASS")
