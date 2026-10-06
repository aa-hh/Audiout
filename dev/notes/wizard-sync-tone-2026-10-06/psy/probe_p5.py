"""P5 and P3R (run with IDS=P3R4,P3R10). P5 = (P1's Mac sweep + Bluetooth whoosh) at 2-10 s: per-lane equal-loudness
trims (merged into equal_loudness_trims.json), heard-mix metrics at 10 sone
(appended to psy_metrics.tsv), and listening files p5_<D>s.wav at the 1 s set's
file gain. Run from scratchpad/: venv/bin/python psy/probe_p5.py"""
import sys, json
import numpy as np
import scipy.io.wavfile as wavfile
import os
IDS = os.environ.get("IDS", "P5L2,P5L4,P5L6,P5L10").split(",")   # IDS=P3R4,P3R10 for the P3R set
SHORT = ["0", "P1", "P2a", "P2b", "P3", "P4"]
sys.argv = [sys.argv[0], "--only=" + ",".join(SHORT + IDS)]
sys.path.insert(0, "research/bench")
import bench  # noqa: E402
src = open("psy/probe_options.py").read()
exec(src.split("# 1) per-lane")[0].split("IDS = ")[0] + "\n" + "\n".join(
    l for l in src.split("# 1) per-lane")[0].split("\n") if l.startswith(("from mosqito", "exec(", "OUT", "MAC_DB", "PAN"))))
exec("\n".join(src.split("C = {")[1].split("\n")[1:]).split("# 1) per-lane")[0])  # padded, n5, match, metrics, heard
C = {c["name"].split(" ")[0]: c for c in bench.candidates()}
T = json.load(open(f"{OUT}/equal_loudness_trims.json"))
base_ref, base_tgt = n5(C["0"]["ref"]), n5(C["0"]["tgt"])
for i in IDS:
    T[i] = [20 * np.log10(match(C[i]["ref"], base_ref)), 20 * np.log10(match(C[i]["tgt"], base_tgt))]
json.dump(T, open(f"{OUT}/equal_loudness_trims.json", "w"), indent=1)
r0, t0 = heard(C["0"]["ref"], C["0"]["tgt"]); g0 = 20 * np.log10(match(r0 + t0, 10.0))
with open(f"{OUT}/psy_metrics.tsv", "a") as f:
    for i in IDS:
        r, t = heard(C[i]["ref"], C[i]["tgt"]); mix = r + t; g = match(mix, 10.0)
        m = metrics(mix * g); mb = metrics(t * match(t, 10.0))
        line = "%s\t%.1f\t%.1f\t%.1f\t%.2f\t%.3f\t%.1f\t%.0f\t%.2f\t%.1f\t%.1f\t%.1f" % (
            i, 20 * np.log10(g) - g0, 20 * np.log10(np.sqrt(np.mean((mix * g) ** 2)) / 2e-5), m["N5"], m["S"], m["R"],
            m["PA"], 100 * m["tonal"], mb["S"], mb["PA"], *T[i])
        f.write(line + "\n"); print(line)
def stereo(i):
    gr, gt = (10 ** (d / 20) for d in T[i]); r, t = heard(C[i]["ref"] * gr, C[i]["tgt"] * gt)
    return np.concatenate([np.zeros((fs // 2, 2)), np.stack([r + PAN * t, PAN * r + t], 1), np.zeros((int(0.3 * fs), 2))])
k = 0.89 / max(np.max(np.abs(stereo(i))) for i in SHORT)
for i in IDS:
    x = stereo(i) * k; drop = min(1.0, 0.89 / np.max(np.abs(x))); x *= drop
    wavfile.write(f"{OUT}/" + ("p5_%ss.wav" % i[3:] if i.startswith("P5") else "p3r_%ss.wav" % i[3:]), fs, (x * 32767).astype(np.int16))
    print(i, "%.1f s, lowered %.1f dB" % (len(x) / fs, -20 * np.log10(drop)))
