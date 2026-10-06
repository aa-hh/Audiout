#!/bin/bash
# Live check for the Cast one-clock fix: pairs the app's timing lines with timed's corrections.
S=/private/tmp/claude-501/-Users-alechenderson-Projects-AirPlay-Controller--claude-worktrees-cast-routing-research-c01f2e/49d71aa4-a040-4d40-bfd9-69192a7bd00a/scratchpad
SINCE=${1:-2026-10-06T21:09:37}
echo "now $(date -u +%H:%M:%SZ)"
ps -axo pid,lstart,command | grep "Audiout Dev.app/Contents/MacOS" | grep -v grep | grep -q cast-timing-fix-r2 && echo "app: clock-fix build running" || echo "app: CLOCK-FIX BUILD NOT RUNNING"
cat ~/Library/Logs/Audiout/telemetry.jsonl.1 ~/Library/Logs/Audiout/telemetry.jsonl 2>/dev/null > $S/clock-run.jsonl
echo "-- timed corrections (local time) since launch:"
/usr/bin/log show --start "$(date -j -f %Y-%m-%dT%H:%M:%S -v+2H "$SINCE" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')" --predicate 'process == "timed"' --style compact 2>/dev/null | grep 'ntp_adjtime:in' | sed -E 's/.*^([0-9-]+ [0-9:.]+).*offset_us,(-?[0-9]+),freq_scaled,([0-9]+).*/\1/' | awk '{print $2}' | cut -c1-8 | sed 's/^/   /'
/usr/bin/log show --start "$(date -j -f %Y-%m-%dT%H:%M:%S -v+2H "$SINCE" '+%Y-%m-%d %H:%M:%S')" --predicate 'process == "timed"' --style compact 2>/dev/null | grep 'ntp_adjtime:in' | sed -E 's/^([0-9-]+ [0-9:.]+).*offset_us,(-?[0-9]+),freq_scaled,([0-9]+).*/   \1 offset_ms=\2 ppm=\3/' | awk '{printf "%s %s offset_ms=%.1f ppm=%.1f\n",$1,$2,substr($3,11)/1000,substr($4,5)/65536}'
python3 - "$S/clock-run.jsonl" "$SINCE" <<'PY'
import json,sys,statistics as st
def f(x):
  try: return float(x)
  except: return None
rows=[json.loads(l) for l in open(sys.argv[1]) if '"cat":"cast"' in l]
rows=[r for r in rows if r['ts']>=sys.argv[2]]
st_=[r for r in rows if r['evt']=='cast_stage_timing']
sm=[r for r in rows if r['evt']=='cast_speed_match']
settled=[r for r in rows if r['evt']=='cast_lead_settled']
print("settled:",[r['ts'][11:19] for r in settled] or "not yet")
if st_:
  print("-- per minute: ioproc_to_push (median / max field) and age:")
  from collections import defaultdict
  b=defaultdict(list)
  for r in st_: b[r['ts'][11:16]].append(r)
  for k in sorted(b):
    v=b[k]; p=[f(r.get('ioproc_to_push_ms')) for r in v]; mx=[f(r.get('ioproc_to_push_max_ms')) for r in v]; a=[f(r.get('age_ms')) for r in v]; rw=[f(r.get('ring_wait_max_ms')) for r in v]
    p=[x for x in p if x is not None]; mx=[x for x in mx if x is not None]; a=[x for x in a if x is not None]; rw=[x for x in rw if x is not None]
    if not p: continue
    print(f"  {k}Z push med {st.median(p):5.1f} max {max(mx):5.1f} | age med {st.median(a):6.1f} | ring_wait_max {max(rw):5.1f}")
if sm:
  e=[float(r['error_ms']) for r in sm]; p=[float(r['ppm']) for r in sm]
  print(f"speed match: n={len(sm)} err {min(e):+.0f}..{max(e):+.0f} ms, ppm {min(p):+.0f}..{max(p):+.0f}, latest {sm[-1]['ts'][11:19]} {sm[-1]['ppm']} ppm (last-60 median err {st.median([float(r['error_ms']) for r in sm[-60:]]):+.1f})")
PY
