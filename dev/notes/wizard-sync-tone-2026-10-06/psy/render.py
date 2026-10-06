# Render + measure the by-ear tick candidates. Run from scratchpad: venv/bin/python research/shaped/ticks/render.py
import os, subprocess, json, sys
exec(open("psy/metrics.py").read().split("sig = {")[0])          # fs, numpy, mosqito, bp(), tick()
exec(open("psy/tonal.py").read().split("allsig")[0].split("\n",1)[1])  # bark(), onebark_share()
from scipy.io import wavfile
from scipy.signal import hilbert
OUT = "research/shaped/ticks"; TMP = OUT + "/_aac"; os.makedirs(TMP, exist_ok=True)
DUR = 0.2   # every tick buffer is 200 ms; the audible part ends well before

def env_attack(n, ms):  # raised-cosine ramp over `ms`
    a = np.ones(n); k = max(1, int(round(ms*1e-3*fs))); a[:k] = 0.5-0.5*np.cos(np.pi*np.arange(k)/k); return a

# ---- baseline: exactly renderTick (30 ms, tau 6 ms, 8-sample linear attack at the engine's 44.1 kHz)
def base(f1, f2, amp):
    t = np.arange(int(fs*DUR))/fs
    env = np.exp(-t/0.006)*np.minimum(1, t/(8/44100)); env[t >= 0.03] = 0
    return amp*env*(0.7*np.sin(2*np.pi*f1*t)+0.3*np.sin(2*np.pi*f2*t))
def aw(f):
    f2=f*f; r=(12194**2*f2*f2)/((f2+20.6**2)*np.sqrt((f2+107.7**2)*(f2+737.9**2))*(f2+12194**2)); return 20*np.log10(r)+2.0
def wE(p): return 0.49*10**(aw(p[0])/10)+0.09*10**(aw(p[1])/10)
CODE_SCALE = np.sqrt(wE((900,1450))/wE((1800,2900)))

# ---- candidates. Each partial: (frequency ratio to the note, relative level, decay time constant s)
MALLET = ((1, 1.0, 0.030), (4, 0.50, 0.008), (10, 0.06, 0.003))
PLUCK  = tuple((k, 1.0/k, 0.035/k**0.7) for k in range(1, 9))
WOOD   = ((1, 1.0, 0.020), (2.3, 0.18, 0.006))
ATTACK_MS = 2.0
def partials(f0, spec, attack_ms=ATTACK_MS):
    t = np.arange(int(fs*DUR))/fs; x = np.zeros_like(t)
    for r, a, tau in spec: x += a*np.exp(-t/tau)*np.sin(2*np.pi*f0*r*t)
    return x*env_attack(len(t), attack_ms)
_noise = np.random.default_rng(7).standard_normal(int(fs*DUR))   # same noise sample on both sides
def wood(f0):
    t = np.arange(int(fs*DUR))/fs
    x = partials(f0, WOOD, 1.0)
    burst = bp(_noise, f0/1.6, min(f0*1.6, 20000), 2)*np.exp(-t/0.002)
    burst *= 0.25*np.max(np.abs(x))/np.max(np.abs(burst))       # noise peak 12 dB under the tone peak
    return x + burst*env_attack(len(t), 0.5)
def norm(x): return x/np.max(np.abs(x))

# ---- metrics
def train(x):
    y = np.zeros(int(fs*1.6))
    for i in range(4): s = int((0.1+0.35*i)*fs); y[s:s+len(x)] += x
    return y
def nmax(x): return float(np.max(loudness_zwtv(train(x), fs, field_type="free")[0]))
def match_gain(x, target):
    g = 1.0
    for _ in range(10): g *= (target/nmax(x*g))**(1/0.6)
    return g
def envelope(x):
    n = len(x); e = np.abs(hilbert(np.concatenate([x, np.zeros(4*n)])))[:n]; k = int(0.0005*fs)   # zero-padded (no wrap-around), 0.5 ms smoothing
    return np.convolve(e, np.ones(k)/k, mode="same")
