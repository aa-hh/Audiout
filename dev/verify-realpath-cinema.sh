#!/usr/bin/env bash
#
# verify-realpath-cinema.sh — THE full product demo on real hardware:
# Mac system audio -> audiocap tap -> S16LE FIFO -> OwnTone -> Cinema (real AirPlay 2).
# Run from YOUR Terminal (needs the audio-capture TCC grant, which agent shells lack).
#
# Play some audio on your Mac (music / a video) BEFORE or DURING the run.
# Keeps OwnTone volume low. Auto-stops after the duration.
set -uo pipefail

REPO="/Users/alechenderson/Projects/Audiouted"
AC="$REPO/dev/audiocap/.build/release/audiocap"
FIFO="$REPO/dev/owntone/media/spike.fifo"
API="http://localhost:3689/api"
CINEMA="212032507664419"
DUR="${1:-25}"        # seconds; pass an arg to change

echo "--- preflight ---"
[[ -x "$AC" ]] || { echo "!! audiocap not built at $AC"; exit 1; }
[[ -p "$FIFO" ]] || mkfifo "$FIFO"
curl -s -m5 "$API/outputs" >/dev/null || { echo "!! OwnTone not responding on :3689"; exit 1; }

echo "--- select Cinema, low volume ---"
curl -s -X PUT "$API/outputs/set" -H 'Content-Type: application/json' -d "{\"outputs\":[\"$CINEMA\"]}" -o /dev/null -w "select: %{http_code}\n"
curl -s -X PUT "$API/player/volume?volume=18" -o /dev/null -w "volume->18: %{http_code}\n"

echo "--- start capture -> FIFO (blocks until OwnTone reads) ---"
# no --exclude: Cinema is a remote speaker, no local-feedback loop.
"$AC" --pipe "$FIFO" --duration "$DUR" 2> "$REPO/dev/audiocap/captures/realpath-cinema.log" &
CAP=$!
sleep 1

echo "--- tell OwnTone to play the pipe -> Cinema ---"
# find the pipe track, then explicit clear -> add -> play (autostart is unreliable)
curl -s -X PUT "$API/update" -o /dev/null; sleep 2
PIPE_URI=$(curl -s --get "$API/search" --data-urlencode "type=tracks" --data-urlencode 'expression=data_kind is pipe' | python3 -c "import sys,json;i=json.load(sys.stdin).get('tracks',{}).get('items',[]);print(i[0]['uri'] if i else '')")
[[ -n "$PIPE_URI" ]] || { echo "!! pipe track not found in library"; kill $CAP 2>/dev/null; exit 1; }
curl -s -X PUT  "$API/queue/clear" -o /dev/null -w "clear: %{http_code}\n"
curl -s -X POST "$API/queue/items/add?uris=$PIPE_URI&clear=true" -o /dev/null -w "add: %{http_code}\n"
curl -s -X PUT  "$API/player/play" -o /dev/null -w "play: %{http_code}\n"

echo
echo ">>> Play audio on your Mac now (music/video). It should come out of Cinema. <<<"
echo ">>> Running ${DUR}s..."
wait "$CAP" 2>/dev/null || true

echo "--- teardown ---"
curl -s -X PUT "$API/player/stop" -o /dev/null -w "stop: %{http_code}\n"
curl -s -X PUT "$API/outputs/set" -H 'Content-Type: application/json' -d '{"outputs":[]}' -o /dev/null -w "deselect: %{http_code}\n"
curl -s -X PUT "$API/queue/clear" -o /dev/null -w "clear: %{http_code}\n"
echo "done. capture log: dev/audiocap/captures/realpath-cinema.log"
