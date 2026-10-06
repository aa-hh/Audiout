"""Numerical bench for candidate sync-probe stimuli.

Mirrors audiout-shared Sources/ProbeKit/SyncProbeCorrelator.swift:
plain matched filter, ambient-noise weighting from a probe-free lead-in,
confidence = peak / (sqrt(2 ln N) * median|background| / 0.6745) with the
background taken outside [peak - 5 ms, peak + 250 ms], parabolic peak
interpolation, refuse below 5, weighted first then unweighted fallback.

Run:  .venv/bin/python bench.py            (all candidates, 20 seeds)
      .venv/bin/python bench.py --quick    (5 seeds, smoke test)
      .venv/bin/python bench.py --noise-boost=10   (10 dB more room noise)
      --only=0,P1,P2a     run only these candidate ids (writes to ../shaped/probe/)
      --noise-shape=step12  room noise 12 dB lower above 3 kHz (level below 3 kHz
                          unchanged from the calibrated flat pink noise)
      --trims=file.json   {"id": [ref_dB, tgt_dB]} level trims after RMS matching
      --seeds=N  --codecs=aac,sbc  --tag=name   (fewer seeds / codecs; CSV name suffix)
"""
import json
import os, sys, subprocess, tempfile, csv
import numpy as np
import scipy.io.wavfile as wavfile
from scipy.signal import fftconvolve

FS = 48000
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
os.makedirs(OUT, exist_ok=True)

SEEDS = 5 if "--quick" in sys.argv else 20
SEEDS = next((int(a.split("=")[1]) for a in sys.argv if a.startswith("--seeds=")), SEEDS)
CODECS = next((a.split("=")[1].split(",") for a in sys.argv if a.startswith("--codecs=")), ["none", "aac", "sbc"])
TAG = next((a.split("=")[1] for a in sys.argv if a.startswith("--tag=")), "")
# --noise-boost=N: N dB more room noise than the calibrated level
BOOST_DB = next((float(a.split("=")[1]) for a in sys.argv if a.startswith("--noise-boost=")), 0.0)
ONLY = next((a.split("=", 1)[1].split(",") for a in sys.argv if a.startswith("--only=")), None)
SHAPE = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--noise-shape=")), "flat")
TRIMS = next((json.load(open(a.split("=", 1)[1])) for a in sys.argv if a.startswith("--trims=")), {})
OFFSETS_MS = [-40.0, -7.0, 3.3, 120.0]
TARGET_GAIN_DB = -23.0
LEAD = 0.5          # probe-free lead-in used as the ambient slice
D1 = 0.6            # reference arrival time in the recording
TAIL = 0.4
FADE = 0.08
SWEEP_AMP = 0.175   # AlignmentTickInjector.probeAmplitude


# ---------------------------------------------------------------- synthesis
def t_axis(dur):
    return np.arange(int(round(dur * FS))) / FS


