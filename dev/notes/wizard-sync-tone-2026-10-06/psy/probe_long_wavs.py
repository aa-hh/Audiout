"""Listening files for the longer mic-probe versions. Same rules as
probe_options.py: per-lane equal-loudness trims (taken from the 1 s version
with the same spectrum), Mac lane +6 dB, 2 dB placement, 0.5 s lead, and the
same file gain as the 1 s set so all files compare by level.
Run from scratchpad/:  venv/bin/python psy/probe_long_wavs.py"""
import sys, json
import numpy as np
import scipy.io.wavfile as wavfile

SHORT = ["0", "P1", "P2a", "P2b", "P3", "P4"]
LONG = {"0L3": "0", "P1L3": "P1"}
for D in (2, 4, 6, 10):
    LONG.update({f"P2L{D}": "P2a", f"P2R{D}": "P2a", f"P3L{D}": "P3"})
sys.argv = [sys.argv[0], "--only=" + ",".join(SHORT + list(LONG))]
sys.path.insert(0, "research/bench")
import bench  # noqa: E402

fs, OUT = bench.FS, "research/shaped/probe"
PAN = 10 ** (-2 / 20)
T = json.load(open(f"{OUT}/equal_loudness_trims.json"))
C = {c["name"].split(" ")[0]: c for c in bench.candidates()}


def stereo(i, trim):
    r = C[i]["ref"] * 10 ** (trim[0] / 20) * 2
    t = C[i]["tgt"] * 10 ** (trim[1] / 20)
    n = max(len(r), len(t))
    a, b = np.zeros(n), np.zeros(n)
    a[:len(r)], b[:len(t)] = r, t
    st = np.stack([a + PAN * b, PAN * a + b], axis=1)
    return np.concatenate([np.zeros((fs // 2, 2)), st, np.zeros((int(0.3 * fs), 2))])


k = 0.89 / max(np.max(np.abs(stereo(i, T[i]))) for i in SHORT)   # the 1 s set's gain
for i, src in LONG.items():
    x = stereo(i, T[src]) * k
    drop = min(1.0, 0.89 / np.max(np.abs(x)))   # only a file that would clip is lowered, to -1 dBFS peak
    x *= drop
    wavfile.write(f"{OUT}/{i}.wav", fs, (x * 32767).astype(np.int16))
    print(i, "%.1f s, peak %.1f dBFS, lowered %.1f dB vs the 1 s set" % (len(x) / fs, 20 * np.log10(np.max(np.abs(x))), -20 * np.log10(drop)))
