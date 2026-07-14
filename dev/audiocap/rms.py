#!/usr/bin/env python3
"""Analyze a raw interleaved Float32 LE .pcm file (audiocap --out output).

Two modes:

  rms.py <file.pcm> [channels]
      Print RMS + peak + dBFS and a SILENT / NON-SILENT verdict.

  rms.py --tones <file.pcm> <rate> <present_hz> <absent_hz> [channels]
      Goertzel tone detection for the per-app / exclude PASS/FAIL test.
      Reports the magnitude of <present_hz> and <absent_hz> in the capture and
      prints PASS iff the "present" tone dominates the "absent" tone by a clear
      margin (>= 8x). Used to prove a --pid tap captured ONLY the intended app
      (its tone present, the other app's tone absent), and that --exclude did the
      inverse (excluded app's tone absent, everything-else tone present).
"""
import sys
import struct
import math


def read_float32_mono_mix(path, channels):
    """Read the file and downmix to a mono float list (average of channels)."""
    with open(path, "rb") as f:
        data = f.read()
    n = len(data) // 4
    if n == 0:
        return [], 0
    samples = struct.unpack("<%df" % n, data[:n * 4])
    if channels <= 1:
        return list(samples), len(data)
    frames = n // channels
    mono = [0.0] * frames
    for i in range(frames):
        acc = 0.0
        base = i * channels
        for c in range(channels):
            acc += samples[base + c]
        mono[i] = acc / channels
    return mono, len(data)


def goertzel(samples, rate, target_hz):
    """Return the normalized magnitude of target_hz in `samples` (Goertzel).

    Normalized so a full-scale pure sine at target_hz gives ~0.5 (amplitude/2),
    which makes the absolute value comparable across capture lengths.
    """
    n = len(samples)
    if n == 0:
        return 0.0
    k = int(0.5 + (n * target_hz) / rate)
    omega = (2.0 * math.pi * k) / n
    coeff = 2.0 * math.cos(omega)
    s_prev = 0.0
    s_prev2 = 0.0
    for x in samples:
        s = x + coeff * s_prev - s_prev2
        s_prev2 = s_prev
        s_prev = s
    real = s_prev - s_prev2 * math.cos(omega)
    imag = s_prev2 * math.sin(omega)
    mag = math.sqrt(real * real + imag * imag)
    return (2.0 * mag) / n  # normalize by length -> amplitude-ish


def rms_mode(path, channels):
    mono, nbytes = read_float32_mono_mix(path, channels)
    if not mono:
        print("empty file")
        sys.exit(1)
    total = 0.0
    peak = 0.0
    # RMS over raw samples (not the downmix) is nicer, but downmix RMS is fine here.
    for s in mono:
        total += s * s
        a = abs(s)
        if a > peak:
            peak = a
    rms = math.sqrt(total / len(mono))
    dbfs = 20 * math.log10(rms) if rms > 0 else float("-inf")
    print(f"bytes={nbytes} frames={len(mono)} channels={channels}")
    print(f"RMS={rms:.6f} ({dbfs:.2f} dBFS)  peak={peak:.6f}")
    if rms < 1e-6:
        print("VERDICT: SILENT (essentially zero) — capture likely not granted or no audio playing")
    else:
        print("VERDICT: NON-SILENT — audio was captured")


def tones_mode(path, rate, present_hz, absent_hz, channels):
    mono, nbytes = read_float32_mono_mix(path, channels)
    if not mono:
        print("empty file")
        print("VERDICT: FAIL (no samples)")
        sys.exit(1)
    present_mag = goertzel(mono, rate, present_hz)
    absent_mag = goertzel(mono, rate, absent_hz)
    frames = len(mono)
    print(f"bytes={nbytes} frames={frames} rate={rate} channels={channels}")
    print(f"present tone {present_hz} Hz : magnitude {present_mag:.6f}")
    print(f"absent  tone {absent_hz} Hz : magnitude {absent_mag:.6f}")

    # Guardrails: the present tone must be clearly audible AND clearly dominate.
    MIN_PRESENT = 0.02       # present tone must be non-trivial
    DOMINANCE = 8.0          # present must beat absent by >= 8x
    ratio = present_mag / absent_mag if absent_mag > 0 else float("inf")
    print(f"present/absent ratio = {ratio:.1f} (need >= {DOMINANCE})")
    if present_mag < MIN_PRESENT:
        print(f"VERDICT: FAIL — present tone too weak ({present_mag:.6f} < {MIN_PRESENT}). "
              "Was the intended app actually playing, and did the tap capture it?")
        sys.exit(1)
    if ratio < DOMINANCE:
        print(f"VERDICT: FAIL — the '{absent_hz} Hz' tone leaked in (ratio {ratio:.1f} < {DOMINANCE}). "
              "The tap captured audio it should NOT have.")
        sys.exit(1)
    print(f"VERDICT: PASS — {present_hz} Hz present and {absent_hz} Hz absent, as required.")


def main():
    args = sys.argv[1:]
    if args and args[0] == "--tones":
        if len(args) < 5:
            print("usage: rms.py --tones <file.pcm> <rate> <present_hz> <absent_hz> [channels]",
                  file=sys.stderr)
            sys.exit(2)
        path = args[1]
        rate = float(args[2])
        present_hz = float(args[3])
        absent_hz = float(args[4])
        channels = int(args[5]) if len(args) > 5 else 2
        tones_mode(path, rate, present_hz, absent_hz, channels)
        return

    if not args:
        print("usage: rms.py <file.pcm> [channels]", file=sys.stderr)
        print("       rms.py --tones <file.pcm> <rate> <present_hz> <absent_hz> [channels]",
              file=sys.stderr)
        sys.exit(2)
    path = args[0]
    channels = int(args[1]) if len(args) > 1 else 2
    rms_mode(path, channels)


if __name__ == "__main__":
    main()
