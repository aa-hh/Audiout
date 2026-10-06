exec(open("psy/metrics.py").read().split("for k,v in sig.items()")[0])
from mosqito import loudness_zwtv, sharpness_din_from_loudness
def prof(name, x, show=False):
    xp = pad(x)
    N, Nsp, bark, tt = loudness_zwtv(xp, fs, field_type="free")
    S = np.asarray(sharpness_din_from_loudness(N, Nsp, weighting="din"))
    m = N > 0.2*N.max()
    Sw = np.sum(S[m]*N[m])/np.sum(N[m])
    line = f"{name:42s} N5 {np.percentile(N,95):5.1f} sone | S loudness-weighted {Sw:4.2f} acum, S p10-p90 {np.percentile(S[m],10):4.2f}-{np.percentile(S[m],90):4.2f}"
    if show:
        for tq in (0.25,0.4,0.6,0.8,1.0):
            i = np.argmin(abs(tt-(tq))); line += f"\n      t={tq-0.1:.2f}s in sound: S {S[i]:4.2f} acum, N {N[i]:5.1f} sone"
    print(line)
for k,v in sig.items(): prof(k, v, show=k.startswith("up") or k.startswith("down"))
from mosqito import tnr_ecma_perseg
for k in ["up sweep 3.2-10 kHz (BT lane)","down sweep 2-0.5 kHz (Mac lane)","pink noise 300-4000 Hz, 1 s, slow fades","log sweep 500-4000 Hz, 1 s"]:
    x = sig[k]
    try:
        r = tnr_ecma_perseg(x, fs)
        print(k, "| t_tnr max", np.round(np.nanmax(np.asarray(r[0],dtype=float)),1), "| per-tone TNR max", np.round(np.nanmax(np.concatenate([np.atleast_1d(np.asarray(z,dtype=float)) for z in r[1]])) if len(r[1]) else -1,1))
    except Exception as e: print(k, "err", e)
