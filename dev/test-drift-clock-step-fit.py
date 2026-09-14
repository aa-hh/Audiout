#!/usr/bin/env python3
"""Tests for dev/drift-clock-step-fit.py — the parser and the verdict it
prints. Run it directly: `python3 dev/test-drift-clock-step-fit.py`.

Every fixture is a real telemetry.jsonl line shape, written the way
`Telemetry.log` writes it (one JSON object per line, every value a string).
Each test names the defect that would turn it red.

Standard library only.
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("drift-clock-step-fit.py")
_spec = importlib.util.spec_from_file_location("drift_clock_step_fit", SCRIPT)
fitmod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fitmod)


def line(evt, sid="S1", **fields):
    """One telemetry line: the fixed columns plus this event's own fields."""
    obj = {"ts": "2026-09-14T00:00:00Z", "sid": sid, "cat": "local_playback", "evt": evt}
    obj.update({k: str(v) for k, v in fields.items()})
    return json.dumps(obj)


def observations(hostNanos, baselines, errors, sid="S1"):
    """A `drift_window_result` of the shape the sampler logs when it matched
    each speaker to its own peak. `baselines`/`errors` are the pre-joined
    field text, markers included."""
    return line("drift_window_result", sid=sid, result="observations",
                baselines=baselines, errors=errors, hostNanos=hostNanos)


def merged(hostNanos, devices, delayMs, sid="S1"):
    """A `drift_window_result` for two speakers heard as one arrival — the
    shape session 47EF produced for every accepted window."""
    return line("drift_window_result", sid=sid, result="merged",
                devices=devices, delayMs=delayMs, hostNanos=hostNanos)


def jump(hostNanos, uid="BT1", ms="+3.0", sid="S1"):
    fields = {"uid": uid, "ms": ms}
    if hostNanos is not None:
        fields["hostNanos"] = hostNanos
    return line("bt_clock_jump", sid=sid, **fields)


def parse_lines(lines):
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        f.write("\n".join(lines) + "\n")
        path = f.name
    try:
        return fitmod.parse(path)
    finally:
        Path(path).unlink()


SECOND = 1_000_000_000


class ObservationsShape(unittest.TestCase):

    def test_a_guessed_reading_is_kept_and_marked(self):
        """The old filter dropped `(guess)` readings. The sampler marks a
        reading a guess only when it MOVED, so dropping them removed the large
        deltas and kept the small ones — the fit flattened towards zero. Red if
        guessed readings are skipped again, or if the mark is lost."""
        pairs, skipped = parse_lines([
            observations(0, "BT1=100.0", "BT1=+0.0"),
            jump(30 * SECOND, ms="+8.0"),
            observations(60 * SECOND, "BT1=100.0", "BT1=-11.5(guess)"),
        ])
        self.assertEqual(skipped, 0)
        self.assertEqual(len(pairs), 1)
        self.assertAlmostEqual(pairs[0].delta, -11.5)
        self.assertAlmostEqual(pairs[0].step_sum, 8.0)
        self.assertAlmostEqual(pairs[0].seconds, 60.0)
        self.assertTrue(pairs[0].guessed)

    def test_an_anchored_window_reads_the_error_not_the_raw_delay(self):
        """With an AirPlay anchor the sampler folds the mic's own offset into
        the baselines, so `baseline + error` moves when the laptop moves. The
        error alone is mic-corrected. Red if the baseline is added back in:
        this mic moved 30 ms and the speaker did not move at all."""
        pairs, _ = parse_lines([
            observations(0, "AP1(anchor)=200.0,BT1=100.0", "BT1=+0.0"),
            observations(60 * SECOND, "AP1(anchor)=230.0,BT1=130.0", "BT1=+0.0"),
        ])
        self.assertEqual(len(pairs), 1)
        self.assertAlmostEqual(pairs[0].delta, 0.0)
        self.assertTrue(pairs[0].anchor_relative)

    def test_an_anchor_is_never_itself_a_reading(self):
        """An anchor is the reference, not a measured speaker. Red if the
        `(anchor)` marker stops being honoured."""
        pairs, _ = parse_lines([
            observations(0, "AP1(anchor)=200.0,BT1=100.0", "BT1=+0.0"),
            observations(60 * SECOND, "AP1(anchor)=200.0,BT1=100.0", "BT1=+2.0"),
        ])
        self.assertEqual([p.uid for p in pairs], ["BT1"])


