"""Psychoacoustic metrics, equal-loudness trims and listening files for the
mic-probe candidates in research/shaped/probe/PROBE-OPTIONS.md.

Synthesis comes from research/bench/bench.py (same functions, same seeds), so
what is measured, heard and benched is the same signal.
Run from scratchpad/:  venv/bin/python psy/probe_options.py
"""
import sys, json, os
import numpy as np
import scipy.io.wavfile as wavfile

IDS = ["0", "P1", "P2a", "P2b", "P3", "P4"]
sys.argv = [sys.argv[0], "--only=" + ",".join(IDS)]
sys.path.insert(0, "research/bench")
import bench  # noqa: E402

# existing psy helpers: onebark_share (tonal.py), mosqito imports (metrics.py)
exec(open("psy/tonal.py").read().split("allsig")[0])
from mosqito import loudness_zwtv, sharpness_din_from_loudness, roughness_dw  # noqa: E402

OUT = "research/shaped/probe"
MAC_DB = 6.0                  # Mac lane heard 6 dB louder than the Bluetooth lane
PAN = 10 ** (-2 / 20)         # slight placement: Mac lane 2 dB down on the right, BT lane 2 dB down on the left

C = {c["name"].split(" ")[0]: c for c in bench.candidates()}


def padded(x):
    return np.concatenate([np.zeros(int(0.1 * fs)), x, np.zeros(int(0.4 * fs))])


def n5(x):
    return np.percentile(loudness_zwtv(padded(x), fs, field_type="free")[0], 95)


def match(x, target):
    g = 1.0
    for _ in range(6):
        g *= (target / n5(x * g)) ** (1 / 0.6)
    return g


def metrics(x):
    xp = padded(x)
    N, Nsp, _, _ = loudness_zwtv(xp, fs, field_type="free")
    S = np.asarray(sharpness_din_from_loudness(N, Nsp, weighting="din"))
    m = N > 0.2 * N.max()
    Sw = np.sum(S[m] * N[m]) / np.sum(N[m])
    N5 = np.percentile(N, 95)
    R = np.mean(roughness_dw(xp, fs, overlap=0.5)[0])
    wS = (Sw - 1.75) * 0.25 * np.log10(N5 + 10) if Sw > 1.75 else 0
    wFR = 2.18 / N5 ** 0.4 * (0.6 * R)   # fluctuation strength taken as 0 (see notes)
    return dict(N5=N5, S=Sw, R=R, PA=N5 * (1 + np.sqrt(wS ** 2 + wFR ** 2)),
                tonal=onebark_share(x))


def heard(ref, tgt):
    n = max(len(ref), len(tgt))
    r = np.zeros(n); r[:len(ref)] = ref * 10 ** (MAC_DB / 20)
    t = np.zeros(n); t[:len(tgt)] = tgt
    return r, t


# 1) per-lane equal-loudness trims against the baseline's own lanes (bench level)
base_ref, base_tgt = n5(C["0"]["ref"]), n5(C["0"]["tgt"])
trims = {}
for i in IDS:
    trims[i] = [20 * np.log10(match(C[i]["ref"], base_ref)), 20 * np.log10(match(C[i]["tgt"], base_tgt))]
json.dump(trims, open(f"{OUT}/equal_loudness_trims.json", "w"), indent=1)

# 2) metrics of the heard mix, whole mix scaled to N5 = 10 sone
rows = []
for i in IDS:
    r, t = heard(C[i]["ref"], C[i]["tgt"])
    mix = r + t
    g = match(mix, 10.0)
    m = metrics(mix * g)
    m_bt = metrics(t * match(t, 10.0))
    rows.append((i, 20 * np.log10(g), 20 * np.log10(np.sqrt(np.mean((mix * g) ** 2)) / 2e-5), m, m_bt))
g0 = rows[0][1]
with open(f"{OUT}/psy_metrics.tsv", "w") as f:
    f.write("id\tmix_gain_vs_baseline_dB\tSPL_dB\tN5_sone\tsharpness_acum\troughness_asper\tPA\tone_band_energy_pct"
            "\tBT_lane_alone_sharpness\tBT_lane_alone_PA\tref_trim_dB\ttgt_trim_dB\n")
    for i, g, spl, m, mb in rows:
        line = "%s\t%.1f\t%.1f\t%.1f\t%.2f\t%.3f\t%.1f\t%.0f\t%.2f\t%.1f\t%.1f\t%.1f" % (
            i, g - g0, spl, m["N5"], m["S"], m["R"], m["PA"], 100 * m["tonal"], mb["S"], mb["PA"], *trims[i])
        f.write(line + "\n"); print(line)

# 3) listening files: equal-loudness lanes, Mac +6 dB, slight placement, 0.5 s lead
files = {}
for i in IDS:
    gr, gt = (10 ** (d / 20) for d in trims[i])
    r, t = heard(C[i]["ref"] * gr, C[i]["tgt"] * gt)
    st = np.stack([r + PAN * t, PAN * r + t], axis=1)
    files[i] = np.concatenate([np.zeros((fs // 2, 2)), st, np.zeros((int(0.3 * fs), 2))])
k = 0.89 / max(np.max(np.abs(v)) for v in files.values())   # one common scale: loudest peak -1 dBFS
for i, v in files.items():
    wavfile.write(f"{OUT}/{i if i != '0' else 'baseline'}.wav", fs, (v * k * 32767).astype(np.int16))
gap = np.zeros((int(1.5 * fs), 2))
aud = [np.zeros((fs // 2, 2))]
for i in IDS:
    aud += [files[i][fs // 2:], gap]
wavfile.write(f"{OUT}/audition.wav", fs, (np.concatenate(aud) * k * 32767).astype(np.int16))
print("common file scale %.1f dB" % (20 * np.log10(k)))
