#!/usr/bin/env python3
"""Pair Bluetooth pacing-clock steps with the acoustic drift readings around
them, and check whether the steps explain the readings' movement.

Input: ~/Library/Logs/Audiout/telemetry.jsonl (or a path argument), one JSON
object per line, written by `Telemetry.log` (see Telemetry.swift). Every field
value is a string. Two lines matter most:
  bt_clock_jump      a Bluetooth sink's pacing clock stepped by more than
                      BTClockStability.jumpThresholdMs (see BTClockWatcher).
  drift_window_result what one passive-drift measurement window heard, per
                      device (see PassiveDriftSampler.logWindow).
Both now carry `hostNanos`, the CLOCK_MONOTONIC stamp of the sample, so a
clock step can be placed on the same timeline as the acoustic readings that
bracket it.

For each device, between one accepted acoustic reading and the next, this
sums every clock-step line that landed in between and compares that sum to
how much the reading itself moved. If the reading moves with the steps
(slope near +-1), the steps are shifting what actually gets played out. If
the reading barely moves regardless of how much the clock stepped (slope
near 0), the steps are bookkeeping the sink already absorbs.

Three things decide whether the slope can be believed, so all three are
printed rather than applied silently:

  Guessed readings. The sampler marks a reading `(guess)` only when it both
  MOVED and was ambiguous to assign (`isBestGuess` in PassiveDriftSampler).
  Dropping them therefore drops large deltas and keeps small ones, which
  flattens the slope towards 0 — the exact answer under test. So every
  reading is kept, and the same fit is printed a second time over the
  confident readings alone: if the two disagree, the assignment ambiguity is
  doing the deciding, not the clock steps.

  Microphone movement. An `observations` line measured against an AirPlay
  anchor carries a mic-corrected error per device (decision 13), and that
  error is used as the reading, so moving the laptop cancels out. Without an
  anchor the only figure available is the raw arrival delay, in which a mic
  that moved is indistinguishable from a speaker that moved; those pairs are
  marked `raw` and counted in the last printed line. A shared shift the
  sampler itself recognised (`result: rebaselined`) ends the run of readings
  so no pair spans it.

  Pairs that carry no step. A pair whose step sum is zero says nothing about
  the slope, so the `--min-pairs` gate counts only pairs with a non-zero step
  sum; the fit itself still uses every pair.

Usage: python3 dev/drift-clock-step-fit.py [path] [--min-pairs 20]
Standard library only. Its test is dev/test-drift-clock-step-fit.py.
"""
import json
import os
import statistics
import sys
from collections import namedtuple

DEFAULT_LOG = os.path.expanduser("~/Library/Logs/Audiout/telemetry.jsonl")
GAIN_TOLERANCE = 0.3
MIN_FIT_PAIRS = 3

#: One device's movement between two consecutive readings. `anchor_relative`
#: is False when the reading is a raw arrival delay, which a microphone move
#: contaminates; `guessed` is True when either end of the pair was a `(guess)`.
Pair = namedtuple("Pair", "uid seconds step_sum delta guessed anchor_relative")


def parse_tagged_list(text, tag_on_key=False, tag_on_value=False, tag="(anchor)"):
    """Split a comma-joined `key<tag>=value<tag>` field into
    {key: (value, tagged)}, skipping empty input."""
    out = {}
    if not text:
        return out
    for entry in text.split(","):
        key, _, value = entry.partition("=")
        tagged = False
        if tag_on_key and key.endswith(tag):
            key = key[: -len(tag)]
            tagged = True
        if tag_on_value and value.endswith(tag):
            value = value[: -len(tag)]
            tagged = True
        try:
            out[key] = (float(value), tagged)
        except ValueError:
            continue
    return out


def readings_for(fields):
    """[(uid, value, guessed, anchor_relative)] this drift_window_result line
    reports, or [].

    Two readings may only be subtracted from each other when their
    `anchor_relative` flags agree: an anchor-relative value is the device's
    error against its own baseline with the microphone's offset already taken
    out, a raw value is the arrival delay itself.
    """
    result = fields.get("result")
    if result == "observations":
        baselines = parse_tagged_list(fields.get("baselines", ""), tag_on_key=True, tag="(anchor)")
        errors = parse_tagged_list(fields.get("errors", ""), tag_on_value=True, tag="(guess)")
        # With an anchor in the window the logged error is already the
        # deviation minus the mic's own offset, so it is the mic-independent
        # figure and the baseline (which the sampler shifted by that offset)
        # must be left out of it.
        anchored = any(is_anchor for _, is_anchor in baselines.values())
        readings = []
        for uid, (error_ms, is_guess) in errors.items():
            if uid not in baselines:
                continue
            baseline_ms, is_anchor = baselines[uid]
            if is_anchor:
                continue
            value = error_ms if anchored else baseline_ms + error_ms
            readings.append((uid, value, is_guess, anchored))
        return readings
    if result == "merged":
        devices = [d for d in fields.get("devices", "").split(",") if d]
        try:
            delay_ms = float(fields.get("delayMs", ""))
        except ValueError:
            return []
        return [(uid, delay_ms, False, False) for uid in devices]
    return []


