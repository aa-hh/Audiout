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
if os.environ.get("DARK") == "wav3":
    D = "research/shaped/round3"; os.makedirs(D + "/raised", exist_ok=True)
    SR = bench.FS; PANG = 10 ** (-2 / 20)
    dl = bench.dark_lanes()
    L = {k: (dl[k][1], 0.0) for k in ("D2", "D4")}
    L.update({k: (v[1], v[3]) for k, v in bench.round3_lanes().items()})
    T0 = bench.today_real()
    def place(x, right): return np.stack([x * PANG, x], 1) if right else np.stack([x, x * PANG], 1)
    def seq(k, gain_db=0.0):     # 1 s silence; Bluetooth lane (its bed starts at 1 s); Mac lane WIN + GAP after the BT glide
        x, pre = L[k]; g = 10 ** (gain_db / 20)
        t_bt = 1.0 + pre; t_mac = t_bt + bench.WIN + bench.GAP
        out = np.zeros((int((t_mac + bench.WIN + 0.5) * SR), 2))
        for t, pk, right in ((t_bt, bench.BT_PEAK, True), (t_mac, bench.MAC_PEAK, False)):
            s0 = int((t - pre) * SR); out[s0:s0 + len(x)] += place(x * pk * g, right)
        return out
    today = np.concatenate([np.zeros((SR, 2)), place(T0["tgt"], True) + place(T0["ref"], False), np.zeros((SR // 2, 2))])
    files = {"today.wav": today}
    for k in L:
        files[f"{k}.wav"] = seq(k)
        for gdb in (6, 12):
            files[f"raised/{k}_plus{gdb}dB.wav"] = seq(k, gdb)
    gap = np.zeros((2 * SR, 2))
    files["audition.wav"] = np.concatenate([today] + [np.concatenate([gap, seq(k)[SR:]]) for k in L if not k.startswith(("E1x", "E1y"))])
    files["audition_broken_control.wav"] = np.concatenate([seq("D4"), gap, seq("E1x")[SR:], gap, seq("E1x0")[SR:], gap, seq("D2")[SR:], gap, seq("E1y")[SR:], gap, seq("E1y0")[SR:]])
    files["audition_raised.wav"] = np.concatenate([seq("D4")] + [np.concatenate([gap, seq(k, gdb)[SR:]]) for k, gdb in
                                                   (("D4", 6), ("D4", 12), ("E1c", 0), ("E1c", 6), ("E1c", 12))])
    def db(v): return 20 * np.log10(max(v, 1e-12))
    rows = []
    for name, x in files.items():
        assert np.max(np.abs(x)) < 1.0, name
        wavfile.write(f"{D}/{name}", SR, np.round(x * 32767).astype(np.int16))
        on = np.max(np.abs(x), 1) > 10 ** (-60 / 20)
        rows.append(f"{name:32s} {len(x) / SR:5.1f} s  peak {db(np.max(np.abs(x))):6.1f} dBFS  RMS while sounding {db(np.sqrt(np.mean(x[on] ** 2))):6.1f} dBFS")
    open(f"{D}/LEVELS.txt", "w").write(
        "Levels of the round-3 listening files, dBFS (0 dBFS = digital full scale). Not normalised: the samples are the\n"
        "values the app would send. Bluetooth lane on the right, Mac lane on the left, each 2 dB down on the other side.\n"
        "Real level: Bluetooth peak -15 dBFS, Mac peak -27 dBFS. raised/*_plus6dB = -9 / -21 dBFS, *_plus12dB = -3 / -15 dBFS:\n"
        "the +12 dB files are 12 dB louder than the others; turn the volume down before playing them.\n"
        "1 s silence first; a bed starts at 1.0 s and its glide 0.5 s later. today.wav peaks above -15 because both lanes play at once.\n"
        "audition.wav: today, D2, D4, E1c, E1t, E1n, E24, E26, E26c, E29, E29c (E2 with tilt -4, -6, -9 dB per octave; c = with the fifth-chord bed), 2 s gaps.\n"
        "audition_broken_control.wav: D4, E1x (D4 + parallel glide a fifth below at -6 dB), E1x0 (same at equal level),\n"
        "  then D2, E1y (D2 + parallel glides a fifth below at -6 dB), E1y0 (same at equal level).\n"
        "audition_raised.wav: D4 at real level, +6, +12 dB, then E1c at real level, +6, +12 dB.\n"
        "RMS while sounding skips samples below -60 dBFS.\n\n" + "\n".join(rows) + "\n")
    print(open(f"{D}/LEVELS.txt").read())
    sys.exit(0)
if os.environ.get("DARK"):
    # Round 2 (research/shaped/dark): DARK=wav writes listening files + LEVELS.txt at the REAL
    # digital level (no normalising); DARK=psy computes loudness/sharpness/annoyance at that level,
    # full scale taken as 94 dB SPL (1 Pa), the same assumption as round 1.
    D = "research/shaped/dark"; os.makedirs(D, exist_ok=True)
    SR = bench.FS; PANG = 10 ** (-2 / 20)        # Mac on the left, Bluetooth on the right, 2 dB down on the other side
    lanes = {k: v for k, v in bench.dark_lanes().items() if k != "D2s"}; T0 = bench.today_real()
    def sil(s): return np.zeros((int(s * SR), 2))
    def place(x, right): return np.stack([x * PANG, x], 1) if right else np.stack([x, x * PANG], 1)
    def staggered_file(k):    # 1 s silence, Bluetooth window, gap, Mac window, 0.5 s tail
        x = lanes[k][1]
        return np.concatenate([sil(1.0), place(x * bench.BT_PEAK, True), sil(bench.GAP), place(x * bench.MAC_PEAK, False), sil(0.5)])
    def today_file():
        return np.concatenate([sil(1.0), place(T0["tgt"], True) + place(T0["ref"], False), sil(0.5)])
    def db(v): return 20 * np.log10(max(v, 1e-12))
    if os.environ["DARK"] == "wav":
        files = {"today.wav": today_file()}
        for k in lanes:
            files[f"{k}.wav"] = staggered_file(k)
        parts = [today_file()] + [np.concatenate([sil(2.0), staggered_file(k)[int(SR):]]) for k in lanes]
        files["audition.wav"] = np.concatenate(parts)
        rows = []
        for name, x in files.items():
            assert np.max(np.abs(x)) < 1.0
            wavfile.write(f"{D}/{name}", SR, np.round(x * 32767).astype(np.int16))
            on = np.max(np.abs(x), 1) > 10 ** (-60 / 20)
            rows.append(f"{name:13s} {len(x) / SR:5.1f} s   peak {db(np.max(np.abs(x))):6.1f} dBFS   "
                        f"RMS while sounding {db(np.sqrt(np.mean(x[on] ** 2))):6.1f} dBFS   RMS whole file {db(np.sqrt(np.mean(x ** 2))):6.1f} dBFS")
        lane_rows = [f"today  Bluetooth lane peak {db(np.max(np.abs(T0['tgt']))):6.1f}  RMS {db(np.sqrt(np.mean(T0['tgt'] ** 2))):6.1f}   "
                     f"Mac lane peak {db(np.max(np.abs(T0['ref']))):6.1f}  RMS {db(np.sqrt(np.mean(T0['ref'] ** 2))):6.1f}  (1.0 s, both at once)"]
        for k, (_, x) in lanes.items():
            r = np.sqrt(np.mean(x ** 2))
            lane_rows.append(f"{k:6s} Bluetooth window peak {db(bench.BT_PEAK):6.1f}  RMS {db(r * bench.BT_PEAK):6.1f}   "
                             f"Mac window peak {db(bench.MAC_PEAK):6.1f}  RMS {db(r * bench.MAC_PEAK):6.1f}  ({bench.WIN} s each, {bench.GAP} s apart)")
        open(f"{D}/LEVELS.txt", "w").write(
            "Levels of the listening files, dBFS (0 dBFS = digital full scale). Not normalised: the samples are the\n"
            "values the app would send. Bluetooth lane on the right, Mac lane on the left, each 2 dB down on the other side,\n"
            "so a lane's peak in its loud channel is its true level. 1 s silence first; audition.wav = today, then D1-D4, 2 s gaps.\n"
            "today.wav peaks at -12 dBFS, above either lane, because both lanes play at once and add in each channel.\n"
            "Peak = largest sample. RMS = average level; 'while sounding' skips samples below -60 dBFS (the silences).\n\n"
            "Per file:\n" + "\n".join(rows) + "\n\nPer lane (loud channel):\n" + "\n".join(lane_rows) + "\n")
        print(open(f"{D}/LEVELS.txt").read())
    if os.environ["DARK"] == "psy3":
        R3 = "research/shaped/round3"
        dl = bench.dark_lanes()
        L3 = {k: dl[k][1] for k in ("D2", "D4")}
        L3.update({k: v[1] for k, v in bench.round3_lanes().items()})
        def shares(x):
            P = np.abs(np.fft.rfft(x)) ** 2; f = np.fft.rfftfreq(len(x), 1 / SR)
            return 100 * P[(f >= 150) & (f <= 1500)].sum() / P.sum(), 100 * P[f > 2000].sum() / P.sum()
        out = ["id\tprobe_gain_dB\tpart\tSPL_dB\tloudness_N5_sone\tsharpness_acum\troughness_asper\tannoyance_PA\tone_band_share_pct\tenergy_150_1500_pct\tenergy_above_2k_pct"]
        T0m = metrics(T0["ref"] + T0["tgt"])
        out.append("today\t0\tmix as shipped\t%.1f\t%.2f\t%.2f\t%.3f\t%.2f\t%.0f\t-\t-" % (
            20 * np.log10(np.sqrt(np.mean((T0["ref"] + T0["tgt"]) ** 2)) / 2e-5), T0m["N5"], T0m["S"], T0m["R"], T0m["PA"], 100 * T0m["tonal"]))
        print(out[-1], flush=True)
        for k, x in L3.items():
            for gdb in (0, 6, 12):
                y = x * bench.BT_PEAK * 10 ** (gdb / 20)
                m = metrics(y); a, b = shares(y)
                out.append("%s\t%d\tBluetooth window\t%.1f\t%.2f\t%.2f\t%.3f\t%.2f\t%.0f\t%.0f\t%.1f" % (
                    k, gdb, 20 * np.log10(np.sqrt(np.mean(y ** 2)) / 2e-5), m["N5"], m["S"], m["R"], m["PA"], 100 * m["tonal"], a, b))
                print(out[-1], flush=True)
        open(f"{R3}/psy_metrics.tsv", "w").write("\n".join(out) + "\n")
    if os.environ["DARK"] == "psy":
        def band_share(x):
            P = np.abs(np.fft.rfft(x)) ** 2; f = np.fft.rfftfreq(len(x), 1 / SR)
            return 100 * P[(f >= 150) & (f <= 1500)].sum() / P.sum(), 100 * P[f > 2000].sum() / P.sum()
        sets = [("today", "mix as shipped (both at once)", T0["ref"] + T0["tgt"]),
                ("today", "Bluetooth lane alone", T0["tgt"]), ("today", "Mac lane alone", T0["ref"])]
        for k, (_, x) in lanes.items():
            sets += [(k, "Bluetooth window", x * bench.BT_PEAK), (k, "Mac window", x * bench.MAC_PEAK)]
        out = ["id\tpart\tSPL_dB\tloudness_N5_sone\tsharpness_acum\troughness_asper\tannoyance_PA\tone_band_share_pct\tenergy_150_1500_pct\tenergy_above_2k_pct"]
        for k, part, x in sets:
            m = metrics(x); a, b = band_share(x)
            out.append("%s\t%s\t%.1f\t%.2f\t%.2f\t%.3f\t%.2f\t%.0f\t%.0f\t%.1f" % (
                k, part, 20 * np.log10(np.sqrt(np.mean(x ** 2)) / 2e-5), m["N5"], m["S"], m["R"], m["PA"], 100 * m["tonal"], a, b))
            print(out[-1], flush=True)
        open(f"{D}/psy_metrics.tsv", "w").write("\n".join(out) + "\n")
    sys.exit(0)
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