def fades(x, fade=FADE, fade_out=None):
    """Raised-cosine fade in of `fade` s and fade out of `fade_out` s
    (defaults to `fade`)."""
    n = len(x)
    x = x.copy()
    for k, sec in enumerate((fade, fade if fade_out is None else fade_out)):
        f = min(int(sec * FS), n // 2)
        if f > 0:
            r = 0.5 - 0.5 * np.cos(np.pi * np.arange(f) / f)
            if k == 0:
                x[:f] *= r
            else:
                x[n - f:] *= r[::-1]
    return x


def exp_sweep(f0, f1, dur=1.0, fin=FADE, fout=None, partials=(1.0,)):
    """Exponential sweep; partials[h-1] is the amplitude of harmonic h, each an
    exact multiple of the fundamental's phase."""
    t = t_axis(dur)
    lnr = np.log(f1 / f0)
    k = 2 * np.pi * f0 * dur / lnr
    ph = k * (np.exp(t / dur * lnr) - 1)
    x = sum(a * np.sin(h * ph) for h, a in enumerate(partials, start=1))
    return fades(x, fin, fout)


def stepped_sweep(f0, f1, dur, degrees, fin=FADE, fout=None):
    """Exponential sweep whose frequency is held on scale notes (semitone
    offsets from f0, repeating every octave), with 10 ms phase-continuous
    glides between notes."""
    t = t_axis(dur)
    up = f1 > f0
    semis = 12 * np.log2(np.exp(t / dur * np.log(f1 / f0)))  # signed semitones from f0
    s = np.abs(semis)
    octv = np.floor(s / 12)
    within = s - 12 * octv
    deg = np.array(degrees + [12])
    q = deg[np.searchsorted(deg, within + 1e-9, side="right") - 1] + 12 * octv
    q = q if up else -q
    f = f0 * 2 ** (q / 12)
    g = int(0.010 * FS)
    f = np.convolve(np.pad(f, (g // 2, g - g // 2 - 1), mode="edge"), np.ones(g) / g, mode="valid")
    return fades(np.sin(2 * np.pi * np.cumsum(f) / FS), fin, fout)


def band_noise(lo, hi, dur, seed, pink=True, skirt=0.1):
    n = int(round(dur * FS))
    rng = np.random.default_rng(seed)
    X = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / FS)
    mag = np.zeros_like(f)
    inb = (f >= lo) & (f <= hi)
    mag[inb] = 1 / np.sqrt(f[inb]) if pink else 1
    # cosine skirts inside the band edges so the noise has no brick-wall ring
    w_lo, w_hi = lo * (1 + skirt), hi * (1 - skirt)
    a = (f >= lo) & (f < w_lo)
    mag[a] *= 0.5 - 0.5 * np.cos(np.pi * (f[a] - lo) / (w_lo - lo))
    b = (f > w_hi) & (f <= hi)
    mag[b] *= 0.5 - 0.5 * np.cos(np.pi * (hi - f[b]) / (hi - w_hi))
    return np.fft.irfft(X * mag, n)


def whoosh(lo, hi, dur, seed, segments=1):
    x = band_noise(lo, hi, dur, seed)
    n = len(x)
    env = np.zeros(n)
    seg = n // segments
    for s in range(segments):
        env[s * seg:(s + 1) * seg] = np.hanning(seg)
    return x * env


def plucks(fundamentals, onsets, dur, tau=0.05, attack=0.002, harm=(1.0, 0.5, 0.25)):
    """Decaying sines with 3 harmonics; 2 ms linear attack, exp decay tau
    (50 ms: -26 dB at 150 ms)."""
    t = t_axis(dur)
    x = np.zeros_like(t)
    for f0, t0 in zip(fundamentals, onsets):
        tt = t - t0
        on = tt >= 0
        env = np.where(tt < attack, tt / attack, np.exp(-(tt - attack) / tau)) * on
        for h, a in enumerate(harm, start=1):
            x += a * env * np.sin(2 * np.pi * f0 * h * tt)
    return x


def schroeder(lo, hi, spacing=50.0, dur=1.0):
    t = t_axis(dur)
    ks = np.arange(int(np.ceil(lo / spacing)), int(np.floor(hi / spacing)) + 1)
    K = len(ks)
    x = np.zeros_like(t)
    for i, k in enumerate(ks, start=1):
        x += np.cos(2 * np.pi * k * spacing * t - np.pi * i * (i - 1) / K)
    return fades(x), K


def golay(n):
    a, b = np.array([1.0]), np.array([1.0])
    while len(a) < n:
        a, b = np.concatenate([a, b]), np.concatenate([a, -b])
    return a, b


def golay_lane(seq, chip_rate, fc, lo, hi):
    """BPSK of a Golay sequence onto a carrier: Hann chip pulse 2 chips wide,
    then FFT band-limited to [lo, hi], then the standard 80 ms fades."""
    dur = len(seq) / chip_rate
    n = int(round(dur * FS)) + int(FS * 2 / chip_rate)
    base = np.zeros(n)
    idx = np.round(np.arange(len(seq)) * FS / chip_rate).astype(int)
    base[idx] = seq
    pulse = np.hanning(int(2 * FS / chip_rate))
    base = fftconvolve(base, pulse)[:n]
    x = base * np.cos(2 * np.pi * fc * np.arange(n) / FS)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1 / FS)
    X[(f < lo) | (f > hi)] = 0
    return fades(np.fft.irfft(X, n))


# Baseline RMS: every lane is scaled to the RMS of today's sweep at 0.175 FS,
# so candidates are compared at equal average level, not equal peak.
REF_RMS = np.sqrt(np.mean((SWEEP_AMP * exp_sweep(2000, 500)) ** 2))


def norm(x):
    return x * REF_RMS / np.sqrt(np.mean(x ** 2))


def under_bed(f0, f1, lo, hi, bed_db, seed):
    s = exp_sweep(f0, f1)
    s = s / np.sqrt(np.mean(s ** 2))
    bed = band_noise(lo, hi, 1.0, seed)
    bed = fades(bed / np.sqrt(np.mean(bed ** 2)) * 10 ** (bed_db / 20))
    lane = s + bed
    k = REF_RMS / np.sqrt(np.mean(lane ** 2))
    return lane * k, s * k   # (what plays, what the matched filter knows)


def candidates():
    C = []

    def add(name, ref, tgt, tref=None, ttgt=None, note=""):
        r, t = norm(ref), norm(tgt)
        if tref is not None:  # already scaled together with their lane
            r, t = ref, tgt
        C.append(dict(name=name, ref=r, tgt=t,
                      tref=r if tref is None else tref,
                      ttgt=t if ttgt is None else ttgt, note=note))

    add("0 baseline sweeps 2000>500 / 3200>10000", exp_sweep(2000, 500), exp_sweep(3200, 10000))
    add("0x check: down/up sweeps sharing 500-10000", exp_sweep(10000, 500), exp_sweep(500, 10000))
    add("1a up sweep capped 3200>6000", exp_sweep(2000, 500), exp_sweep(3200, 6000))
    add("1b up sweep capped 3200>4500", exp_sweep(2000, 500), exp_sweep(3200, 4500))
    add("2a whoosh 1.0 s (400-1800 / 2500-7000)", whoosh(400, 1800, 1.0, 11), whoosh(2500, 7000, 1.0, 12))
    add("2b whoosh 2.0 s", whoosh(400, 1800, 2.0, 11), whoosh(2500, 7000, 2.0, 12))
    add("2c whoosh x3 swells, 2.0 s", whoosh(400, 1800, 2.0, 11, 3), whoosh(2500, 7000, 2.0, 12, 3))
    add("2o whoosh 1.0 s OVERLAP both 500-6000", whoosh(500, 6000, 1.0, 11), whoosh(500, 6000, 1.0, 12))
    add("2o' whoosh 2.0 s OVERLAP both 500-6000", whoosh(500, 6000, 2.0, 11), whoosh(500, 6000, 2.0, 12))
    semis = list(range(12))
    penta = [0, 2, 4, 7, 9]
    add("3a semitone-stepped sweeps", stepped_sweep(2000, 500, 1.0, semis), stepped_sweep(3200, 10000, 1.0, semis))
    add("3b pentatonic-stepped sweeps", stepped_sweep(2000, 500, 1.0, penta), stepped_sweep(3200, 10000, 1.0, penta))
    low = [220.0, 277.18, 329.63, 554.37, 440.0, 329.63]       # A major pentatonic, 150-600 Hz
    high = [4 * f for f in [329.63, 440.0, 554.37, 329.63, 277.18, 220.0]]  # answer, 2 octaves up
    on = [0.25 * i for i in range(6)]
    add("4a plucked phrase 1.5 s (low 220-554 Hz, answer x4)",
        plucks(low, on, 1.5), plucks(high, [o + 0.125 for o in on], 1.5))
    add("4b chord stab 0.5 s", plucks(low, [0] * 6, 0.5), plucks(high, [0] * 6, 0.5))
    lo_in = [554.37, 659.26, 739.99, 987.77, 880.0, 659.26]          # fundamentals + 2nd harmonic <= 2 kHz
    hi_in = [8 * f for f in [659.26, 739.99, 880.0, 659.26, 554.37, 554.37]]  # 3 octaves up, 4.4-7 kHz, fundamental only
    add("4c plucked phrase kept inside today's disjoint bands",
        plucks(lo_in, on, 1.5, harm=(1.0, 0.4)), plucks(hi_in, [o + 0.125 for o in on], 1.5, harm=(1.0,)))
    ov_a = [659.26, 739.99, 880.0, 1108.73, 987.77, 880.0]
    ov_b = [1318.5, 1108.73, 987.77, 739.99, 1479.98, 659.26]
    add("4o plucked phrases OVERLAP (both 660-1480 Hz fund., to ~4.4 kHz)",
        plucks(ov_a, on, 1.5), plucks(ov_b, [o + 0.125 for o in on], 1.5))
    s_lo, k_lo = schroeder(500, 2000)
    s_hi, k_hi = schroeder(3200, 10000)
    add(f"5 Schroeder multisine 50 Hz grid ({k_lo} / {k_hi} tones)", s_lo, s_hi)
    a1k, _ = golay(1024)
    _, b4k = golay(4096)
    add("6 Golay A1024 @1024 chip/s 1250 Hz / B4096 @4096 chip/s 6600 Hz",
        golay_lane(a1k, 1024, 1250, 500, 2000), golay_lane(b4k, 4096, 6600, 3200, 10000))
    a4k, b4k2 = golay(4096)
    add("6o Golay pair A/B OVERLAP (both 4096 chip/s, 500-6000)",
        golay_lane(a4k, 4096, 3250, 500, 6000), golay_lane(b4k2, 4096, 3250, 500, 6000))
    for tag, bed in (("7a", 6), ("7b", 12)):
        r, tr = under_bed(2000, 500, 500, 2000, bed, 21)
        t, tt = under_bed(3200, 10000, 3200, 10000, bed, 22)
        add(f"{tag} sweeps under same-band pink bed +{bed} dB", r, t, tr, tt)
    # ---- shaped mic-probe candidates (research/shaped/probe/PROBE-OPTIONS.md)
    fi, fo = 0.2, 0.4
    add("P1 low glide pair: down 1100>300 / down 5500>1500 (5:1)",
        exp_sweep(1100, 300, 1.0, fi, fo), exp_sweep(5500, 1500, 1.0, fi, fo))
    add("P1h check: P1 with 2nd+3rd partials (1, 0.5, 0.25) on the Mac lane",
        exp_sweep(1100, 300, 1.0, fi, fo, (1.0, 0.5, 0.25)), exp_sweep(5500, 1500, 1.0, fi, fo))
    add("P2a whoosh 1.0 s, 300-1100 / 1500-4500, one Hann swell",
        whoosh(300, 1100, 1.0, 31), whoosh(1500, 4500, 1.0, 32))
    add("P2b whoosh 2.0 s, 300-1100 / 1500-4500, three Hann swells",
        whoosh(300, 1100, 2.0, 31, 3), whoosh(1500, 4500, 2.0, 32, 3))
    add("P3 semitone-stepped down 1200>300 / whoosh 1500-4500, same fades",
        stepped_sweep(1200, 300, 1.0, semis, fi, fo), fades(band_noise(1500, 4500, 1.0, 32), fi, fo))
    add("P4 today's Mac lane / BT lane down 4500>2700, fades 200/400",
        exp_sweep(2000, 500, 1.0, fi, fo), exp_sweep(4500, 2700, 1.0, fi, fo))
    add("P4x check: BT lane down 4500>1600 (overlaps the Mac lane's 500-2000)",
        exp_sweep(2000, 500, 1.0, fi, fo), exp_sweep(4500, 1600, 1.0, fi, fo))
    # ---- longer versions (owner allowed probes up to 10 s)
    add("0L3 today's sweeps stretched to 3 s", exp_sweep(2000, 500, 3.0), exp_sweep(3200, 10000, 3.0))
    add("P1L3 P1 stretched to 3 s", exp_sweep(1100, 300, 3.0, fi, fo), exp_sweep(5500, 1500, 3.0, fi, fo))
    for D in (2, 4, 6, 10):
        add(f"P2L{D} whoosh {D} s, fresh noise, {D} x 1 s Hann swells, one {D} s template",
            whoosh(300, 1100, float(D), 31, D), whoosh(1500, 4500, float(D), 32, D))
        r1, t1 = norm(whoosh(300, 1100, 1.0, 31)), norm(whoosh(1500, 4500, 1.0, 32))
        add(f"P2R{D} whoosh {D} x the same 1 s swell, each measured, median arrival",
            np.tile(r1, D), np.tile(t1, D), r1, t1)
        C[-1]["repeat"] = D
        add(f"P3L{D} P3 stretched to {D} s (slower semitone run, longer hiss)",
            stepped_sweep(1200, 300, float(D), semis, fi, fo), fades(band_noise(1500, 4500, float(D), 32), fi, fo))
    for D in (2, 4, 6, 10):
        add(f"P5L{D} P1's Mac sweep 1100>300 / whoosh 1500-4500, {D} s, fades 200/400 on both",
            exp_sweep(1100, 300, float(D), fi, fo), fades(band_noise(1500, 4500, float(D), 32), fi, fo))
    run1 = fades(stepped_sweep(1200, 300, 1.0, semis, 0, 0), 0.01)   # 10 ms joins between repeats
    for D in (4, 10):
        add(f"P3R{D} P3's fast 1 s note run repeated {D}x / whoosh 1500-4500, {D} s, one template, fades 200/400",
            fades(np.tile(run1, D), fi, fo), fades(band_noise(1500, 4500, float(D), 32), fi, fo))
    if ONLY:
        C = [c for c in C if c["name"].split(" ")[0] in ONLY]
    for c in C:
        tr = TRIMS.get(c["name"].split(" ")[0])
        if tr:
            gr, gt = 10 ** (tr[0] / 20), 10 ** (tr[1] / 20)
            for k, g in (("ref", gr), ("tref", gr), ("tgt", gt), ("ttgt", gt)):
                c[k] = c[k] * g
    return C


# ---------------------------------------------------------------- codecs
def run(cmd):
    subprocess.run(cmd, shell=True, check=True, capture_output=True)


def codec_roundtrip(x, codec, tmp):
    src = os.path.join(tmp, "in.wav")
    dec = os.path.join(tmp, "dec.wav")
    k = max(1.0, np.max(np.abs(x)) / 0.9)   # keep peaky stimuli out of clipping
    pad = np.concatenate([np.zeros(FS // 2), x / k, np.zeros(FS // 2)])
    wavfile.write(src, FS, np.clip(pad * 32767, -32768, 32767).astype(np.int16))
    if codec == "aac":
        enc = os.path.join(tmp, "e.m4a")
        run(f"afconvert -f m4af -d aac -b 128000 '{src}' '{enc}' && afconvert -f WAVE -d LEF32 '{enc}' '{dec}'")
    else:
        enc = os.path.join(tmp, "e.sbc")
        run(f"ffmpeg -v error -y -i '{src}' -ac 2 -c:a sbc -b:a 345k -f sbc '{enc}' && "
            f"ffmpeg -v error -y -f sbc -i '{enc}' -ac 1 -c:a pcm_f32le '{dec}'")
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        _, y = wavfile.read(dec)
    return y.astype(np.float64) * k


def codec_delay(codec, tmp):
    """Fixed integer delay of the codec round trip, from white noise."""
    x = np.random.default_rng(99).standard_normal(FS) * 0.1
    y = codec_roundtrip(x, codec, tmp)
    c = fftconvolve(y, x[::-1])
    return int(np.argmax(c)) - (len(x) - 1) - FS // 2


def through(x, codec, tmp, delays):
    if codec == "none":
        return x
    y = codec_roundtrip(x, codec, tmp)
    s = FS // 2 + delays[codec]
    return y[s:s + len(x)]


# ---------------------------------------------------------------- correlator
def next_pow2(n):
    return 1 << int(np.ceil(np.log2(n)))


def noise_weights(ambient, n):
    P = np.abs(np.fft.fft(ambient, n)) ** 2
    r = min(64, n // 2)
    pre = np.concatenate([[0.0], np.cumsum(P)])
    k = np.arange(n)
    lo, hi = np.maximum(0, k - r), np.minimum(n - 1, k + r)
    sm = (pre[hi + 1] - pre[lo]) / (hi - lo + 1)
    eps = max(pre[n] / n * 0.05, 1e-30)
    return (1 / (sm + eps))[: n // 2 + 1]


def correlate(R, probe, n, rec_len, W=None):
    P = np.fft.rfft(probe, n)
    X = R * np.conj(P)
    if W is not None:
        X = X * W
    return np.fft.irfft(X, n)[: rec_len - len(probe) + 1]


def score(peak, bg):
    sigma = np.median(bg) / 0.6744897501960817
    side = np.sqrt(2 * np.log(len(bg))) * sigma
    return peak / side if side > 0 else np.inf


def arrival(corr):
    i = int(np.argmax(corr))
    pk = corr[i]
    if pk <= 0:
        return None, 0.0, 1.0
    ex, sh = int(0.005 * FS), int(0.25 * FS)
    idx = np.arange(len(corr))
    bg = np.abs(corr[(idx < i - ex) | (idx > i + sh)])
    psr = score(pk, bg)
    sep = int(0.003 * FS)
    rival = corr[np.abs(idx - i) > sep].max()
    margin = pk / rival if rival > 0 else np.inf
    off = float(i)
    if 0 < i < len(corr) - 1:
        cm, c0, cp = corr[i - 1], corr[i], corr[i + 1]
        d = cm - 2 * c0 + cp
        if d < 0:
            off += 0.5 * (cm - cp) / d
    return off, psr, margin


def measure(rec, tref, ttgt, ambient):
    n = next_pow2(len(rec) + max(len(tref), len(ttgt)))
    R = np.fft.rfft(rec, n)
    W = noise_weights(ambient, n) if ambient is not None else None
    res = []
    for weights in ((W, None) if W is not None else (None,)):
        a = arrival(correlate(R, tref, n, len(rec), weights))
        b = arrival(correlate(R, ttgt, n, len(rec), weights))
        res = (a, b)
        if a[0] is not None and b[0] is not None and a[1] >= 5 and b[1] >= 5:
            break
    return res


def measure_any(rec, c, ambient):
    """measure() for one-template candidates. For a repeated candidate, measure
    each 1 s swell in its own slice [swell start - 0.3 s, + 1.45 s] (room for a
    +120 ms offset), keep swells where both lanes reach 5, and return the
    median offset with the median per-swell confidences. Refused (None) when
    fewer than half the swells pass."""
    N = c.get("repeat")
    if not N:
        (a, pa, ma), (b, pb, mb) = measure(rec, c["tref"], c["ttgt"], ambient)
        return (None if a is None or b is None else (b - a)), pa, pb, min(ma, mb)
    offs, pas, pbs, mgs = [], [], [], []
    for k in range(N):
        s0, s1 = int((D1 - 0.3 + k) * FS), int((D1 + k + 1.45) * FS)
        (a, pa, ma), (b, pb, mb) = measure(rec[s0:s1], c["tref"], c["ttgt"], ambient)
        pas.append(pa); pbs.append(pb); mgs.append(min(ma, mb))
        if a is not None and b is not None and pa >= 5 and pb >= 5:
            offs.append(b - a)
    off = float(np.median(offs)) if len(offs) * 2 >= N else None
    return off, float(np.median(pas)), float(np.median(pbs)), float(np.median(mgs))


# ---------------------------------------------------------------- scene
def frac_shift(x, delay_s, total):
    n = next_pow2(total + len(x))
    X = np.fft.rfft(x, n)
    f = np.fft.rfftfreq(n, 1 / FS)
    return np.fft.irfft(X * np.exp(-2j * np.pi * f * delay_s), n)[:total]


def reverb(x, rng):
    """Direct path plus 6 discrete echoes 5-60 ms later, gain 0.2-0.5 x
    exp(-delay / 30 ms). Not a room: no diffuse tail, no frequency colour."""
    y = x.copy()
    for d in rng.uniform(0.005, 0.060, 6):
        k = int(d * FS)
        g = rng.uniform(0.2, 0.5) * np.exp(-d / 0.030)
        y[k:] += g * x[: len(x) - k]
    return y


def pink(n, rng, shape="flat"):
    """Unit-RMS pink noise. shape="step12" then lowers everything above 3 kHz
    by 12 dB (half-octave raised-cosine transition centred on 3 kHz) WITHOUT
    renormalising, so the level below 3 kHz matches the flat version."""
    X = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / FS)
    X[1:] /= np.sqrt(np.maximum(f[1:], 20))
    X[0] = 0
    y = np.fft.irfft(X, n)
    k = 1 / np.sqrt(np.mean(y ** 2))
    if shape == "step12":
        lo, hi = 3000 / 2 ** 0.25, 3000 * 2 ** 0.25
        u = np.clip(np.log2(np.maximum(f, 1) / lo) / np.log2(hi / lo), 0, 1)
        g = 1 - (1 - 10 ** (-12 / 20)) * (0.5 - 0.5 * np.cos(np.pi * u))
        y = np.fft.irfft(X * g, n)
    return y * k


def scene(ref, tgt_coded, offset_ms, noise_rms, seed, echoes=True, shape=None):
    rng = np.random.default_rng(seed)
    total = int((D1 + 0.12 + max(len(ref), len(tgt_coded)) / FS + TAIL) * FS)
    g = 10 ** (TARGET_GAIN_DB / 20)
    rv = reverb if echoes else (lambda x, _: x)
    r = rv(frac_shift(ref, D1, total), rng)
    t = rv(frac_shift(tgt_coded * g, D1 + offset_ms / 1000, total), rng)
    rec = r + t + noise_rms * pink(total, rng, SHAPE if shape is None else shape)
    return rec


def leakage_db(tref_play, ttgt, tgt_play):
    """Peak of the target matched filter on the reference lane alone,
    over the peak it gives the target lane alone, at equal level; and the
    same with the reference lane 23 dB louder (positive = the leak beats
    the real target peak)."""
    leak = np.max(np.abs(fftconvolve(tref_play, ttgt[::-1])))
    own = np.max(fftconvolve(tgt_play, ttgt[::-1]))
    iso = 20 * np.log10(leak / own)
    return iso, iso - TARGET_GAIN_DB


def repeat_rival_db(corr, period_s=1.0):
    """Tallest correlation value within +/-20 ms of +/-period_s from the true
    peak, in dB below it (the rival a repeated run creates)."""
    i = int(np.argmax(corr)); p, w = int(period_s * FS), int(0.02 * FS)
    v = [corr[max(0, j - w):j + w].max() for j in (i - p, i + p) if 0 <= j - w and j + w < len(corr)]
    return 20 * np.log10(max(v) / corr[i]) if v else float("nan")


def near_false_peaks(corr):
    """Tallest local maximum within +/-50 ms of the true (highest) peak, in dB
    relative to it: (within 3 ms, i.e. neighbouring carrier cycles; beyond
    3 ms, i.e. what peakMargin calls a rival)."""
    i = int(np.argmax(corr))
    w, sep = int(0.050 * FS), int(0.003 * FS)
    lo, hi = max(1, i - w), min(len(corr) - 1, i + w)
    k = np.arange(lo, hi)
    seg = corr[lo:hi]
    is_max = (seg > corr[lo - 1:hi - 1]) & (seg >= corr[lo + 1:hi + 1]) & (k != i)
    out = []
    for m in (np.abs(k - i) <= sep, np.abs(k - i) > sep):
        sel = is_max & m & (seg > 0)
        if not sel.any():
            out += [-np.inf, np.nan]
            continue
        j = np.argmax(np.where(sel, seg, -np.inf))
        out += [20 * np.log10(seg[j] / corr[i]), (k[j] - i) / FS * 1000]
    return out   # [dB within 3 ms, lag ms, dB 3-50 ms, lag ms]


def distort(x, h2_db=-30.0, h3_db=-40.0):
    """Memoryless speaker-style distortion: for a sine of the lane's peak
    amplitude A, adds a 2nd harmonic h2_db and a 3rd harmonic h3_db below it."""
    A = np.max(np.abs(x))
    a2 = 2 * 10 ** (h2_db / 20) / A
    a3 = 4 * 10 ** (h3_db / 20) / A ** 2
    return x + a2 * x ** 2 - a3 * x ** 3


# ---------------------------------------------------------------- main
def evaluate(c, codec, noise_rms, tmp, delays):
    tgt_play = through(c["tgt"], codec, tmp, delays)
    errs, pr, pt, mg, refused = [], [], [], [], 0
    for o in OFFSETS_MS:
        for s in range(SEEDS):
            rec = scene(c["ref"], tgt_play, o, noise_rms, 1000 + s)
            d, psa, psb, m = measure_any(rec, c, rec[: int(LEAD * FS)])
            pr.append(psa); pt.append(psb); mg.append(m)
            if d is None or psa < 5 or psb < 5:
                refused += 1
                continue
            errs.append(d / FS * 1000 - o)
    errs = np.abs(np.array(errs)) if errs else np.array([np.nan])
    # how much the codec changed the target lane, as a signal-to-error ratio
    if codec == "none":
        cer = np.inf
    else:
        e = tgt_play - c["tgt"]
        cer = 10 * np.log10(np.sum(c["tgt"] ** 2) / np.sum(e ** 2))
    iso, leak23 = leakage_db(c["ref"], c["ttgt"], tgt_play)
    _, leak23_dist = leakage_db(distort(c["ref"]), c["ttgt"], tgt_play)
    # confidence with no room noise and no echoes: the stimulus's own ceiling
    clean = scene(c["ref"], tgt_play, 3.3, 0.0, 0, echoes=False)
    _, cr, ct, _ = measure_any(clean, c, None)
    nfft = next_pow2(len(clean) + max(len(c["tref"]), len(c["ttgt"])))
    Rc = np.fft.rfft(clean, nfft)
    corr_ref = correlate(Rc, c["tref"], nfft, len(clean))
    fp_ref = near_false_peaks(corr_ref)
    rival_1s = repeat_rival_db(corr_ref)
    fp_tgt = near_false_peaks(correlate(Rc, c["ttgt"], nfft, len(clean)))
    n = len(OFFSETS_MS) * SEEDS
    return dict(candidate=c["name"], codec=codec,
                med_err_ms=float(np.median(errs)), worst_err_ms=float(np.max(errs)),
                wrong_gt2ms=int(np.sum(errs > 2)), refused=refused, trials=n,
                med_conf_ref=float(np.median(pr)), med_conf_tgt=float(np.median(pt)),
                min_conf_tgt=float(np.min(pt)), ceil_ref=float(cr), ceil_tgt=float(ct),
                med_margin=float(np.median(mg)), min_margin=float(np.min(mg)),
                iso_db=iso, leak_vs_true_db=leak23, leak_dist_vs_true_db=leak23_dist,
                codec_snr_db=cer,
                fp_ref_in3ms_db=fp_ref[0], fp_ref_in3ms_lag_ms=fp_ref[1],
                fp_ref_3to50ms_db=fp_ref[2], fp_ref_3to50ms_lag_ms=fp_ref[3],
                fp_tgt_in3ms_db=fp_tgt[0], fp_tgt_in3ms_lag_ms=fp_tgt[1],
                fp_tgt_3to50ms_db=fp_tgt[2], fp_tgt_3to50ms_lag_ms=fp_tgt[3], ref_rival_at_1s_db=rival_1s)


def calibrate_noise(c, tmp, delays):
    """Pick the pink-noise RMS that puts the baseline pair's weaker-lane
    confidence near 30 (5 seeds, offset +3.3 ms)."""
    lo, hi = -8.0, 0.0   # log10 of noise rms
    for _ in range(14):
        mid = (lo + hi) / 2
        confs = []
        for s in range(5):
            rec = scene(c["ref"], c["tgt"], 3.3, 10 ** mid, 500 + s, shape="flat")
            (_, a, _), (_, b, _) = measure(rec, c["tref"], c["ttgt"], rec[: int(LEAD * FS)])
            confs.append(min(a, b))
        if np.median(confs) > 30:
            lo = mid
        else:
            hi = mid
    return 10 ** ((lo + hi) / 2)


def write_wavs(C):
    rows = []
    for c in C:
        slug = c["name"].split(" ")[0].replace("'", "p")
        st = np.zeros((max(len(c["ref"]), len(c["tgt"])), 2))
        st[: len(c["ref"]), 0] = c["ref"]
        st[: len(c["tgt"]), 1] = c["tgt"]
        k = max(1.0, np.max(np.abs(st)) / 0.89)  # files only: keep peaks under -1 dBFS
        wavfile.write(os.path.join(OUT, f"{slug}.wav"), FS, (st / k * 32767).astype(np.int16))
        def db(v): return 20 * np.log10(v)
        for lane, x in (("ref", c["ref"]), ("tgt", c["tgt"])):
            rms, pk = np.sqrt(np.mean(x ** 2)), np.max(np.abs(x))
            rows.append((slug, lane, len(x) / FS, db(rms / k), db(pk / k), db(pk / rms)))
    with open(os.path.join(OUT, "levels.tsv"), "w") as f:
        f.write("file\tlane\tseconds\trms_dBFS\tpeak_dBFS\tcrest_dB\n")
        for r in rows:
            f.write("%s\t%s\t%.2f\t%.1f\t%.1f\t%.1f\n" % r)


def main():
    C = candidates()
    if not ONLY:
        write_wavs(C)
    with tempfile.TemporaryDirectory() as tmp:
        delays = {k: codec_delay(k, tmp) for k in ("aac", "sbc")}
        print("codec delays (samples):", delays, flush=True)
        noise = calibrate_noise(C[0], tmp, delays) * 10 ** (BOOST_DB / 20)
        print("noise rms %.3g (%.1f dBFS); baseline lane rms %.1f dBFS"
              % (noise, 20 * np.log10(noise), 20 * np.log10(REF_RMS)), flush=True)
        rows = []
        for c in C:
            for codec in CODECS:
                r = evaluate(c, codec, noise, tmp, delays)
                rows.append(r)
                print("%-62s %-4s err med %.3f worst %.2f wrong %d ref %d/%d conf %.0f/%.0f (min %.1f) ceil %.0f/%.0f margin %.2f/%.2f iso %.1f leak23 %.1f dist %.1f codec %.1f fp %.1f/%.1f %.1f/%.1f"
                      % (r["candidate"][:62], codec, r["med_err_ms"], r["worst_err_ms"], r["wrong_gt2ms"],
                         r["refused"], r["trials"], r["med_conf_ref"], r["med_conf_tgt"], r["min_conf_tgt"],
                         r["ceil_ref"], r["ceil_tgt"], r["med_margin"], r["min_margin"],
                         r["iso_db"], r["leak_vs_true_db"], r["leak_dist_vs_true_db"], r["codec_snr_db"],
                         r["fp_ref_in3ms_db"], r["fp_ref_3to50ms_db"], r["fp_tgt_in3ms_db"], r["fp_tgt_3to50ms_db"]), flush=True)
    name = "results.csv" if BOOST_DB == 0 else "results_noise+%g.csv" % BOOST_DB
    where = HERE
    if ONLY:
        where = os.path.join(HERE, "..", "shaped", "probe")
        os.makedirs(where, exist_ok=True)
        name = "bench_%s%s%s%s.csv" % (SHAPE, "" if BOOST_DB == 0 else "_noise+%g" % BOOST_DB,
                                       "_equal_loudness" if TRIMS else "", f"_{TAG}" if TAG else "")
    with open(os.path.join(where, name), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)


if __name__ == "__main__":
    main()
