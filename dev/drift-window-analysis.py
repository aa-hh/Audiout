#!/usr/bin/env python3
"""Replay dumped passive-drift windows through several delay estimators.

Input: ~/Library/Logs/Audiout/drift-windows/<stamp>-{ref,cap}.f32 + -meta.json,
written by the Mac app when `audiout.driftDumpWindows` is set (see
PassiveDriftSampler.dumpWindowIfEnabled). Reference = the outgoing mix (mono
Float32 at referenceRate), capture = the built-in mic (mono Float32 at
captureRate); capture[0] and reference[0] are the same instant, so a speaker
at delay d puts the reference into the capture d later.

For each window and each expected delay it reports, per estimator, the best
lag inside ±SEARCH ms of the expectation and its score:
  plain   the app's matched filter, whole-tape robust background (ProbeKit)
  phat.5  partially whitened by the reference's own spectrum, exponent 0.5
  phat1   fully whitened (phase transform)
  local   plain filter scored against a ±300 ms local background
  p2p     peak over the second-best peak inside the search window
  hi.ph1  1–8 kHz only, fully whitened (the treble carries the timing)
  bands   4 sub-band whitened peaks: spread in ms (agreement)
plus capture level stats (clipping is the first thing to rule out).

Usage: python3 dev/drift-window-analysis.py [dir] [--search 120] [--band 300 8000]
Needs numpy + scipy (python3 -m venv v && v/bin/pip install numpy scipy).
"""
import glob, json, math, os, sys
import numpy as np
from scipy import signal

SEARCH_MS = 120.0
BAND = (300.0, 8000.0)
EXCLUSION_S, SHADOW_S = 0.005, 0.100          # ProbeKit's peak exclusion / reverb shadow
MEDIAN_HALF_NORMAL = 0.6744897501960817


def load(stem):
    ref = np.fromfile(stem + "-ref.f32", dtype="<f4").astype(np.float64)
    cap = np.fromfile(stem + "-cap.f32", dtype="<f4").astype(np.float64)
    meta = json.load(open(stem + "-meta.json"))
    return ref, cap, meta


def bandlimit(x, rate, lo, hi):
    hi = min(hi, rate / 2 * 0.99)
    sos = signal.butter(4, [lo, hi], btype="band", fs=rate, output="sos")
    return signal.sosfiltfilt(sos, x)


def xcorr_fft(ref, cap, beta=0.0, eps=1e-9):
    """corr[k] = sum_n ref[n] cap[n+k], k >= 0, via FFT; beta whitens by |REF|^beta."""
    n = len(ref) + len(cap)
    nfft = 1 << (n - 1).bit_length()
    R = np.fft.rfft(ref, nfft)
    C = np.fft.rfft(cap, nfft)
    cross = np.conj(R) * C
    if beta > 0:
        cross = cross / (np.abs(R) ** beta + eps)
    return np.fft.irfft(cross, nfft)[: len(cap)]


def probekit_score(corr, peak_idx, rate):
    """Peak over the expected largest background lag, ProbeKit style."""
    excl = max(1, int(EXCLUSION_S * rate))
    shadow = max(excl, int(SHADOW_S * rate))
    idx = np.arange(len(corr))
    bg = np.abs(corr[(idx < peak_idx - excl) | (idx > peak_idx + shadow)])
    if len(bg) < 2:
        return float("nan")
    sigma = np.median(bg) / MEDIAN_HALF_NORMAL
    sidelobe = math.sqrt(2 * math.log(len(bg))) * sigma
    return corr[peak_idx] / sidelobe if sidelobe > 0 else float("inf")


def local_score(corr, peak_idx, rate, half_s=0.3):
    lo, hi = max(0, peak_idx - int(half_s * rate)), min(len(corr), peak_idx + int(half_s * rate))
    excl = max(1, int(EXCLUSION_S * rate))
    idx = np.arange(lo, hi)
    bg = np.abs(corr[lo:hi][(idx < peak_idx - excl) | (idx > peak_idx + excl)])
    if len(bg) < 2:
        return float("nan")
    sigma = np.median(bg) / MEDIAN_HALF_NORMAL
    return corr[peak_idx] / (math.sqrt(2 * math.log(len(bg))) * sigma)


