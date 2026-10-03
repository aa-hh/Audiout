#!/usr/bin/env python3
"""Measure the gap between the two arrivals of each click at the Mac's mic.

Usage:  python3 click-pair-spacing.py recording.wav [--period 3.0]

The recording is the Mac's built-in mic while click-track-3s.wav loops through
Audiout to the Mac's own speakers AND one Bluetooth speaker. Every 3 s there
are two arrivals: the Mac speaker (near, loud) and the Bluetooth speaker. For
each period the script prints the time of the loudest peak and the offset of
the second-loudest peak relative to it, in ms. In sync => one merged peak
(offset ~0 or missing). Over an hour, a steady change in the offset is the
Bluetooth-vs-host rate drift; a sudden change is a latency step.

Convert a QuickTime .m4a first:  afconvert -f WAVE -d LEI16 rec.m4a rec.wav
Needs numpy (python3 -c "import numpy" to check).
"""
import sys, wave, argparse
try:
    import numpy as np
except ImportError:
    sys.exit("numpy is required: python3 -m pip install numpy")

ap = argparse.ArgumentParser()
ap.add_argument("wav"); ap.add_argument("--period", type=float, default=3.0)
ap.add_argument("--min-sep-ms", type=float, default=15.0, help="two peaks closer than this are one arrival")
a = ap.parse_args()

w = wave.open(a.wav, "rb"); sr = w.getframerate(); ch = w.getnchannels(); sw = w.getsampwidth()
raw = w.readframes(w.getnframes()); w.close()
dt = {1: np.int8, 2: np.int16, 4: np.int32}[sw]
x = np.frombuffer(raw, dtype=dt).astype(np.float64)
if ch > 1: x = x.reshape(-1, ch).mean(axis=1)
x /= (np.abs(x).max() or 1.0)

# Envelope: remove rumble with a 20 ms moving average, rectify, 1 ms box smoothing.
k20 = int(sr*0.02); x = x - np.convolve(x, np.ones(k20)/k20, mode="same")
k1 = int(sr*0.001); env = np.convolve(np.abs(x), np.ones(k1)/k1, mode="same")
floor = np.median(env) * 8 + 1e-9

# Lock the period grid to the strongest peak in the first period.
P = int(a.period * sr); minsep = int(a.min_sep_ms/1000*sr)
first = int(np.argmax(env[:P])); start = max(0, first - P//4)
print(f"# sr={sr} period={a.period}s frames={len(env)//P}")
print("# t_loudest_s  offset_second_ms  (loud/second ratio)")
rows = []
for k in range((len(env) - start)//P):
    seg = env[start + k*P : start + (k+1)*P]
    if seg.max() < floor: continue
    i1 = int(np.argmax(seg)); v1 = seg[i1]
    mask = np.ones_like(seg, dtype=bool); mask[max(0,i1-minsep):i1+minsep] = False
    seg2 = np.where(mask, seg, 0.0)
    i2 = int(np.argmax(seg2)); v2 = seg2[i2]
    t1 = (start + k*P + i1)/sr
    if v2 < floor or v2 < 0.05*v1:
        print(f"{t1:10.3f}  {'merged':>10}"); rows.append((t1, 0.0)); continue
    off = (i2 - i1)/sr*1000
    print(f"{t1:10.3f}  {off:+10.2f}   ({v1/v2:.1f})"); rows.append((t1, off))
if len(rows) >= 4:
    t = np.array([r[0] for r in rows]); o = np.array([r[1] for r in rows])
    slope = np.polyfit(t, o, 1)[0]
    print(f"# linear fit: {slope*60:+.3f} ms/min = {slope*1000:+.1f} ppm over {t[-1]-t[0]:.0f} s "
          f"(first {o[:5].mean():+.1f} ms, last {o[-5:].mean():+.1f} ms)")
