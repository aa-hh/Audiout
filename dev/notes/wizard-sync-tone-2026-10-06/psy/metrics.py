import numpy as np, warnings
warnings.filterwarnings("ignore")
from scipy.signal import butter, sosfiltfilt
from mosqito import loudness_zwtv, loudness_zwst, sharpness_din_tv, sharpness_din_st, roughness_dw, tnr_ecma_perseg, pr_ecma_perseg
fs = 48000
rng = np.random.default_rng(1)

def sweep(f0, f1, dur=1.0, fade=0.08, amp=0.175):
    t = np.arange(int(fs*dur))/fs
    L = np.log(f1/f0); k = 2*np.pi*f0*dur/L
    x = np.sin(k*(np.exp(t/dur*L)-1))
    n = int(fade*fs); w = 0.5-0.5*np.cos(np.pi*np.arange(n)/n)
    x[:n]*=w; x[-n:]*=w[::-1]
    return amp*x

def tick(f1, f2, amp=0.35):
    t = np.arange(int(fs*0.03))/fs
    env = np.exp(-t/0.006); a = 8; env[:a] *= np.arange(a)/a
    return amp*env*(0.7*np.sin(2*np.pi*f1*t)+0.3*np.sin(2*np.pi*f2*t))

def pink(n):
    X = np.fft.rfft(rng.standard_normal(n)); f = np.fft.rfftfreq(n, 1/fs); f[0]=f[1]
    return np.fft.irfft(X/np.sqrt(f), n)

def bp(x, lo, hi, order=4):
    return sosfiltfilt(butter(order, [lo, hi], btype='band', fs=fs, output='sos'), x)

def whoosh(lo=300, hi=4000, dur=1.0, rise=0.35, fall=0.5):
    x = bp(pink(int(fs*dur)), lo, hi)
    t = np.arange(len(x))/fs
    env = np.where(t<rise, 0.5-0.5*np.cos(np.pi*t/rise), 1.0)
    tf = dur-t; env = np.where(tf<fall, env*(0.5-0.5*np.cos(np.pi*tf/fall)), env)
    return x*env

def mallet(f0, amp=0.35, partials=((1,1.0,0.25),(3.93,0.25,0.06),(9.2,0.08,0.02)), dur=0.6, attack=0.0002):
    # marimba-like: inharmonic modes 1 : ~3.9 : ~9.2, higher modes decay faster
    t = np.arange(int(fs*dur))/fs; x = np.zeros_like(t)
    for r, a, tau in partials: x += a*np.exp(-t/tau)*np.sin(2*np.pi*f0*r*t)
    n = max(1,int(attack*fs)); x[:n] *= np.arange(n)/n
    return amp*x/np.max(np.abs(x))

def pad(x, total=1.5):
    y = np.zeros(int(fs*total)); y[int(0.1*fs):int(0.1*fs)+len(x)] = x; return y

# calibration: digital 1.0 = 1 Pa*sqrt2 peak -> full-scale sine = 94 dB SPL. Signals below keep their real relative levels.
CAL = 1.0
sig = {
 "up sweep 3.2-10 kHz (BT lane)": sweep(3200,10000),
 "down sweep 2-0.5 kHz (Mac lane)": sweep(2000,500, amp=0.175),
 "both sweeps as played (Mac x0.5)": sweep(3200,10000)+0.5*sweep(2000,500),
 "pink noise 300-4000 Hz, 1 s, slow fades": None,
 "pink noise 500-8000 Hz, 1 s, slow fades": None,
 "log sweep 500-4000 Hz, 1 s": sweep(500,4000),
}
w1 = whoosh(300,4000); sig["pink noise 300-4000 Hz, 1 s, slow fades"] = 0.175*w1/np.sqrt(np.mean(w1**2))/np.sqrt(2)
w2 = whoosh(500,8000); sig["pink noise 500-8000 Hz, 1 s, slow fades"] = 0.175*w2/np.sqrt(np.mean(w2**2))/np.sqrt(2)

def report_long(name, x):
    xp = pad(x)
    N, Nsp, bark, tt = loudness_zwtv(xp*CAL, fs, field_type="free")
    S = sharpness_din_tv(xp*CAL, fs, weighting="din", skip=0.1)[0]
    act = N > 0.1*N.max()
    Smean = np.mean(np.asarray(S)[act[:len(S)]]) if len(S)==len(N) else np.nanmean(S)
    R = roughness_dw(xp*CAL, fs, overlap=0.5)[0]
    spl = 20*np.log10(np.sqrt(np.mean(x**2))/2e-5)
    print(f"{name:42s} SPL {spl:5.1f} dB | N5 {np.percentile(N,95):5.2f} sone | S mean {Smean:4.2f} max {np.nanmax(S):4.2f} acum | R max {np.max(R):5.3f} asper")
    return xp

for k,v in sig.items(): report_long(k, v)

# tonality via ECMA-74 tone-to-noise ratio on 85 ms segments, max over segments
print("\nTone-to-noise ratio (ECMA-74/418-1), 4096-sample segments; >~8 dB at 1-3 kHz = 'prominent tone':")
for k in ["up sweep 3.2-10 kHz (BT lane)","down sweep 2-0.5 kHz (Mac lane)","pink noise 300-4000 Hz, 1 s, slow fades","log sweep 500-4000 Hz, 1 s"]:
    x = sig[k]
    try:
        r = tnr_ecma_perseg(x, fs, nperseg=4096, prominence=False)
        T_pr = np.asarray(r[0]); 
        print(f"  {k:42s} total TNR max {np.nanmax(T_pr):5.1f} dB")
    except Exception as e:
        print("  ", k, "TNR error", e)

print("\nShort sounds (sharpness from spectrum of the 30 ms / 300 ms segment):")
shorts = {
 "bright tick 1800+2900": tick(1800,2900),
 "low tick 900+1450": tick(900,1450),
 "marimba-like C5 523 Hz": mallet(523.25),
 "marimba-like G5 784 Hz": mallet(783.99),
 "marimba-like C6 1047 Hz": mallet(1046.5),
 "woodblock-like 1.2 kHz band noise 20 ms": None,
}
nb = bp(rng.standard_normal(int(fs*0.03)), 800, 2000, 2); t=np.arange(len(nb))/fs
shorts["woodblock-like 1.2 kHz band noise 20 ms"] = 0.35*nb/np.max(np.abs(nb))*np.exp(-t/0.006)
for k,x in shorts.items():
    seg = x[:int(0.03*fs)]
    N, Nsp, bark = loudness_zwst(seg*CAL, fs, field_type="free")[:3]
    S = sharpness_din_st(seg*CAL, fs, weighting="din")
    pk = 20*np.log10(np.max(np.abs(x))/2e-5/np.sqrt(2))
    print(f"  {k:42s} peak-equiv SPL {pk:5.1f} dB | S {S:4.2f} acum (first 30 ms)")