class MergedShape(unittest.TestCase):

    def test_merged_lines_pair_on_their_delay(self):
        """`merged` carries `devices`/`delayMs` and no `errors` at all. Red if
        the merged shape stops being read — it is what every accepted window
        of session 47EF produced."""
        pairs, _ = parse_lines([
            merged(0, "BT1,BT2", "150.0"),
            jump(30 * SECOND, uid="BT1", ms="+4.0"),
            merged(60 * SECOND, "BT1,BT2", "154.0"),
        ])
        self.assertEqual(sorted(p.uid for p in pairs), ["BT1", "BT2"])
        for p in pairs:
            self.assertAlmostEqual(p.delta, 4.0)
            self.assertFalse(p.anchor_relative)
        self.assertAlmostEqual(next(p.step_sum for p in pairs if p.uid == "BT1"), 4.0)
        self.assertAlmostEqual(next(p.step_sum for p in pairs if p.uid == "BT2"), 0.0)

    def test_a_merged_reading_does_not_pair_with_an_anchored_one(self):
        """A merged line's raw arrival delay and an anchored line's error are
        different quantities. Red if they are subtracted from each other."""
        pairs, _ = parse_lines([
            observations(0, "AP1(anchor)=200.0,BT1=100.0", "BT1=+0.0"),
            merged(60 * SECOND, "BT1,BT2", "150.0"),
        ])
        self.assertEqual(pairs, [])


class StateResets(unittest.TestCase):

    def test_no_pair_spans_a_session_boundary(self):
        """A new `sid` is a new process: its clock stamps and baselines have no
        relation to the old ones. Red if the sid change stops clearing state."""
        pairs, _ = parse_lines([
            observations(0, "BT1=100.0", "BT1=+0.0", sid="S1"),
            observations(60 * SECOND, "BT1=100.0", "BT1=+5.0", sid="S2"),
            observations(120 * SECOND, "BT1=100.0", "BT1=+7.0", sid="S2"),
        ])
        self.assertEqual(len(pairs), 1)
        self.assertAlmostEqual(pairs[0].delta, 2.0)

    def test_no_pair_spans_a_correction(self):
        """A correction is the app moving the speaker, and a slew is still
        travelling ~20 s after it starts. Red if `drift_correction_started` is
        ignored again: the window inside the slew pairs, and its delta is the
        correction's own partial movement."""
        pairs, _ = parse_lines([
            observations(0, "BT1=100.0", "BT1=+0.0"),
            line("drift_correction_started", device="BT1", ms="-40.0",
                 placement="slew", kind="drift"),
            observations(10 * SECOND, "BT1=100.0", "BT1=-20.0"),
            line("drift_correction_landed", device="BT1", latencyAfterMs="60.0"),
            observations(60 * SECOND, "BT1=100.0", "BT1=-40.0"),
            observations(120 * SECOND, "BT1=100.0", "BT1=-41.0"),
        ])
        self.assertEqual(len(pairs), 1)
        self.assertAlmostEqual(pairs[0].delta, -1.0)

    def test_no_pair_spans_a_rebaseline(self):
        """`result: rebaselined` is the sampler's own name for a shift every
        speaker shared — a microphone that moved. Red if the reading before it
        is kept, which is what let a 30 ms mic move land in a delta."""
        pairs, _ = parse_lines([
            observations(0, "BT1=100.0,BT2=120.0", "BT1=+0.0,BT2=+0.0"),
            line("drift_window_result", result="rebaselined", shiftMs="+30.0",
                 baselines="BT1=130.0,BT2=150.0", hostNanos=30 * SECOND),
            observations(60 * SECOND, "BT1=130.0,BT2=150.0", "BT1=+0.0,BT2=+0.0"),
        ])
        self.assertEqual(pairs, [])


