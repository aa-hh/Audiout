#!/bin/bash
S=/private/tmp/claude-501/-Users-alechenderson-Projects-AirPlay-Controller--claude-worktrees-cast-routing-research-c01f2e/49d71aa4-a040-4d40-bfd9-69192a7bd00a/scratchpad
SINCE=2026-10-06T19:54:32
echo "now $(date -u +%H:%M:%SZ)"
ps -axo pid,lstart,command | grep "Audiout Dev.app/Contents/MacOS" | grep -v grep | grep -q cast-timing-fix-r2 && echo "app: sinc build running" || { echo "app: SINC BUILD NOT RUNNING"; ps -axo pid,lstart,command | grep "Audiout Dev.app/Contents/MacOS" | grep -v grep; }
(cd "/Users/alechenderson/Projects/AirPlay Controller" && bash scripts/livetest.sh status 2>&1 | head -1)
cp ~/Library/Logs/Audiout/telemetry.jsonl $S/sinc-run.jsonl
python3 $S/castdrift.py $S/sinc-run.jsonl $SINCE 2>&1 | tail -12
python3 - "$S/sinc-run.jsonl" "$SINCE" <<'PY'
import json,sys,statistics as st
rows=[json.loads(l) for l in open(sys.argv[1]) if '"cat":"cast"' in l]
rows=[r for r in rows if r['ts']>=sys.argv[2]]
sm=[r for r in rows if r['evt']=='cast_speed_match']
if sm:
  e=[float(r['error_ms']) for r in sm]; p=[float(r['ppm']) for r in sm]
  last=[float(r['error_ms']) for r in sm[-60:]]
  print(f"speed match: n={len(sm)} err {min(e):+.0f}..{max(e):+.0f} ms (last 60 median {st.median(last):+.1f}), ppm {min(p):+.0f}..{max(p):+.0f}, latest {sm[-1]['ts'][11:19]} {sm[-1]['ppm']} ppm")
print("tracked moves", sum(1 for r in rows if r['evt']=='cast_lead_tracked'), "| re-settles", sum(1 for r in rows if r['evt']=='cast_lead_settled'), "| feed resets", sum(1 for r in rows if r['evt']=='cast_feed_reset'))
PY
