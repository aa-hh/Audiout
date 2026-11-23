# Faithful port of SyncedLocalSink.renderInterleaved + FractionalResampler + PhaseController
# (mono, 48 kHz, 512-frame cycles, released session). FIX=1 applies the proposed fix.
import os, sys
from collections import deque
FIX = os.environ.get("FIX") == "1"
SR = 48000.0; N = 512; NS_PER_FRAME = 1e9 / SR

class PhaseController:
    def __init__(s, kp=150, ki=2.0, maxp=200, slew=25):
        s.kp, s.ki, s.maxp, s.slew = kp, ki, maxp, slew
        s.imax = maxp / ki; s.integ = 0.0; s.ppm = 0.0
    @property
    def ratio(s): return 1.0 + s.ppm * 1e-6
    def update(s, err_ns, nspf):
        e = err_ns / nspf
        s.integ = min(s.imax, max(-s.imax, s.integ + e))
        p = s.kp * e + s.ki * s.integ
        p = min(s.maxp, max(-s.maxp, p))
        p = min(s.ppm + s.slew, max(s.ppm - s.slew, p))
        s.ppm = p

class Resampler:
    def __init__(s): s.t = [0.0]*4; s.frac = 0.0; s.primed = False; s.consumed = 0
    @property
    def content(s): return s.consumed - 3.0 + s.frac if s.primed else 0.0
    def render(s, out, off, n, ratio, pull):
        r = min(2.0, max(0.5, ratio)); produced = 0
        for o in range(n):
            if not s.primed:
                s.t[0] = 0.0
                for i in (1, 2, 3):
                    v = pull()
                    if v is None: return produced
                    s.t[i] = v; s.consumed += 1
                s.primed = True; s.frac = 0.0
            while s.frac >= 1.0:
                v = pull()
                if v is None: return produced
                s.t = s.t[1:] + [v]; s.consumed += 1; s.frac -= 1.0
            f = s.frac; x0, x1, x2, x3 = s.t
            a = -0.5*x0 + 1.5*x1 - 1.5*x2 + 0.5*x3
            b = x0 - 2.5*x1 + 2.0*x2 - 0.5*x3
            c = -0.5*x0 + 0.5*x2
            out[off+o] = ((a*f + b)*f + c)*f + x1
            produced += 1; s.frac += r
        return produced

class Sink:
    def __init__(s, target):
        s.ring = deque(float(i+1) for i in range(48000*120))  # 2 min of ramp content (value = index+1, never 0)
        s.anchored = True; s.released = True; s.target = target; s.gain = 1.0
        s.lock_busy = False
        s.res = Resampler(); s.pc = PhaseController(); s.last_err = 0
        s.r_target = target if FIX else None; s.r_gain = 1.0   # fix: render-thread-owned cache
    def pull(s): return s.ring.popleft() if s.ring else None
    def render(s, out, cycle_start):
        silent = N; drain = False; target = 0; g = 1.0
        if not s.lock_busy:                       # stateLock.try() succeeded
            g = s.gain
            if s.anchored:
                target = s.target
                if s.released: silent = 0; drain = True
            if FIX: s.r_gain = g; s.r_target = target if drain else None
        elif FIX and s.r_target is not None:      # fix: keep draining with cached snapshot
            target = s.r_target; g = s.r_gain; silent = 0; drain = True
        else:
            for i in range(N): out[i] = 0.0
            return False
        if not drain: return False
        start = cycle_start + round(silent * NS_PER_FRAME)
        err = float(start - target) - s.res.content * NS_PER_FRAME
        s.pc.update(err, NS_PER_FRAME)
        p = s.res.render(out, silent, N - silent, s.pc.ratio, s.pull)
        if g != 1.0:
            for i in range(p): out[silent+i] *= g
        for i in range(silent+p, N): out[i] = 0.0
        s.err = err
        return p > 0
