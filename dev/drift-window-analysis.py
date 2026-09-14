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

It also reads the fixtures committed in audiout-shared
(`Tests/ProbeKitTests/Fixtures`: Int16 at one rate, made by that repo's
`tools/make-drift-fixtures.py`), so both sides consume the identical samples,
and checks its own replica of the correlator against the Swift one. Run the
`PassiveDriftFixtureTests` suite in the shared repo with that repo's own test
command (not this repo's), keep its output, and pass it here:

  python3 dev/drift-window-analysis.py --fixtures <shared>/Tests/ProbeKitTests/Fixtures \
      --swift /tmp/swift-fixture-run.txt

The `sw` columns are a line-by-line replica of what PassiveDriftCorrelator
reports for one window: the same causal 300 Hz-8 kHz biquads, the same FFT
correlation whitened by the reference's own magnitude spectrum at exponent
0.7, the same background taken over the search range with a 250 ms reverb
shadow, the same parabolic peak, and the same two extra numbers the correlator
gates on: its local score, and its margin over the nearest rival lag, which
this file has always called p2p. The research rows in the per-window report
are left as they were, zero-phase filtering and whole-tape background
included, because they answer research questions rather than parity ones.

Usage: python3 dev/drift-window-analysis.py [dir] [--search 120] [--band 300 8000]
       python3 dev/drift-window-analysis.py --fixtures <dir> [--swift <log>]
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


def probekit_score(corr, peak_idx, rate, shadow_s=SHADOW_S, limit=None):
    """Peak over the expected largest background lag, ProbeKit style.

    `limit` bounds the background to the lags the correlator itself searches
    (its `searchCount`); the default whole-tape background is what the research
    rows above have always used.
    """
    excl = max(1, int(EXCLUSION_S * rate))
    shadow = max(excl, int(shadow_s * rate))
    corr = corr[:limit] if limit is not None else corr
    idx = np.arange(len(corr))
    bg = np.abs(corr[(idx < peak_idx - excl) | (idx > peak_idx + shadow)])
    if len(bg) < 2:
        return float("nan")
    sigma = np.median(bg) / MEDIAN_HALF_NORMAL
    sidelobe = math.sqrt(2 * math.log(len(bg))) * sigma
    return corr[peak_idx] / sidelobe if sidelobe > 0 else float("inf")


def local_score(corr, peak_idx, rate, half_s=0.3, limit=None):
    """Peak over the background within ±`half_s` of it. `limit` bounds that
    neighbourhood to the lags the correlator itself searches, as the Swift side
    does; the research rows pass nothing and keep the whole tape."""
    corr = corr[:limit] if limit is not None else corr
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


SWIFT_BAND = (300.0, 8000.0)          # PassiveDriftCorrelator.timingBandLow/HighHz
SWIFT_SHADOW_S = 0.25                 # SyncProbeCorrelator.reverbShadowSeconds
SWIFT_WHITENING = 0.7                 # PassiveDriftCorrelator.whiteningExponent
RIVAL_SEPARATION_S = 0.003            # SyncProbeCorrelator.peakMarginSeparationSeconds


def swift_band_limit(x, rate, lo=SWIFT_BAND[0], hi=SWIFT_BAND[1]):
    """PassiveDriftCorrelator.bandLimited: two causal biquads, Q = 1/sqrt(2).

    Not sosfiltfilt: that runs the filter twice and backwards, which is a
    different signal. Parity needs the filter the app actually applies.
    """
    y = np.asarray(x, dtype=np.float64)
    for hz, high_pass in ((lo, True), (hi, False)):
        if not 0 < hz < rate / 2:
            continue
        w0 = 2 * math.pi * hz / rate
        cos_w, alpha = math.cos(w0), math.sin(w0) / math.sqrt(2)
        a0 = 1 + alpha
        b = ([(1 + cos_w) / 2, -(1 + cos_w), (1 + cos_w) / 2] if high_pass
             else [(1 - cos_w) / 2, 1 - cos_w, (1 - cos_w) / 2])
        y = signal.lfilter(np.array(b) / a0,
                           [1.0, -2 * cos_w / a0, (1 - alpha) / a0], y)
    return y


def swift_candidate(ref, cap, rate, expected_ms, search_ms=None):
    """One window as PassiveDriftCorrelator reports it: best lag, whole-tape
    score, local score, and margin over the nearest rival lag."""
    nan4 = (float("nan"),) * 4
    search_ms = SEARCH_MS if search_ms is None else search_ms
    probe, rec = swift_band_limit(ref, rate), swift_band_limit(cap, rate)
    search_count = len(rec) - len(probe) + 1
    if search_count < 2:
        return nan4
    n = 1 << (len(rec) + len(probe) - 1).bit_length()
    # SyncProbeCorrelator.whiteningWeights: each bin divided by the reference's
    # own magnitude raised to the exponent, with a floor at 5% of the
    # reference's mean power so a near-empty bin divides by the floor rather
    # than by nothing. `power` holds half the spectrum, so the mean over the
    # whole one counts every bin but DC and Nyquist twice.
    R, C = np.fft.rfft(probe, n), np.fft.rfft(rec, n)
    power = np.abs(R) ** 2
    eps = (power[0] + power[-1] + 2 * power[1:-1].sum()) / n * 0.05
    corr = np.fft.irfft(np.conj(R) * C / (power + eps) ** (SWIFT_WHITENING / 2), n)

    half = round(search_ms / 1000 * rate)
    centre = round(expected_ms / 1000 * rate)
    lo, hi = max(0, centre - half), min(search_count, centre + half + 1)
    if lo >= hi:
        return nan4
    peak = lo + int(np.argmax(corr[lo:hi]))
    if corr[peak] <= 0:
        return nan4

    offset = float(peak)
    if 0 < peak < search_count - 1:
        cm, c0, cp = corr[peak - 1], corr[peak], corr[peak + 1]
        denom = cm - 2 * c0 + cp
        if denom < 0:
            offset += 0.5 * (cm - cp) / denom
    score = probekit_score(corr, peak, rate, shadow_s=SWIFT_SHADOW_S, limit=search_count)
    local = local_score(corr, peak, rate, limit=search_count)
    # The best lag in the same window that is not this arrival.
    rivals = corr[lo:hi][np.abs(np.arange(lo, hi) - peak) > max(1, int(RIVAL_SEPARATION_S * rate))]
    best_rival = np.max(rivals) if rivals.size else 0.0
    margin = corr[peak] / best_rival if best_rival > 0 else float("inf")
    return offset / rate * 1000, score, local, margin


def load_fixtures(directory):
    """The shared repo's Int16 fixtures, back at the amplitude they were dumped at."""
    manifest = json.load(open(os.path.join(directory, "manifest.json")))
    for fixture in manifest["fixtures"]:
        def samples(kind, scale):
            raw = np.fromfile(os.path.join(directory, f"{fixture['name']}-{kind}.i16"),
                              dtype="<i2")
            return raw.astype(np.float64) / 32767 * scale
        yield (fixture,
               samples("ref", fixture["referenceFullScale"]),
               samples("cap", fixture["captureFullScale"]))


def read_swift_output(path):
    """The CANDIDATE lines PassiveDriftFixtureTests prints, by fixture name."""
    by_name = {}
    for line in open(path):
        parts = line.split()
        if len(parts) < 3 or parts[0] != "CANDIDATE":
            continue
        fields = dict(p.split("=", 1) for p in parts[2:] if "=" in p)
        by_name.setdefault(parts[1], []).append({k: float(v) for k, v in fields.items()})
    return by_name


def parity(directory, swift_path, tolerance=0.05):
    """Both sides over the identical samples. False if any score is further apart
    than `tolerance`."""
    swift = read_swift_output(swift_path) if swift_path else {}
    print(f"{'fixture':>26} {'label':>6} {'exp':>7} {'py lag':>7} {'sw lag':>7} "
          f"{'py score':>8} {'sw score':>8} {'diff':>7} "
          f"{'py local':>8} {'sw local':>8} {'py p2p':>7} {'sw marg':>7}")
    agreed = True
    for fixture, ref, cap in load_fixtures(directory):
        rate = float(fixture["captureRate"])
        rows = swift.get(fixture["name"], [])
        for i, baseline in enumerate(fixture["baselines"]):
            expected = float(baseline["expectedDelayMs"])
            lag, score, local, p2p = swift_candidate(ref, cap, rate, expected)
            row = rows[i] if i < len(rows) else None
            head = (f"{fixture['name']:>26} {fixture['label']:>6} {expected:7.1f} "
                    f"{lag:7.2f}")
            if row is None:
                print(f"{head} {'-':>7} {score:8.4f} {'-':>8} {'-':>7} "
                      f"{local:8.2f} {'-':>8} {p2p:7.2f} {'-':>7}")
                continue
            diff = abs(score - row["score"]) / row["score"] if row["score"] else float("inf")
            agreed &= diff <= tolerance
            print(f"{head} {row['lag']:7.2f} {score:8.4f} {row['score']:8.4f} "
                  f"{diff*100:6.2f}% {local:8.2f} {row['local']:8.2f} "
                  f"{p2p:7.2f} {row['margin']:7.2f}"
                  f"{'' if diff <= tolerance else '  OVER'}")
    if swift:
        print("scores agree within 5%" if agreed else "SCORES DISAGREE by more than 5%")
    return agreed


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
    if "--fixtures" in args:
        i = args.index("--fixtures")
        swift_path = args[args.index("--swift") + 1] if "--swift" in args else None
        sys.exit(0 if parity(args[i + 1], swift_path) else 1)
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