def rise(x, t0=0):
    e = envelope(x); p = e.max(); i10 = np.argmax(e >= 0.1*p); i90 = np.argmax(e >= 0.9*p)
    return (i90-i10)/fs*1e3, i10/fs*1e3, e
def decay_end(x, db=40):
    e = envelope(x); p = np.argmax(e); thr = e[p]*10**(-db/20)
    above = np.where(e > thr)[0]; return above[-1]/fs*1e3
def sharp(x): return float(sharpness_din_st(x[:int(0.15*fs)], fs, weighting="din"))
def band_energy(x):
    P = np.abs(np.fft.rfft(x, 1 << 16))**2; z = bark(np.fft.rfftfreq(1 << 16, 1/fs))
    e = np.array([P[(z >= b) & (z < b+1)].sum() for b in range(25)]); return e/e.sum()
def overlap(a, b): return float(np.minimum(band_energy(a), band_energy(b)).sum())
def band_share(x, lo, hi):
    P = np.abs(np.fft.rfft(x, 1 << 16))**2; f = np.fft.rfftfreq(1 << 16, 1/fs)
    return float(P[(f >= lo) & (f < hi)].sum()/P.sum())

def aac_roundtrip(x, name):
    # six copies at varied positions so the codec's 1024-sample frame grid lands differently each time
    starts = [int((0.3+0.4*i)*fs)+137*i for i in range(6)]
    y = np.zeros(int(fs*3.0))
    for s in starts: y[s:s+len(x)] += x
    src, enc, dec = f"{TMP}/{name}.wav", f"{TMP}/{name}.m4a", f"{TMP}/{name}_dec.wav"
    wavfile.write(src, fs, (y*32767).astype(np.int16))
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "128000", src, enc], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@48000", enc, dec], check=True)
    r, d = wavfile.read(dec); d = d.astype(float)/32767
    if d.ndim > 1: d = d[:, 0]
    # constant codec delay from whole-file cross-correlation, so "moved" means the onset relative to the body
    n = min(len(y), len(d)); c = np.correlate(d[:n], y[:n], mode="full"); lag = int(np.argmax(c)) - (n-1)
    rb, ob, _ = rise(x)
    rs, ms, pre = [], [], []
    for s in starts:
        seg = d[s+lag-int(0.02*fs): s+lag+len(x)]
        ra, oa, e = rise(seg)
        rs.append(ra); ms.append(oa-20-ob)
        e0 = envelope(seg); pre.append(20*np.log10(e0[:int(0.018*fs)].max()/e0.max()+1e-12))
    return dict(codec_delay_ms=lag/fs*1e3, rise_before=rb, rise_after_mean=float(np.mean(rs)), rise_after_max=float(np.max(rs)),
                onset_moved_mean=float(np.mean(ms)), onset_moved_range=(float(np.min(ms)), float(np.max(ms))), pre_echo_db=float(np.max(pre)))

# ---- build pairs
REF_LOUD = nmax(base(900, 1450, 0.35))   # today's Mac-side knock: every candidate's Mac side is matched to this
pairs = {}
pairs["baseline"] = dict(mac=base(900, 1450, 0.35), bt=base(1800, 2900, 0.35*CODE_SCALE), mac_hz=(900, 1450), bt_hz=(1800, 2900))
def make(name, fn, mac_f, bt_f):
    m = norm(fn(mac_f)); b = norm(fn(bt_f))
    m *= match_gain(m, REF_LOUD); b *= match_gain(b, REF_LOUD)
    pairs[name] = dict(mac=m, bt=b, mac_hz=mac_f, bt_hz=bt_f)
make("T1 fifth",  lambda f: partials(f, MALLET), 440, 660)
make("T1 octave", lambda f: partials(f, MALLET), 440, 880)
make("T2 fifth",  lambda f: partials(f, PLUCK), 440, 660)
make("T2 octave", lambda f: partials(f, PLUCK), 440, 880)
make("T3 fifth",  wood, 1200, 1800)

