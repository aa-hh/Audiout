# T1 mallet with shorter decays. Run from scratchpad: venv/bin/python research/shaped/ticks/short/render_short.py
import json
exec(open("research/shaped/ticks/render.py").read().split("# ---- build pairs")[0])
OUTS = "research/shaped/ticks/short"
REF_LOUD = nmax(base(900, 1450, 0.35))
ATT = 1.0
def mallet_tau(f0, tau):  # high partials keep the 30 : 8 : 3 ratio of the original T1
    return partials(f0, ((1, 1.0, tau), (4, 0.5, tau*8/30), (10, 0.06, tau*3/30)), ATT)
MAC, BT = (1.0, 0.7), (0.7, 1.0)    # Mac slightly left, Bluetooth slightly right
def place(buf, x, at, p, g):
    s = int(round(at*fs)); buf[s:s+len(x), 0] += g*p[0]*x; buf[s:s+len(x), 1] += g*p[1]*x
def metro(m, b, shift, beats=6):
    buf = np.zeros((int(fs*(0.5+3.0*(beats-1)+0.5)), 2))
    for i in range(beats): place(buf, m, 0.5+3.0*i, MAC, 1.0); place(buf, b, 0.5+3.0*i+shift, BT, 0.5)  # Bluetooth 6 dB under Mac
    return buf
res = {}
for tau_ms in (6, 10, 15):
    tau = tau_ms/1000
    m = norm(mallet_tau(440, tau)); b = norm(mallet_tau(660, tau))
    m *= match_gain(m, REF_LOUD); b *= match_gain(b, REF_LOUD)    # Mac side as loud as today's Mac tick
    r = dict(tau_ms=tau_ms, mac_peak=float(np.max(abs(m))), bt_peak=float(np.max(abs(b))),
             mac_peak_dbfs=float(20*np.log10(np.max(abs(m)))), trim_db=float(20*np.log10(np.max(abs(b))/np.max(abs(m)))),
             sharp_mac=sharp(m), sharp_bt=sharp(b), rise_mac=rise(m)[0], rise_bt=rise(b)[0],
             end_mac=decay_end(m), end_bt=decay_end(b), overlap=overlap(m, b), hf_mac=band_share(m, 1500, 4000))
    res[tau_ms] = r; print(json.dumps({k: round(v, 3) for k, v in r.items()}))
    blocks = []
    for off in (0, 6, 10, 20, 40):
        x = metro(m, b, off/1000)
        wavfile.write(f"{OUTS}/t1_tau{tau_ms}ms_bt_{off:02d}ms_late.wav", fs, (np.clip(x, -1, 1)*32767).astype(np.int16))
        blocks += [x, np.zeros((int(fs*1.5), 2))]
    a = np.concatenate(blocks[:-1]); print("  audition peak dBFS", round(20*np.log10(np.max(abs(a))), 1))
    wavfile.write(f"{OUTS}/audition_tau{tau_ms}ms.wav", fs, (np.clip(a, -1, 1)*32767).astype(np.int16))
json.dump(res, open(f"{OUTS}/metrics.json", "w"), indent=1)