class MalformedInput(unittest.TestCase):

    def test_a_malformed_line_is_skipped_and_reading_continues(self):
        """The log is appended to live, so a truncated last line is normal.
        Red if a bad line stops the parse or raises."""
        pairs, _ = parse_lines([
            observations(0, "BT1=100.0", "BT1=+0.0"),
            '{"ts":"2026-09-14T00:00:00Z","sid":"S1","evt":"drift_window_re',
            "",
            observations(60 * SECOND, "BT1=100.0", "BT1=+3.0"),
        ])
        self.assertEqual(len(pairs), 1)
        self.assertAlmostEqual(pairs[0].delta, 3.0)

    def test_a_result_line_without_host_nanos_is_counted_not_used(self):
        """Older builds wrote no `hostNanos`, and a pair needs both stamps.
        Red if such a line is paired anyway, or stops being counted."""
        pairs, skipped = parse_lines([
            observations(0, "BT1=100.0", "BT1=+0.0"),
            line("drift_window_result", result="observations",
                 baselines="BT1=100.0", errors="BT1=+9.0"),
            observations(60 * SECOND, "BT1=100.0", "BT1=+3.0"),
        ])
        self.assertEqual(skipped, 1)
        self.assertEqual(len(pairs), 1)
        self.assertAlmostEqual(pairs[0].delta, 3.0)

    def test_a_jump_without_host_nanos_still_counts_in_its_interval(self):
        """A step with no stamp is still a step that happened between these two
        readings. Red if an unstamped jump is dropped from the sum."""
        pairs, _ = parse_lines([
            observations(0, "BT1=100.0", "BT1=+0.0"),
            jump(None, ms="+5.0"),
            observations(60 * SECOND, "BT1=100.0", "BT1=+5.0"),
        ])
        self.assertEqual(len(pairs), 1)
        self.assertAlmostEqual(pairs[0].step_sum, 5.0)


class Verdict(unittest.TestCase):

    def pairs(self, sums_and_deltas, guessed=False):
        return [fitmod.Pair("BT1", 60.0, s, d, guessed, True)
                for s, d in sums_and_deltas]

    def test_a_single_pair_carrying_a_step_earns_no_verdict(self):
        """37 pairs with a zero step sum plus one informative pair used to
        print `playout moved`. Red if the gate counts uninformative pairs
        again."""
        pairs = self.pairs([(0.0, 0.0)] * 37 + [(8.0, 8.3)])
        lines = fitmod.verdict(pairs, 20)
        self.assertEqual(lines[0], "pairs 38, of which 1 carry a non-zero step sum")
        self.assertIn("no verdict: 1 pairs carry a step, 20 needed", lines[-1])

    def test_a_clean_one_to_one_run_says_playout_moved(self):
        """The conclusion the script exists to reach. Red if the slope test or
        its tolerance breaks."""
        lines = fitmod.verdict(self.pairs([(float(i), float(i)) for i in range(1, 25)]), 20)
        self.assertEqual(lines[-1], "playout moved (g near +-1)")

    def test_steps_the_sink_absorbs_say_bookkeeping_only(self):
        lines = fitmod.verdict(self.pairs([(float(i), 0.1) for i in range(1, 25)]), 20)
        self.assertEqual(lines[-1], "bookkeeping only (g near 0)")


class EndToEnd(unittest.TestCase):

    def test_the_script_runs_and_prints_both_fits(self):
        """The command a person actually types. Red if the printed report loses
        the confident-only fit, which is what shows whether dropping guessed
        readings changes the answer."""
        lines, error = [], 0.0
        for i in range(25):
            lines.append(observations(i * 60 * SECOND, "BT1=100.0",
                                      f"BT1={error:+.1f}(guess)"))
            step = 1.0 + i % 4          # the sums must differ, or there is no slope
            error += step
            lines.append(jump((i * 60 + 30) * SECOND, ms=f"{step:+.1f}"))
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
            f.write("\n".join(lines) + "\n")
            path = f.name
        try:
            out = subprocess.run([sys.executable, str(SCRIPT), path],
                                 capture_output=True, text=True, check=True).stdout
        finally:
            Path(path).unlink()
        self.assertIn("all readings:", out)
        self.assertIn("playout moved (g near +-1)", out)
        self.assertIn("confident readings only:", out)
        self.assertIn("pairs 0, of which 0 carry a non-zero step sum", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