res = {}
for k, p in pairs.items():
    m, b = p["mac"], p["bt"]
    if k == "baseline":
        nm, nb = nmax(m), nmax(b); unity = nmax(base(1800, 2900, 0.35))
        trim = 20*np.log10(match_gain(base(1800, 2900, 0.35), nm))
        p["bt_iso"] = base(1800, 2900, 0.35)*10**(trim/20)
    else:
        nm, nb = nmax(m), nmax(b)
        trim = 20*np.log10(np.max(np.abs(b))/np.max(np.abs(m)))
    r = dict(mac_hz=p["mac_hz"], bt_hz=p["bt_hz"], loud_mac=nm, loud_bt=nb, trim_db=trim,
             mac_peak_db_re_today=20*np.log10(np.max(np.abs(m))/0.35), bt_peak_db_re_today=20*np.log10(np.max(np.abs(b))/0.35),
             sharp_mac=sharp(m), sharp_bt=sharp(b), tonal_mac=onebark_share(m[:int(0.15*fs)]), tonal_bt=onebark_share(b[:int(0.15*fs)]),
             rise_mac=rise(m)[0], rise_bt=rise(b)[0], end_mac=decay_end(m), end_bt=decay_end(b), overlap=overlap(m, b),
             hf_mac=band_share(m, 1500, 4000), hf_bt=band_share(b, 1500, 4000),
             main_mac=band_share(m, 250, 4000), main_bt=band_share(b, 250, 4000))
    r["aac"] = aac_roundtrip(b, k.replace(" ", "_"))
    res[k] = r
    print(k, json.dumps({a: (round(v, 3) if isinstance(v, float) else v) for a, v in r.items() if a != "aac"}))
    print("   AAC", {a: (round(v, 2) if isinstance(v, float) else v) for a, v in r["aac"].items()})
json.dump(res, open(f"{OUT}/metrics.json", "w"), indent=1, default=float)

# ---- listening files
CHOSEN = {"baseline": "baseline", "T1": sys.argv[1] if len(sys.argv) > 1 else "T1 fifth",
          "T2": sys.argv[2] if len(sys.argv) > 2 else "T2 fifth", "T3": "T3 fifth"}
def pan(th): return np.cos(np.radians(th)), np.sin(np.radians(th))
MACP, BTP, MACG = pan(35), pan(55), 2.0          # Mac slightly left and +6 dB, Bluetooth slightly right
def place(buf, x, at, p, g):
    s = int(at*fs); buf[s:s+len(x), 0] += g*p[0]*x; buf[s:s+len(x), 1] += g*p[1]*x
def metronome(p, beats, bt_shift, lead=0.5):
    buf = np.zeros((int(fs*(lead+3.0*(beats-1)+0.5)), 2))
    for i in range(beats):
        place(buf, p["mac"], lead+3.0*i, MACP, MACG); place(buf, p["bt"], lead+3.0*i+bt_shift, BTP, 1.0)
    return buf
files = {}
for tag, key in CHOSEN.items():
    p = pairs[key]; slug = tag.lower()
    single = np.zeros((int(fs*1.3), 2)); place(single, p["mac"], 0.3, MACP, MACG); place(single, p["bt"], 0.8, BTP, 1.0)
    files[f"{slug}_1_single.wav"] = single
    files[f"{slug}_2_aligned.wav"] = metronome(p, 6, 0.0)
    files[f"{slug}_3_bt_40ms_late.wav"] = metronome(p, 6, 0.040)
    files[f"{slug}_4_bt_40ms_early.wav"] = metronome(p, 6, -0.040)
gap = np.zeros((int(fs*1.5), 2))
files["audition.wav"] = np.concatenate(sum([[metronome(pairs[CHOSEN[t]], 4, 0.0), gap] for t in ("baseline", "T1", "T2", "T3")], [])[:-1])
G = 0.89/max(np.max(np.abs(v)) for v in files.values())    # one gain for every file, so levels compare across files
for n, v in files.items(): wavfile.write(f"{OUT}/{n}", fs, (v*G*32767).astype(np.int16))
print("global file gain", round(20*np.log10(G), 2), "dB;", "chosen", CHOSEN)
