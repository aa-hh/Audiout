#!/usr/bin/env bash
# DEBUG-wz7: temporary timing capture for the phone-driven alignment wizard.
# Lives only on the claude/wizard-timing-debug branch; never merged.
#
#   capture.sh start
#       Notes the start time and launches the debug phone build with its
#       console attached, in the background, writing stdout to
#       ${TMPDIR}/wz7/phone.log.
#   capture.sh report
#       Stops that console capture and prints the merged phone + Mac timeline.
#   capture.sh report <phone-log> <since-iso>
#       Same, offline, against a saved phone log and an ISO-8601 UTC start
#       such as 2026-10-25T20:00:00.000Z.
#
# Env: WZ7_LABEL (default wizard-timing, the --name given to ios.sh device),
#      WZ7_DEVICE (default the owner's iPhone),
#      WZ7_TELEMETRY (default ~/Library/Logs/Audiout/telemetry*.jsonl; a
#      file or a directory).
set -euo pipefail

DIR="${TMPDIR:-/tmp}/wz7"
DEVICE="${WZ7_DEVICE:-00008130-000125DE2861401C}"
LABEL="${WZ7_LABEL:-wizard-timing}"
# Same rule as scripts/ios.sh device --name: lowercased, letters and digits.
SLUG=$(printf '%s' "$LABEL" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
BUNDLE="com.audiout.remote.${SLUG:-dev}"

start() {
    mkdir -p "$DIR"
    if [ -f "$DIR/devicectl.pid" ] && kill -0 "$(cat "$DIR/devicectl.pid")" 2>/dev/null; then
        kill "$(cat "$DIR/devicectl.pid")" 2>/dev/null || true
    fi
    date -u +%Y-%m-%dT%H:%M:%S.000Z > "$DIR/start"
    : > "$DIR/phone.log"
    nohup xcrun devicectl device process launch --device "$DEVICE" \
        --terminate-existing --console "$BUNDLE" > "$DIR/phone.log" 2>&1 &
    echo $! > "$DIR/devicectl.pid"
    echo "wz7: started $(cat "$DIR/start"), $BUNDLE on $DEVICE, console -> $DIR/phone.log"
    echo "wz7: run the alignment on the phone, then: $0 report"
}

report() {
    local phone since
    if [ $# -ge 2 ]; then
        phone="$1"; since="$2"
    else
        [ -f "$DIR/start" ] || { echo "wz7: no capture started (run: $0 start)" >&2; exit 1; }
        if [ -f "$DIR/devicectl.pid" ]; then
            kill "$(cat "$DIR/devicectl.pid")" 2>/dev/null || true
            rm -f "$DIR/devicectl.pid"
        fi
        phone="$DIR/phone.log"; since="$(cat "$DIR/start")"
    fi
    local telemetry="${WZ7_TELEMETRY:-$HOME/Library/Logs/Audiout}"
    python3 -I - "$phone" "$since" "$telemetry" <<'PY'
import glob, json, os, re, sys
from datetime import datetime

phone_path, since_iso, telemetry = sys.argv[1:4]

def parse(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()

since = parse(since_iso)
rows = []  # (t, side, phase, fields)

line_re = re.compile(r"DEBUG-wz7 (\S+) (\S+)(.*)")
with open(phone_path, errors="replace") as f:
    for line in f:
        m = line_re.search(line)
        if not m:
            continue
        try:
            t = parse(m.group(1))
        except ValueError:
            continue
        if t >= since:
            rows.append((t, "phone", m.group(2), m.group(3).strip()))

KEEP = {"wizard_ticks_armed", "bt_sink_rebuild", "bt_sink_anchored",
        "sync_session_anchored", "bt_align_measurement", "wizard_keep"}
files = (sorted(glob.glob(os.path.join(telemetry, "telemetry*.jsonl")))
         if os.path.isdir(telemetry) else [telemetry])
for path in files:
    with open(path, errors="replace") as f:
        for line in f:
            if "DEBUG-wz7_" not in line and not any(k in line for k in KEEP):
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            evt = obj.get("evt", "")
            if not (evt.startswith("DEBUG-wz7_") or evt in KEEP):
                continue
            t = parse(obj["ts"])
            if t < since:
                continue
            fields = " ".join(f"{k}={v}" for k, v in obj.items()
                              if k not in ("ts", "sid", "cat", "evt", "level"))
            rows.append((t, "mac", evt.replace("DEBUG-wz7_", ""), fields))

rows.sort(key=lambda r: r[0])
if not rows:
    print(f"wz7: no marks since {since_iso}")
    sys.exit(0)

def phone_times(name):
    return [r[0] for r in rows if r[1] == "phone" and r[2] == name]

starts = phone_times("start_tapped")
zero = starts[-1] if starts else rows[0][0]
print(f"zero = {'last start_tapped' if starts else 'first line'}; "
      f"phone and Mac wall clocks are compared as-is (no skew correction)\n")
print(f"{'t(s)':>8} {'gap(s)':>7}  {'side':<5} {'phase':<34} fields")
prev = None
for t, side, phase, fields in rows:
    gap = "" if prev is None else f"{t - prev:.3f}"
    print(f"{t - zero:8.3f} {gap:>7}  {side:<5} {phase:<34} {fields}")
    prev = t

def first(name, after=zero, side="phone"):
    for t, s, p, f in rows:
        if s == side and p == name and t >= after:
            return t
    return None

def span(label, a, b):
    if a is None or b is None:
        print(f"  {label:<46} n/a")
    else:
        print(f"  {label:<46} {b - a:7.3f} s")

print("\nsummary (from the last start_tapped)")
span("Start -> probe_started_received", zero, first("probe_started_received"))
turn_ends = []
for role in ("target", "reference"):
    for t, s, p, f in rows:
        if s == "phone" and p == "turn_begin" and t >= zero and f"role={role}" in f:
            end = next((t2 for t2, s2, p2, f2 in rows if s2 == "phone" and p2 == "turn_end"
                        and t2 >= t and f"role={role}" in f2), None)
            span(f"turn {role}", t, end)
            if end is not None:
                turn_ends.append(end)
            break
applied = first("measurement_applied_received")
span("last turn_end -> measurement_applied_received",
     max(turn_ends) if turn_ends else None, applied)
gather_end = first("gather_end", applied) if applied else None
span("applied -> gather_end", applied, gather_end)
span("gather_end -> sounds_right_enabled", gather_end,
     first("sounds_right_enabled", gather_end) if gather_end else None)
span("total Start -> locked", zero, first("locked"))
PY
}

case "${1:-}" in
    start) start ;;
    report) shift; report "$@" ;;
    *) echo "usage: $0 start | report [<phone-log> <since-iso>]" >&2; exit 64 ;;
esac