def best_in_window(corr, expected_ms, rate):
    lo = max(0, int((expected_ms - SEARCH_MS) / 1000 * rate))
    hi = min(len(corr), int((expected_ms + SEARCH_MS) / 1000 * rate))
    seg = corr[lo:hi]
    i = int(np.argmax(seg))
    peak = lo + i
    # second-best peak outside ±3 ms of the best
    mask = np.abs(np.arange(lo, hi) - peak) > int(0.003 * rate)
    second = np.max(seg[mask]) if mask.any() else float("nan")
    p2p = corr[peak] / second if second > 0 else float("inf")
    return peak, p2p


def analyse(stem):
    ref, cap, meta = load(stem)
    rr, cr = float(meta["referenceRate"]), float(meta["captureRate"])
    if rr != cr:
        ref = signal.resample_poly(ref, int(cr), int(rr))
    clip = np.mean(np.abs(cap) > 0.99)
    print(f"\n== {os.path.basename(stem)}  ref {len(ref)/cr:.2f}s  cap {len(cap)/cr:.2f}s  "
          f"cap peak {20*math.log10(max(np.max(np.abs(cap)),1e-9)):.1f} dBFS  rms {20*math.log10(max(np.sqrt(np.mean(cap**2)),1e-9)):.1f} dBFS  "
          f"clipped {clip*100:.2f}%  ref rms {20*math.log10(max(np.sqrt(np.mean(ref**2)),1e-9)):.1f} dBFS")
    refb, capb = bandlimit(ref, cr, *BAND), bandlimit(cap, cr, *BAND)
    corrs = {"plain": xcorr_fft(refb, capb), "phat.5": xcorr_fft(refb, capb, 0.5), "phat1": xcorr_fft(refb, capb, 1.0),
             # 1–8 kHz whitened: the first live window (2026-09-13 21:07) had its
             # only clear peak here (local 4.0) while 300 Hz–8 kHz showed none.
             "hi.ph1": xcorr_fft(bandlimit(ref, cr, 1000.0, BAND[1]), bandlimit(cap, cr, 1000.0, BAND[1]), 1.0)}
    edges = np.geomspace(BAND[0], BAND[1], 5)
    band_corrs = [xcorr_fft(bandlimit(ref, cr, a, b), bandlimit(cap, cr, a, b), 0.5) for a, b in zip(edges[:-1], edges[1:])]
    print(f"{'expected':>9} {'est':>7} {'lag ms':>8} {'err ms':>7} {'score':>6} {'local':>6} {'p2p':>5}")
    for b in meta["baselines"]:
        exp = float(b["expectedDelayMs"])
        for name, corr in corrs.items():
            peak, p2p = best_in_window(corr, exp, cr)
            lag = peak / cr * 1000
            print(f"{exp:9.1f} {name:>7} {lag:8.1f} {lag-exp:+7.1f} {probekit_score(corr, peak, cr):6.2f} "
                  f"{local_score(corr, peak, cr):6.2f} {p2p:5.2f}")
        lags = [best_in_window(c, exp, cr)[0] / cr * 1000 for c in band_corrs]
        print(f"{exp:9.1f} {'bands':>7} {np.median(lags):8.1f}   spread {max(lags)-min(lags):6.1f} ms  "
              f"[{', '.join(f'{l:.1f}' for l in lags)}]  uid {b['uid']}")


if __name__ == "__main__":
    args = sys.argv[1:]
    d = os.path.expanduser("~/Library/Logs/Audiout/drift-windows")
    if args and not args[0].startswith("--"):
        d = args.pop(0)
    if "--search" in args:
        SEARCH_MS = float(args[args.index("--search") + 1])
    if "--band" in args:
        i = args.index("--band"); BAND = (float(args[i + 1]), float(args[i + 2]))
    stems = sorted(p[:-len("-meta.json")] for p in glob.glob(os.path.join(d, "*-meta.json")))
    if not stems:
        sys.exit(f"no windows in {d}")
    for s in stems:
        analyse(s)
