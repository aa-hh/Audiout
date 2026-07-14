#!/usr/bin/env bash
#
# verify-0f2-prep.sh — automates Steps 3a-3c of dev/notes/0e3-0f2-verify.md:
# port check, start the "Verify Receiver" shairport instance (stdout backend ->
# capture file), wait for OwnTone to discover it, select it, set volume 70.
#
# Run this, then ./dev/verify-0f2-e2e.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$REPO_ROOT/dev/.run"
mkdir -p "$RUN"

echo "--- 3a: port 5000 free? ---"
if lsof -iTCP:5000 -sTCP:LISTEN -n >/dev/null 2>&1; then
  echo "!! Port 5000 IN USE — turn OFF System Settings > General > AirDrop & Handoff > AirPlay Receiver"
  exit 1
fi
echo "OK: port 5000 free"

echo
echo "--- 3b: start Verify Receiver (silent, stdout backend -> file) ---"
pkill -f 'shairport-sync -c .*verify-recv\.conf' 2>/dev/null && sleep 1
SHAIRPORT="$(command -v shairport-sync)"
[[ -n "$SHAIRPORT" ]] || { echo "!! shairport-sync not found"; exit 1; }
cat > "$RUN/verify-recv.conf" <<'EOF'
general = { name = "Verify Receiver"; output_backend = "stdout"; };
EOF
: > "$RUN/verify-recv.pcm"
"$SHAIRPORT" -c "$RUN/verify-recv.conf" -v > "$RUN/verify-recv.pcm" 2> "$RUN/verify-recv.log" &
RECV=$!
sleep 2
kill -0 "$RECV" 2>/dev/null || { echo "!! receiver died:"; tail -3 "$RUN/verify-recv.log"; exit 1; }
echo "receiver alive, pid = $RECV"

echo
echo "--- waiting for OwnTone to discover 'Verify Receiver' (mDNS) ---"
OUT=""
for i in $(seq 1 15); do
  OUT="$(curl -s http://localhost:3689/api/outputs | python3 -c '
import sys, json
for o in json.load(sys.stdin)["outputs"]:
    if o["name"] == "Verify Receiver":
        print(o["id"]); break
' 2>/dev/null)"
  [[ -n "$OUT" ]] && break
  sleep 2
done
[[ -n "$OUT" ]] || { echo "!! OwnTone never discovered 'Verify Receiver' (is OwnTone running on :3689?)"; exit 1; }
echo "discovered, output id = $OUT"

echo
echo "--- 3c: select + set volume 70 ---"
curl -s -X PUT "http://localhost:3689/api/outputs/set" -H 'Content-Type: application/json' \
  -d "{\"outputs\":[\"$OUT\"]}" -o /dev/null -w "select: %{http_code}\n"
curl -s -X PUT "http://localhost:3689/api/outputs/$OUT" -H 'Content-Type: application/json' \
  -d '{"volume": 70}' -o /dev/null -w "volume: %{http_code}\n"

echo
echo "=== prep done — now run: ./dev/verify-0f2-e2e.sh ==="