def parse(path):
    """(pairs, skipped): every consecutive pair of readings for one device,
    with the clock steps that landed between them, and how many result lines
    were unusable because they carry no `hostNanos`."""
    last = {}        # uid -> (hostNanos, value, anchor_relative, guessed)
    pending = {}     # uid -> [(hostNanos, stepMs)]
    current_sid = None
    last_jump_nanos = 0
    pairs = []
    skipped = 0

    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            evt = obj.get("evt")
            if evt not in ("session_start", "bt_clock_jump", "bt_clock_deviation",
                            "drift_window_result", "drift_correction_started",
                            "drift_correction_landed", "drift_tracking_state"):
                continue
            sid = obj.get("sid")
            if sid != current_sid or evt == "session_start":
                last.clear()
                pending.clear()
                current_sid = sid

            if evt == "bt_clock_jump":
                uid = obj.get("uid")
                try:
                    ms = float(obj.get("ms", "0"))
                except ValueError:
                    continue
                if "hostNanos" in obj:
                    try:
                        last_jump_nanos = int(obj["hostNanos"])
                    except ValueError:
                        pass
                pending.setdefault(uid, []).append((last_jump_nanos, ms))
            elif evt == "bt_clock_deviation":
                pass  # counted as recognised, not used for the fit
            elif evt in ("drift_correction_started", "drift_correction_landed"):
                # The app moving the speaker itself, not the speaker drifting.
                # A slew moves 1 ms per 0.5 s, so a 40 ms correction is still
                # travelling 20 s later: a window that fires inside that span
                # reads the correction's own partial movement, with the sign
                # opposite to the step that caused it. Both ends of that span
                # are dropped, so neither the start nor the landing can pair.
                device = obj.get("device")
                last.pop(device, None)
                pending.pop(device, None)
            elif evt == "drift_tracking_state":
                last.clear()
                pending.clear()
            elif evt == "drift_window_result":
                if obj.get("result") == "rebaselined":
                    # The sampler read one shift every speaker shared and moved
                    # every baseline by it — its own name for a microphone that
                    # moved. A pair spanning it would carry that shift as though
                    # the speakers had moved, so the run of readings ends here.
                    last.clear()
                    pending.clear()
                    continue
                if "hostNanos" not in obj:
                    skipped += 1
                    continue
                try:
                    host_nanos = int(obj["hostNanos"])
                except ValueError:
                    skipped += 1
                    continue
                for uid, value, guessed, anchor_relative in readings_for(obj):
                    if uid in last:
                        last_nanos, last_value, last_anchored, last_guessed = last[uid]
                        # Two readings measured against different things cannot
                        # be subtracted from each other.
                        if last_anchored == anchor_relative:
                            seconds = (host_nanos - last_nanos) / 1e9
                            step_sum = sum(ms for stamp, ms in pending.get(uid, [])
                                           if stamp <= host_nanos)
                            pairs.append(Pair(uid, seconds, step_sum, value - last_value,
                                              guessed or last_guessed, anchor_relative))
                    last[uid] = (host_nanos, value, anchor_relative, guessed)
                    pending[uid] = [(stamp, ms) for stamp, ms in pending.get(uid, [])
                                    if stamp > host_nanos]
    return pairs, skipped


def verdict(pairs, min_pairs):
    """The lines a reader should see for `pairs`: the counts, the fit, and the
    conclusion those support — or a refusal when too few pairs carry a step."""
    informative = [p for p in pairs if p.step_sum != 0]
    lines = [f"pairs {len(pairs)}, of which {len(informative)} carry a non-zero step sum"]
    if len(pairs) < MIN_FIT_PAIRS:
        lines.append("too few pairs")
        return lines
    if len({p.step_sum for p in pairs}) < 2:
        lines.append("no steps between readings; slope undefined")
        return lines
    sums = [p.step_sum for p in pairs]
    deltas = [p.delta for p in pairs]
    gain, intercept = statistics.linear_regression(sums, deltas)
    residual = statistics.pstdev(d - (gain * s + intercept) for s, d in zip(sums, deltas))
    lines.append(f"g {gain:.2f}  c {intercept:+.2f}  residual {residual:.2f}")
    if len(informative) < min_pairs:
        lines.append(f"no verdict: {len(informative)} pairs carry a step, {min_pairs} needed")
    elif abs(gain - 1) <= GAIN_TOLERANCE or abs(gain + 1) <= GAIN_TOLERANCE:
        lines.append("playout moved (g near +-1)")
    elif abs(gain) <= GAIN_TOLERANCE:
        lines.append("bookkeeping only (g near 0)")
    else:
        lines.append("unresolved")
    return lines


def report(pairs, skipped, min_pairs):
    """Every printed line, in order, for one parsed log."""
    lines = []
    for p in pairs:
        marks = "guess " if p.guessed else "      "
        marks += "anchor-relative" if p.anchor_relative else "raw"
        lines.append(f"{p.uid:24s} {p.seconds:8.1f}s {p.step_sum:8.1f}ms "
                     f"{p.delta:+8.1f}ms  {marks}")
    lines.append(f"skipped {skipped} result lines without hostNanos")
    lines.append("all readings:")
    lines += [f"  {line}" for line in verdict(pairs, min_pairs)]
    # A guessed reading is a less certain assignment, not a wrong one. Both
    # fits are printed because dropping the guesses drops moved readings only.
    lines.append("confident readings only:")
    lines += [f"  {line}" for line in verdict([p for p in pairs if not p.guessed], min_pairs)]
    raw = sum(1 for p in pairs if not p.anchor_relative)
    if raw:
        lines.append(f"{raw} of {len(pairs)} pairs are not measured against an AirPlay "
                     "anchor: in those, a microphone that moved cannot be told apart "
                     "from a speaker that moved, so read the slope as an upper bound.")
    return lines


def fit(path, min_pairs):
    pairs, skipped = parse(path)
    for line in report(pairs, skipped, min_pairs):
        print(line)


if __name__ == "__main__":
    args = sys.argv[1:]
    path = DEFAULT_LOG
    if args and not args[0].startswith("--"):
        path = args.pop(0)
    min_pairs = 20
    if "--min-pairs" in args:
        min_pairs = int(args[args.index("--min-pairs") + 1])
    fit(path, min_pairs)
