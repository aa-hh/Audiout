#!/bin/zsh
# Unattended listening night for the Bluetooth sync fixes. See README.md here.
#
#   ./unattended-night.sh [--dry-run | --smoke] [--relaunch] [--with-airplay | --only-c] [--move1 ID] [--move2 ID] [--airplay-id ID] [--c-move ID]
#   ./unattended-night.sh --list-devices      # ids this Mac has seen, in the form the driver takes
#   ./unattended-night.sh --check [flags]     # tools, ids and build only, then exit (launch-tonight.sh runs it)
#
# Block A (25 min): both Moves, click track loops, mic records; at minute 22 the
#   Move that is not --c-move is disconnected for 10 s and reconnected (needs
#   blueutil). Last, because in the 2026-10-03 smoke run that Move stayed silent
#   for the rest of the run after its reconnect.
# Block B (~5 min): the --c-move Move, plus This Mac; play 60 s, pause 90 s, play 60 s.
#
# Selection is manual by default: at each block the driver writes a WAITING line
# naming the rows to select in Audiout Dev and waits for Enter or
# ~/listening/go-block-<a|b|c>, then checks telemetry. The app's launch-time
# restore leaves Bluetooth speakers selected but not connected (third smoke run,
# 2026-10-03), so the relaunch path is kept behind --relaunch for when it is fixed.
# Block C (60 min, --with-airplay only): one Move on Bluetooth (--c-move, default
#   Move 1) + the other Move in Wi-Fi mode as an AirPlay speaker (--airplay-id).
#   A Move is Bluetooth or AirPlay, never both, and switching is a button press,
#   so before Block C the driver waits for someone to switch it and confirm.
# Then: convert, run click-pair-spacing.py, cut each block's telemetry lines,
# write results/<date>/summary.md.
#
# --dry-run: every phase lasts 10 s, Audiout is not relaunched and Bluetooth is
# not touched. Exercises afplay, recording, conversion, analysis and the
# summary on any Mac. If the mic cannot be used it falls back to a synthetic
# recording and says so in the summary.
#
# Playback is afplay of a 75-minute copy of the click track, never QuickTime:
# in the second smoke run QuickTime kept playing but its output left Audiout's
# aggregate device after about 16 s.
#
# --smoke: the real run, shortened for a rehearsal with the owner in the room:
# Block A 2 min (disconnect at 1:30), Block B 20 s / 30 s / 20 s, Block C 2 min.
#
# A watchdog checks the recording, the mic level, the clicks, the clock lines and
# the load every WATCH_EVERY_S during each block and writes results/<date>/status.log.
set -euo pipefail
zmodload zsh/datetime

# ---- Parameters -------------------------------------------------------------
HERE=${0:A:h}
APP="$HOME/Applications/Audiout Dev.app"
BUNDLE_ID=com.audiout.Audiout.dev
SUPPORT="$HOME/Library/Application Support/$BUNDLE_ID"
TRIMS="$SUPPORT/bt-sync-trims.json"
ROUTING="$SUPPORT/routing.json"
# Selection changes: with Settings > General "Reconnect last speakers when Audiout
# starts" on, launch restores routing.json's selectedDeviceIDs
# (GroupController.ensureDefaultSelection). The setting is off by default.
RECONNECT_KEY=general.reconnectAtLaunch
LIVE_CHECK_S=90      # after a relaunch, telemetry must show exactly the wanted speakers within this
RELAUNCH_TRIES=2     # a speaker discovered after the restore is dropped, so one more relaunch
# Device ids exactly as `--list-devices` prints them ON THE MAC THAT RUNS THIS.
# Bluetooth: the speaker's address with dashes plus ":output"; AirPlay: colon hex.
MOVE1_ID=""
MOVE2_ID=""
AIRPLAY_ID=""            # only needed for --with-airplay: the other Move's id in Wi-Fi mode
C_MOVE_ID=""             # the Move that stays on Bluetooth in Block C; empty = MOVE1_ID
GO_DIR="$HOME/listening"  # touch $GO_DIR/go-block-<a|b|c> to confirm a WAITING line (Enter works too at a terminal)
WAIT_C_S=1800           # how long a WAITING line waits before that block is aborted
SELECT_CHECK_S=35       # after confirming: telemetry must show the selection within this (bt_clock_deviation is every 30 s)
SELECT_TRIES=3          # WAITING is shown again after a mismatch, this many times in all
RECONNECT_SINK_S=60     # Block A: after the reconnect, a sink line for that Move must appear within this
MAC_ROW="This Mac (the MacBook Air Speakers row)"
AIRPLAY_NAME="AirPlay speaker"
MAC_ID=local-mac         # This Mac; the same id on every Mac
MAC_VOLUME=50            # system output volume set before each relaunch; Audiout adopts it as its master level
# Recording: ffmpeg. MIC_INDEX empty = find the built-in mic in
# `ffmpeg -f avfoundation -list_devices true -i ""`.
MIC_INDEX=""
MIC_PATTERN='MacBook.*Microphone|Built-in Microphone'
CLICK_WAV="$HERE/click-track-3s.wav"      # beside the script (the ~/listening copy); else the repo's runbooks folder
ANALYSER="$HERE/click-pair-spacing.py"
[[ -f $CLICK_WAV ]] || CLICK_WAV="$HERE/../notes/bt-sync-discovery/runbooks/click-track-3s.wav"
[[ -f $ANALYSER ]] || ANALYSER="$HERE/../notes/bt-sync-discovery/runbooks/click-pair-spacing.py"
LONG_WAV="$HERE/click-track-70min.wav"   # the 30 s click track 151 times (75.5 min), made once with ffmpeg
LONG_LOOPS=150
AUDIO_PEAK_DB=-60    # stream_health peak_dbfs above this (or silent_s 0) means the app is getting audio
AUDIO_WAIT_S=15      # after a play command, wait this long for such a stream_health line
PYTHON=${PYTHON:-python3}
TELEMETRY="$HOME/Library/Logs/Audiout/telemetry.jsonl"
RESULTS_ROOT="$HERE/results"
SETTLE_S=60          # Bluetooth clocks step for ~40 s after a connect
A_FIRST_S=1320       # Block A: 22 min, then the disconnect
A_OFF_S=10
A_REST_S=170         # Block A: from the reconnect to the end of the block (25 min in all)
B_PLAY_S=60
B_PAUSE_S=90
C_S=3600
JUMP_MS=5            # an offset change bigger than this between 3 s rows is a jump
OSA_TIMEOUT_S=30     # limit on the osascript call that quits Audiout Dev
BT_CONNECT_S=45      # per connect attempt: wait this long for blueutil --is-connected 1 (two attempts)
CA_WAIT_S=10         # then wait this long for the speaker to show as a Core Audio output
LOAD_EVERY_S=60      # load.csv sample interval
LOAD_WARN=4          # summary.md warns, and the watchdog alerts, above this 1-minute load average
WATCH_EVERY_S=60     # watchdog interval during a block
RMS_FLOOR_DB=-80     # mic level over the last 10 s must be above this (digital silence is -inf)
CLICKS_MIN=8         # 3 s periods with a click found in the last 30 s
CLOCK_WINDOW_S=90    # every selected Bluetooth speaker must log bt_clock_deviation within this
ALERTS_TO_ABORT=3    # consecutive alerts on one check that end a block early
PROBE_S=20           # pre-flight probe recording before Block A

# ---- Flags ------------------------------------------------------------------
MODE=night; DRY=0; SMOKE=0; WITH_AIRPLAY=0; MANUAL=1; ONLY_C=0
while (( $# )); do
  case $1 in
    --dry-run) DRY=1 ;;
    --smoke) SMOKE=1 ;;
    --manual-selection) MANUAL=1 ;;
    --relaunch) MANUAL=0 ;;
    --with-airplay) WITH_AIRPLAY=1 ;;
    --only-c) WITH_AIRPLAY=1; ONLY_C=1 ;;   # Blocks A and B already ran: skip straight to Block C
    --list-devices) MODE=list ;;
    --check) MODE=check ;;
    --move1) MOVE1_ID=${2:?--move1 needs an id}; shift ;;
    --move2) MOVE2_ID=${2:?--move2 needs an id}; shift ;;
    --airplay-id) AIRPLAY_ID=${2:?--airplay-id needs an id}; shift ;;
    --c-move) C_MOVE_ID=${2:?--c-move needs a Bluetooth id}; shift ;;
    *) print -u2 "unknown argument: $1"; exit 2 ;;
  esac
  shift
done
(( DRY && SMOKE )) && { print -u2 "--dry-run and --smoke cannot be combined"; exit 2 }
if (( DRY )); then
  SETTLE_S=0; A_FIRST_S=10; A_OFF_S=10; A_REST_S=10; B_PLAY_S=10; B_PAUSE_S=10; C_S=10; LOAD_EVERY_S=5; WATCH_EVERY_S=5; PROBE_S=10; WAIT_C_S=10
fi
if (( SMOKE )); then
  A_FIRST_S=90; A_OFF_S=10; A_REST_S=20; B_PLAY_S=20; B_PAUSE_S=30; C_S=120
fi

OUT=""
log() { print -r -- "[$(date +%H:%M:%S)] $*" | { [[ -n $OUT ]] && tee -a "$OUT/driver.log" || cat } }
die() { log "STOP: $*"; exit 1 }
note() { [[ -n $OUT ]] && print -r -- "$*" >> "$OUT/notes.txt"; log "$*" }
need() { command -v "$1" >/dev/null || die "missing tool: $1 ($2)" }
to() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@" }  # run with a time limit

# ---- Device ids -------------------------------------------------------------
# list: print every Bluetooth and AirPlay output seen here. check: exit 1 naming
# any id that neither the alignment store nor the telemetry log has seen.
devices() {  # mode ids...
  need "$PYTHON" "install Python 3"
  "$PYTHON" - "$1" "$TRIMS" "$TELEMETRY" "${@:2}" <<'EOF'
import sys, json, re, subprocess
mode, trims, tel, wanted = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
BT = re.compile(r"^[0-9A-F]{2}(-[0-9A-F]{2}){5}:output$"); AP = re.compile(r"^[0-9A-F]{2}(:[0-9A-F]{2}){5}$")
seen = {}
def add(i, src, ts=""):
    kind = "Bluetooth" if BT.match(i) else "AirPlay" if AP.match(i) else None
    if kind:
        d = seen.setdefault(i, {"kind": kind, "src": set(), "evts": set(), "last": ""})
        d["src"].add(src); d["last"] = max(d["last"], ts)
        return d
store = {}
try: store = json.load(open(trims))
except (OSError, ValueError): pass
for k in ("latencyMs", "trims"):
    for i in store.get(k, {}): add(i, "store")
names = set()
for p in (tel + ".1", tel):
    try: f = open(p, errors="replace")
    except OSError: continue
    for line in f:
        try: r = json.loads(line)
        except ValueError: continue
        for key in ("uid", "device"):
            v = r.get(key)
            d = add(v, "log", r.get("ts", "")) if isinstance(v, str) else None
            if d: d["evts"].add(r.get("evt", "?"))
        if r.get("evt") == "set_output_set":
            for key in ("added", "removed", "desiredOn"):
                names.update(n for n in str(r.get(key, "")).strip("[]").split(",") if n)

if mode == "check":
    bad = [i for i in wanted if i != "local-mac" and i not in seen]
    for i in bad:
        print(f"unknown id {i}: neither {trims} nor {tel} has ever seen it; run --list-devices on this Mac.")
    sys.exit(1 if bad else 0)

paired, blue_note = {}, ""
try:
    out = subprocess.run(["blueutil", "--paired", "--format", "json"], capture_output=True, text=True, timeout=20)
    for d in json.loads(out.stdout):
        i = d["address"].upper() + ":output"; paired[i] = d
        seen.setdefault(i, {"kind": "Bluetooth", "src": set(), "evts": set(), "last": ""})["src"].add("blueutil")
except FileNotFoundError: blue_note = "blueutil not installed, so no names or paired-only speakers"
except (ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
    blue_note = "blueutil could not read Bluetooth (give Terminal Bluetooth access in System Settings > Privacy & Security)"

print("Outputs Audiout Dev has seen on this Mac. The ids are exactly what the driver takes.\n")
for i in sorted(seen, key=lambda i: (seen[i]["kind"], i)):
    d = seen[i]; bits = []
    if d["kind"] == "Bluetooth":
        p = paired.get(i)
        if p: bits.append(f'name "{p.get("name", "")}", ' + ("connected" if p.get("connected") else "not connected"))
        if i in store.get("latencyMs", {}):
            bits.append(f'alignment stored (latency {store["latencyMs"][i]} ms, trim {store.get("trims", {}).get(i, 0)} ms)')
        else: bits.append("NO stored alignment: run the wizard on it")
    else:
        twin = i.replace(":", "-") + ":output"
        if twin in seen: bits.append(f"same address as Bluetooth {twin}, so the Wi-Fi side of that speaker")
        moves = [b for b in seen if seen[b]["kind"] == "Bluetooth"
                 and (not paired or "move" in paired.get(b, {}).get("name", "").lower())]
        if any(b[:8].replace("-", ":") == i[:8] for b in moves): bits.insert(0, "(a Sonos Move in Wi-Fi mode)")
    if "store" not in d["src"] and "log" not in d["src"]: bits.append("never seen by Audiout Dev, so the driver refuses it")
    if d["last"]: bits.append(f'last log line {d["last"]} ({", ".join(sorted(d["evts"])[:3])})')
    print(f'{d["kind"]:<10} {i:<25} {"; ".join(bits)}')
print(f'{"This Mac":<10} {"local-mac":<25} always available')
if names: print("\nSpeaker names in set_output_set lines (that line carries names only, no ids): " + ", ".join(sorted(names)))
if blue_note: print("\nNote: " + blue_note)
print('\nPaste into the top of unattended-night.sh, or pass --move1 / --move2 / --airplay-id:\n  MOVE1_ID="<Bluetooth id>"\n  MOVE2_ID="<Bluetooth id>"\n  AIRPLAY_ID="<AirPlay id>"')
EOF
}

if [[ $MODE == list ]]; then devices list; exit 0; fi

# ---- Tools ------------------------------------------------------------------
need osascript "part of macOS"
need afconvert "part of macOS"
need perl "part of macOS"
need "$PYTHON" "install Python 3"
"$PYTHON" -c 'import numpy' 2>/dev/null || die "numpy missing for $PYTHON: $PYTHON -m pip install numpy"
[[ -f $CLICK_WAV ]] || die "click track not found: $CLICK_WAV"
[[ -f $ANALYSER ]] || die "click-pair-spacing.py not found: $ANALYSER"
[[ -f $TELEMETRY ]] || die "no telemetry file: $TELEMETRY (launch Audiout Dev once)"
need afplay "part of macOS"
need ffmpeg "brew install ffmpeg"
if [[ ! -s $LONG_WAV ]]; then
  log "making $LONG_WAV (the click track $((LONG_LOOPS + 1)) times)"
  ffmpeg -nostdin -hide_banner -loglevel error -y -stream_loop $LONG_LOOPS -i "$CLICK_WAV" -c copy "$LONG_WAV" \
    || { rm -f "$LONG_WAV"; die "ffmpeg could not make $LONG_WAV"; }
fi
BLUE_PROBLEM=""
if ! command -v blueutil >/dev/null; then BLUE_PROBLEM="blueutil not installed"
elif ! to 15 blueutil --power >/dev/null 2>&1; then BLUE_PROBLEM="blueutil cannot reach Bluetooth (Terminal needs Bluetooth access in Privacy & Security)"; fi
HAVE_BLUEUTIL=$([[ -z $BLUE_PROBLEM ]] && print 1 || print 0)
(( DRY )) || [[ -z $BLUE_PROBLEM ]] || die "$BLUE_PROBLEM. A real run needs it: quitting Audiout Dev drops the Moves' links, and the driver must reconnect them before every relaunch."

# ---- Bluetooth links ---------------------------------------------------------
# Quitting Audiout Dev drops the A2DP links, and the launch-time restore
# (GroupController.ensureDefaultSelection, applied once) drops any id the device
# list does not hold yet. So before every launch the wanted Moves are connected
# and visible to Core Audio, and the unwanted ones are disconnected.
bt_addr() { local a=${1%:output}; print -n -- ${a//-/:} }       # blueutil form, colons
bt_connected() { [[ $(to 15 blueutil --is-connected "$1" 2>/dev/null) == 1 ]] }
bt_name() { to 15 blueutil --info "$1" --format json 2>/dev/null | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null }
ca_has_output() {  # name: true when Core Audio lists a Bluetooth output with that name
  system_profiler SPAudioDataType -json 2>/dev/null | "$PYTHON" -c '
import json, sys
name = sys.argv[1]
items = [i for g in json.load(sys.stdin).get("SPAudioDataType", []) for i in g.get("_items", [])]
sys.exit(0 if any(i.get("_name") == name and "bluetooth" in i.get("coreaudio_device_transport", "")
                  and i.get("coreaudio_device_output") for i in items) else 1)' "$1"
}
bt_connect_wait() {  # Bluetooth id; connect, wait for the link, then for Core Audio
  local a=$(bt_addr $1) try end name
  for try in 1 2; do
    bt_connected $a && break
    log "connecting $a (attempt $try)"; to $BT_CONNECT_S blueutil --connect $a >/dev/null 2>&1 || true
    end=$(( SECONDS + BT_CONNECT_S ))
    while (( SECONDS < end )) && ! bt_connected $a; do sleep 1; done
  done
  bt_connected $a || { log "$a did not connect after 2 attempts of $BT_CONNECT_S s"; return 1; }
  name=$(bt_name $a)
  end=$(( SECONDS + CA_WAIT_S ))
  while (( SECONDS < end )); do
    [[ -n $name ]] && ca_has_output "$name" && { log "$a connected and listed by Core Audio as \"$name\""; return 0; }
    sleep 1
  done
  log "$a connected, but Core Audio did not list \"$name\" as an output within $CA_WAIT_S s; launching anyway"
  return 0
}
bt_disconnect_wait() {  # Bluetooth id
  local a=$(bt_addr $1) end=$(( SECONDS + 15 ))
  bt_connected $a || return 0
  log "disconnecting $a"; to 15 blueutil --disconnect $a >/dev/null 2>&1 || true
  while (( SECONDS < end )) && bt_connected $a; do sleep 1; done
  bt_connected $a && { log "$a is still connected"; return 1; }
  return 0
}
bt_prepare() {  # wanted ids...; connect the wanted Moves, disconnect the other Moves
  local id
  for id in $MOVE1_ID $MOVE2_ID; do
    (( ${@[(Ie)$id]} )) || bt_disconnect_wait $id || return 1
  done
  for id in "$@"; do
    [[ $id == *:output ]] && { bt_connect_wait $id || return 1; }
  done
  return 0
}

KEY_PROBLEM=""
if [[ ! -d $APP ]]; then KEY_PROBLEM="Audiout Dev not found at $APP. Install it there (README step 2)."
elif ! grep -rqaF "$RECONNECT_KEY" "$APP/Contents/MacOS" "$APP/Contents/Frameworks" 2>/dev/null; then
  KEY_PROBLEM="Audiout Dev at $APP has no \"Reconnect last speakers when Audiout starts\" setting ($RECONNECT_KEY), so the driver cannot change the speaker selection unattended. Install a build from main after roadmap 050."
fi

# Ids per block; a real run refuses an empty or unknown id before anything plays.
typeset -a IDS_A IDS_B IDS_C
C_MOVE_ID=${C_MOVE_ID:-$MOVE1_ID}
TOGGLE_ID=$MOVE2_ID; [[ $C_MOVE_ID == $MOVE2_ID ]] && TOGGLE_ID=$MOVE1_ID   # the c-move's partner: disconnected in Block A
IDS_A=($MOVE1_ID $MOVE2_ID); IDS_B=($C_MOVE_ID $MAC_ID); IDS_C=($C_MOVE_ID $AIRPLAY_ID)
(( MANUAL )) && KEY_PROBLEM=""   # the reconnect setting only matters for --relaunch
if (( MANUAL && ! DRY )) && ! pgrep -f "$APP/Contents/MacOS/" >/dev/null; then
  KEY_PROBLEM+="Audiout Dev is not running: open Audiout Dev first (manual selection needs it running). "
fi
ids_problem=""
for pair in MOVE1_ID:$MOVE1_ID MOVE2_ID:$MOVE2_ID $( (( WITH_AIRPLAY )) && print AIRPLAY_ID:$AIRPLAY_ID ); do
  [[ -n ${pair#*:} ]] || ids_problem+="${pair%%:*} is empty (run --list-devices and set it). "
done
unknown=$(devices check $MOVE1_ID $MOVE2_ID $C_MOVE_ID $( (( WITH_AIRPLAY )) && print -- $AIRPLAY_ID )) || ids_problem+="$unknown "
[[ -z $C_MOVE_ID || $C_MOVE_ID == *:output ]] || ids_problem+="--c-move must be a Bluetooth id (ending :output): $C_MOVE_ID. "

if (( ! DRY )); then
  [[ -z $KEY_PROBLEM$ids_problem ]] || die "$ids_problem$KEY_PROBLEM"
fi
if [[ $MODE == check ]]; then
  bt_connect_wait $MOVE1_ID || die "blueutil could not connect $MOVE1_ID; a real run reconnects the Moves before every relaunch"
  log "check: blueutil connected $MOVE1_ID (left connected)"
  log "check passed: tools present, ids known, build has $RECONNECT_KEY; ${BLUE_PROBLEM:-blueutil works}"
  exit 0
fi

SUFFIX=""; (( DRY )) && SUFFIX=-dry-run; (( SMOKE )) && SUFFIX=-smoke
OUT="$RESULTS_ROOT/$(date +%Y-%m-%d_%H%M)$SUFFIX"
mkdir -p "$OUT"
log "results: $OUT; dry run: $DRY; smoke: $SMOKE"
log "watch it: tail -F '$OUT/status.log'"

# Once a minute for the whole run: the 1-minute load average and the busiest
# process, so a block disturbed by a test run or anything else shows in the summary.
print "timestamp,block,load1,top_process" > "$OUT/load.csv"
print -n -- - > "$OUT/.block"
(
  while true; do
    load1=$(uptime | sed -E 's/.*load averages?: ([0-9.]+).*/\1/') || true
    top=$(ps -Ao pcpu=,comm= -r | head -1 | sed -E 's/^ *[0-9.]+ +//') || true
    print -r -- "$(date +%Y-%m-%dT%H:%M:%S),$(<"$OUT/.block"),$load1,${${top:t}//,/ }" >> "$OUT/load.csv"
    sleep $LOAD_EVERY_S
  done
) &
LOAD_PID=$!
trap 'kill $LOAD_PID 2>/dev/null; [[ -n $PLAY_PID ]] && kill $PLAY_PID 2>/dev/null' EXIT
[[ -n $BLUE_PROBLEM ]] && note "$BLUE_PROBLEM: Block A's disconnect and the connection checks are skipped"
if (( DRY )); then
  [[ -n $KEY_PROBLEM ]] && note "a real run would stop here: $KEY_PROBLEM"
  if [[ -z $MOVE1_ID$MOVE2_ID ]]; then note "no ids set, so the id check was not exercised"
  elif [[ -n $ids_problem ]]; then note "a real run would stop here: $ids_problem"
  else log "id check passed for: $MOVE1_ID $MOVE2_ID $AIRPLAY_ID"; fi
fi

# ---- Helpers ----------------------------------------------------------------
tel_size() { stat -f %z "$TELEMETRY" }
now() { print -n -- $EPOCHREALTIME }

FAKE_AUDIO=0      # 1 once the mic turned out to be unusable (dry run only)

# afplay plays to the default output as it is when afplay STARTS, so a fresh
# afplay is started whenever the app may have changed that (after a launch, and
# when the audio check fails). Pause is a kill; resume starts again from 0 (the
# clicks are periodic, so the offset is unchanged).
PLAY_PID=""
play_start() {
  play_stop
  afplay "$LONG_WAV" 2>>"$OUT/driver.log" &
  PLAY_PID=$!
  sleep 0.5; kill -0 $PLAY_PID 2>/dev/null || { log "afplay exited at once"; PLAY_PID=""; return 1; }
}
play_stop() {
  [[ -n $PLAY_PID ]] || return 0
  kill $PLAY_PID 2>/dev/null; wait $PLAY_PID 2>/dev/null; PLAY_PID=""
  return 0
}
play_pause() { play_stop }
play_resume() { play_start }

# Is audio reaching the app? The newest stream_health lines (every 5 s while it
# streams) written after byte $1 and at most $2 s old. Prints "peak=<dB> silent_s=<n>"
# or what is missing; exit 0 when the peak is above AUDIO_PEAK_DB or silent_s is 0.
audio_flow() {  # from_byte max_age_s
  "$PYTHON" - "$TELEMETRY" "$1" "$2" "$AUDIO_PEAK_DB" <<'EOF'
import sys, os, json, datetime
tel, start, max_age, floor = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
f = open(tel, "rb"); f.seek(max(start, os.path.getsize(tel) - 400_000))
now = datetime.datetime.now(datetime.timezone.utc); fresh = []
for l in f.read().decode("utf-8", "replace").splitlines():
    if '"stream_health"' not in l: continue
    try: r = json.loads(l); ts = datetime.datetime.fromisoformat(r["ts"].replace("Z", "+00:00"))
    except (ValueError, KeyError): continue
    if (now - ts).total_seconds() <= max_age: fresh.append(r)
if not fresh: print(f"peak=none (no stream_health line in the last {max_age:g} s)"); sys.exit(1)
peak = max(float(r.get("peak_dbfs", -120)) for r in fresh); silent = min(int(r.get("silent_s", 999)) for r in fresh)
print(f"peak={peak:.1f} silent_s={silent}")
sys.exit(0 if peak > floor or silent == 0 else 1)
EOF
}

# Start the long file from 0 and prove within AUDIO_WAIT_S that the app gets audio;
# rewind and play once more if not, then fail with what stream_health said.
play_verified() {
  if (( DRY )); then play_start; log "dry run: audio-flow check skipped (Audiout Dev not relaunched)"; return 0; fi
  local try from got end
  for try in 1 2; do
    from=$(tel_size); play_start || log "play command failed (try $try)"
    end=$(( SECONDS + AUDIO_WAIT_S ))
    while (( SECONDS < end )); do
      got=$(audio_flow $from 6) && { log "audio flowing: $got (try $try)"; return 0; }
      sleep 2
    done
    log "audio not flowing after play (try $try): $got"
  done
  note "audio did not reach Audiout Dev after two play commands: $got"
  return 1
}

find_mic() {
  [[ -n $MIC_INDEX ]] && return 0
  MIC_INDEX=$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
    | sed -n '/audio devices/,$p' | grep -E "$MIC_PATTERN" | head -1 | sed -E 's/.*\[([0-9]+)\].*/\1/') || true
  [[ -n $MIC_INDEX ]] || die "no built-in mic matching '$MIC_PATTERN' in ffmpeg's device list; set MIC_INDEX"
  log "mic index $MIC_INDEX"
}

REC_PID=""
rec_start() {  # $1 = raw file without extension
  (( FAKE_AUDIO )) && return 0
  ffmpeg -nostdin -hide_banner -loglevel error -f avfoundation -i ":$MIC_INDEX" -ac 1 -y "$1.wav" 2>>"$OUT/ffmpeg.log" &
  REC_PID=$!
}
rec_stop() {  # $1 = raw file without extension; leaves $1.wav
  (( FAKE_AUDIO )) && return 0
  kill -TERM $REC_PID 2>/dev/null || true; wait $REC_PID 2>/dev/null || true
}
raw_file() { print -n -- "$1.wav" }

# Peak of a 16-bit recording; 0 when the mic gave digital silence (no permission).
peak() {
  "$PYTHON" - "$1" <<'EOF'
import sys, wave, numpy as np
w = wave.open(sys.argv[1]); x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
print(int(np.abs(x.astype(np.int32)).max()) if x.size else 0)
EOF
}

# Two clicks every 3 s, the second 42 ms after the first and quieter, for
# checking the analysis path when the mic cannot be used.
synth() {  # $1 = output wav, $2 = seconds
  "$PYTHON" - "$1" "$2" <<'EOF'
import sys, wave, numpy as np
sr = 48000; n = int(float(sys.argv[2]) * sr); x = np.random.default_rng(1).normal(0, 30, n)
click = (np.hanning(96) * np.sin(np.arange(96) * 0.9)) * 20000
for start in range(int(0.5 * sr), n - sr, 3 * sr):
    x[start:start + 96] += click
    s2 = start + int(0.042 * sr); x[s2:s2 + 96] += click * 0.5
w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
w.writeframes(np.clip(x, -32767, 32767).astype(np.int16).tobytes()); w.close()
EOF
}

# Before the night starts: does afplay play and can this process hear the mic?
preflight() {
  find_mic
  local why=""
  play_start || why="afplay could not play $LONG_WAV"
  if [[ -z $why ]]; then
    rec_start "$OUT/preflight" 2>>"$OUT/driver.log" || why="recording could not start"
    sleep 4
    [[ -z $why ]] && { rec_stop "$OUT/preflight" 2>>"$OUT/driver.log" || why="recording could not stop or save"; }
    play_stop 2>>"$OUT/driver.log" || true
    if [[ -z $why ]]; then
      local raw=$(raw_file "$OUT/preflight")
      if [[ ! -s $raw ]]; then why="the recorder wrote no file (Microphone permission)"
      else
        afconvert -f WAVE -d LEI16 "$raw" "$OUT/preflight-16.wav"
        (( $(peak "$OUT/preflight-16.wav") > 0 )) || why="the recording is digital silence (Microphone permission not granted to this process)"
      fi
    fi
  fi
  [[ -z $why ]] && { log "preflight: afplay and mic both work"; return 0; }
  (( DRY )) || die "preflight failed: $why. Run the dry run once while present to approve the prompts."
  FAKE_AUDIO=1
  note "DRY RUN FALLBACK: $why. Playback and recording are replaced by a synthetic recording (two clicks per 3 s, the second 42 ms later)."
}


# routing.json as RoutingStore.save writes it: schema 1, Main Out = Selected Speakers.
write_routing() {  # file ids...
  "$PYTHON" - "$@" <<'EOF'
import sys, json, os
state = {"mainOutKind": "selected", "selectedDeviceIDs": sorted(set(sys.argv[2:]))}
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
json.dump({"schemaVersion": 1, "state": state}, open(sys.argv[1], "w"), indent=2, sort_keys=True)
EOF
}

# Prints nothing when the routing file holds exactly these ids, else what it holds.
selection_mismatch() {  # file ids...
  "$PYTHON" - "$@" <<'EOF'
import sys, json
try: got = set(json.load(open(sys.argv[1]))["state"]["selectedDeviceIDs"])
except (OSError, ValueError, KeyError): got = None
print("" if got == set(sys.argv[2:]) else "unreadable" if got is None else " ".join(sorted(got)))
EOF
}

# The live selection after a relaunch, from telemetry written since byte offset
# $1. set_output_set carries speaker NAMES (NativeBackend.telemetryDeviceList),
# so it gives the count of non-local speakers handed to the backend; the ids come
# from bt_sink_rebuild / bt_sink_anchored / bt_clock_deviation (uid) for
# Bluetooth and connect_requested (device) for AirPlay. Prints nothing when they
# match exactly, else what is wrong. This Mac never reaches the backend; the
# routing.json check covers it.
live_mismatch() {  # from_byte ids...
  "$PYTHON" - "$TELEMETRY" "$@" <<'EOF'
import sys, json, re
tel, start, want = sys.argv[1], int(sys.argv[2]), set(sys.argv[3:])
BT = re.compile(r"^[0-9A-F]{2}(-[0-9A-F]{2}){5}:output$"); AP = re.compile(r"^[0-9A-F]{2}(:[0-9A-F]{2}){5}$")
f = open(tel, "rb"); f.seek(start)
names, seen_bt, seen_ap, got_set = set(), set(), set(), False
for l in f.read().decode("utf-8", "replace").splitlines():
    try: r = json.loads(l)
    except ValueError: continue
    e = r.get("evt", "")
    lst = lambda k: {n for n in str(r.get(k, "")).strip("[]").split(",") if n}
    if e == "set_output_set": got_set = True; names = (names | lst("added")) - lst("removed")
    elif e in ("bt_sink_rebuild", "bt_sink_anchored", "bt_clock_deviation") and BT.match(r.get("uid", "")): seen_bt.add(r["uid"])
    elif e == "connect_requested" and AP.match(r.get("device", "")): seen_ap.add(r["device"])
want_bt = {i for i in want if BT.match(i)}; want_ap = {i for i in want if AP.match(i)}
bad = []
if not got_set: bad.append("no set_output_set line")
elif len(names) != len(want_bt | want_ap): bad.append(f"set_output_set selects {len(names)} speakers [{', '.join(sorted(names))}], wanted {len(want_bt | want_ap)}")
if want_bt - seen_bt: bad.append("no sink line for " + " ".join(sorted(want_bt - seen_bt)))
if seen_bt - want_bt: bad.append("unwanted Bluetooth sink " + " ".join(sorted(seen_bt - want_bt)))
if want_ap - seen_ap: bad.append("no connect_requested for " + " ".join(sorted(want_ap - seen_ap)))
if seen_ap - want_ap: bad.append("unwanted AirPlay connect " + " ".join(sorted(seen_ap - want_ap)))
print("; ".join(bad) if bad else "")
EOF
}

# ---- Manual selection ----------------------------------------------------------
# The app names a Move like "Move 2 (SONOS BF4A)": the last two bytes of its
# address. Names come from this Mac's set_output_set lines matched on that,
# else from blueutil, else the id. This Mac never reaches set_output_set.
manual_py() {  # mode tel from_byte id=name...
  "$PYTHON" - "$@" <<'EOF'
import sys, json, re, os
mode, tel, start, pairs = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4:]
BT = re.compile(r"^[0-9A-F]{2}(-[0-9A-F]{2}){5}:output$"); AP = re.compile(r"^[0-9A-F]{2}(:[0-9A-F]{2}){5}$")
def lines(path):
    try: return open(path, "rb").read().decode("utf-8", "replace").splitlines()
    except OSError: return []
rows = []
for l in lines(tel + ".1") + lines(tel):
    try: rows.append(json.loads(l))
    except ValueError: pass
lst = lambda r, k: [n for n in str(r.get(k, "")).strip("[]").split(",") if n]
known = {n for r in rows if r.get("evt") == "set_output_set" for k in ("added", "removed", "desiredOn") for n in lst(r, k)}
def name(i, fallback):
    if BT.match(i):
        tail = i[12:17].replace("-", "")
        hit = sorted(n for n in known if tail in n.upper())
        if hit: return hit[0]
    return fallback or i
ids = [p.split("=", 1)[0] for p in pairs]; given = {p.split("=", 1)[0]: p.split("=", 1)[1] for p in pairs}
names = {i: name(i, given[i]) for i in ids}
if mode == "names":
    for i in ids: print(names[i])
    sys.exit(0)
# check: the app's live selection against the wanted ids, from telemetry
sid = rows[-1].get("sid") if rows else None
running = set()
for r in rows:
    if r.get("sid") == sid and r.get("evt") == "set_output_set":
        running = (running | set(lst(r, "added"))) - set(lst(r, "removed"))
f = open(tel, "rb"); f.seek(start); recent = []
for l in f.read().decode("utf-8", "replace").splitlines():
    try: recent.append(json.loads(l))
    except ValueError: pass
bt = [i for i in ids if BT.match(i)]; ap = [i for i in ids if AP.match(i)]
want_bt_names = {names[i] for i in bt}
bad = []
if len(running) != len(bt) + len(ap): bad.append(f"the app has {len(running)} speakers selected [{', '.join(sorted(running))}], wanted {len(bt) + len(ap)}")
missing = want_bt_names - running
if missing: bad.append("not selected: " + ", ".join(sorted(missing)))
extra = running - want_bt_names
if len(extra) > len(ap): bad.append("selected but not wanted: " + ", ".join(sorted(extra)))
sinks = {r.get("uid") for r in recent if r.get("evt") in ("bt_sink_rebuild", "bt_sink_anchored", "bt_clock_deviation")}
for i in bt:
    if i not in sinks: bad.append(f"no Bluetooth output line for {names[i]} ({i}) since the WAITING line")
conns = {r.get("device") for r in recent if r.get("evt") == "connect_requested"}
for i in ap:
    if i not in conns: bad.append(f"no connect_requested for the AirPlay id {i} since the WAITING line")
print("; ".join(bad))
EOF
}
typeset -a PAIRS   # id=fallback-name for the current block, shared by the WAITING line and the check
human_names() {  # ids...; one name per line, as the WAITING line shows them
  PAIRS=(); local id
  for id in "$@"; do
    case $id in
      $MAC_ID) PAIRS+=("$id=$MAC_ROW") ;;
      *:output) PAIRS+=("$id=$( (( HAVE_BLUEUTIL )) && bt_name $(bt_addr $id))") ;;
      *) PAIRS+=("$id=the AirPlay row of the Move in Wi-Fi mode (id $id)") ;;
    esac
  done
  manual_py names "$TELEMETRY" 0 "${PAIRS[@]}"
}
wait_go() {  # block letter; true on Enter or the go file, false after WAIT_C_S
  local go="$GO_DIR/go-block-${(L)1}" end=$(( SECONDS + WAIT_C_S ))
  (( DRY )) && { sleep 2; log "dry run: confirming block $1 automatically"; return 0; }
  while (( SECONDS < end )); do
    [[ -f $go ]] && { rm -f "$go"; log "block $1 confirmed by $go"; return 0; }
    if [[ -t 0 ]]; then read -t 2 -r _ && { log "block $1 confirmed by Enter"; return 0; }
    else sleep 2; fi
  done
  return 1
}
select_manual() {  # block letter, then ids
  local blk=$1; shift
  human_names "$@" > "$OUT/.names"; local -a nm=("${(@f)$(<"$OUT/.names")}")
  local list="${(j:" and ":)nm}" pre="" try from end bad flow
  [[ $blk == C ]] && pre="switch the Move that is not on Bluetooth to Wi-Fi mode and wait until it shows as an AirPlay speaker; then "
  [[ $blk == B && -n $TOGGLE_ID ]] && pre="quit and reopen Audiout Dev first (a Move whose link was dropped stays silent until the app restarts); then "
  for try in {1..$SELECT_TRIES}; do
    play_stop; rm -f "$GO_DIR/go-block-${(L)blk}"; from=$(tel_size)
    status "WAITING $blk $(date +%H:%M:%S) ${pre}in Audiout Dev select exactly: \"$list\" and nothing else, then press Enter (or: touch $GO_DIR/go-block-${(L)blk})"
    wait_go $blk || { status "ABORT $blk $(date +%H:%M:%S) nobody confirmed the selection within $WAIT_C_S s"; return 1; }
    play_start || log "afplay did not start"
    (( DRY )) && { log "dry run: selection and audio checks skipped (no app running)"; return 0; }
    end=$(( SECONDS + SELECT_CHECK_S ))
    while (( SECONDS < end )); do
      sleep 5
      bad=$(manual_py check "$TELEMETRY" $from "${PAIRS[@]}")
      flow=$(audio_flow $from 15) || bad+="${bad:+; }no audio reaching the app ($flow)"
      [[ -z $bad ]] && { log "selection check passed for block $blk [$list]; audio $flow"; return 0; }
    done
    status "ALERT $blk $(date +%H:%M:%S) selection $bad"
  done
  status "ABORT $blk $(date +%H:%M:%S) selection still wrong after $SELECT_TRIES tries"
  return 1
}
choose_speakers() {  # block letter, then ids
  local blk=$1; shift
  if (( MANUAL )); then select_manual $blk "$@"; else select_speakers "$@"; fi
}

RECONNECT_WAS=""
select_speakers() {  # ids...
  if (( DRY )); then  # write and check a copy; the app's own file is left alone
    write_routing "$OUT/routing-dry-run.json" "$@"
    local got=$(selection_mismatch "$OUT/routing-dry-run.json" "$@")
    [[ -z $got ]] && log "dry run: routing file check passed for [$*] (wrote $OUT/routing-dry-run.json; no relaunch, so no live check)" \
                  || { log "dry run: routing file check FAILED: holds [$got], wanted [$*]"; return 1; }
    return 0
  fi
  if [[ -z $RECONNECT_WAS ]]; then
    RECONNECT_WAS=$(defaults read $BUNDLE_ID $RECONNECT_KEY 2>/dev/null || print -n off)
    defaults write $BUNDLE_ID $RECONNECT_KEY -bool true
    note "turned on \"Reconnect last speakers when Audiout starts\" ($RECONNECT_KEY, was $RECONNECT_WAS) so launch restores routing.json; set back at the end"
  fi
  local try from t0 got live
  for try in {1..$RELAUNCH_TRIES}; do
    to 20 osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    local i; for i in {1..20}; do pgrep -f "$APP/Contents/MacOS/" >/dev/null || break; sleep 1; done
    pgrep -f "$APP/Contents/MacOS/" >/dev/null && { log "Audiout Dev did not quit, sending TERM"; pkill -f "$APP/Contents/MacOS/"; sleep 3; }
    osascript -e "set volume output volume $MAC_VOLUME"
    write_routing "$ROUTING" "$@"
    bt_prepare "$@" || { log "try $try: the Bluetooth links could not be set up"; continue; }
    from=$(tel_size); t0=$SECONDS
    open "$APP"
    # afplay must start after the app has taken the default output (its aggregate)
    local w; for w in {1..30}; do tail -c +$((from + 1)) "$TELEMETRY" | grep -q '"evt":"default_output_change"' && break; sleep 1; done
    (( w < 30 )) || log "try $try: no default_output_change line within 30 s of launch; starting playback anyway"
    play_start || log "playback did not start"   # sinks only build with audio flowing
    sleep $(( LIVE_CHECK_S > SECONDS - t0 ? LIVE_CHECK_S - (SECONDS - t0) : 0 ))
    got=$(selection_mismatch "$ROUTING" "$@")
    live=$(live_mismatch $from "$@")
    local flow; flow=$(audio_flow $from 15) || live+="${live:+; }no audio reaching the app ($flow)"
    if [[ -z $got && -z $live ]]; then
      log "selection check passed for [$*]: routing.json and telemetry agree (try $try)"
      local left=$(( SETTLE_S - (SECONDS - t0) )); (( left > 0 )) && sleep $left
      return 0
    fi
    [[ -n $got ]] && log "try $try: routing.json holds [$got], wanted [$*]"
    [[ -n $live ]] && log "try $try: live selection differs: $live"
  done
  return 1
}

# ---- Watchdog ---------------------------------------------------------------
# One python pass over the growing recording, the telemetry tail and the load.
# Prints the status fields on line 1, then one "<check> <value>" line per failure.
watch_probe() {  # raw_wav prev_bytes click_window_s paused ids...
  "$PYTHON" - "$1" "$2" "$3" "$4" "$TELEMETRY" "$ANALYSER" "$RMS_FLOOR_DB" "$CLICKS_MIN" \
    "$CLOCK_WINDOW_S" "$LOAD_WARN" "$DRY" "${@:5}" <<'EOF'
import sys, os, re, json, math, struct, wave, tempfile, subprocess, datetime
raw, prev, win, paused, tel, analyser = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4] == "1", sys.argv[5], sys.argv[6]
floor_db, clicks_min, clock_win, load_warn, dry = float(sys.argv[7]), int(sys.argv[8]), float(sys.argv[9]), float(sys.argv[10]), sys.argv[11] == "1"
ids = sys.argv[12:]
f, fails = [], []
if raw and os.path.exists(raw):
    size = os.path.getsize(raw); f.append(f"rec={size}")
    if size <= prev: fails.append(f"rec {size}")
    with open(raw, "rb") as fh: head = fh.read(4096)
    i = head.find(b"fmt "); ch, rate = struct.unpack("<HI", head[i + 10:i + 16]); bits = struct.unpack("<H", head[i + 22:i + 24])[0]
    data = head.find(b"data") + 8; frame = ch * bits // 8
    def tail(sec):
        n = int(sec * rate) * frame; start = max(data, size - n); start -= (start - data) % frame
        with open(raw, "rb") as fh: fh.seek(start); return fh.read(size - start)
    import numpy as np
    x = np.frombuffer(tail(10), dtype=np.int16).astype(np.float64)
    rms = 20 * math.log10(math.sqrt((x ** 2).mean()) / 32768) if x.size and x.any() else float("-inf")
    f.append(f"rms={rms:.1f}")
    if paused: f.append("clicks=paused")
    else:
        if rms <= floor_db: fails.append(f"rms {rms:.1f}")
        with tempfile.NamedTemporaryFile(suffix=".wav") as t:
            w = wave.open(t.name, "wb"); w.setnchannels(ch); w.setsampwidth(bits // 8); w.setframerate(rate); w.writeframes(tail(win)); w.close()
            out = subprocess.run([sys.executable, analyser, t.name], capture_output=True, text=True).stdout
        n = sum(1 for l in out.splitlines() if l.strip() and not l.startswith("#"))
        have = min(win, (size - data) / (rate * frame))  # less than the window early in a block
        need = int(clicks_min * have / 30); f.append(f"clicks={n}")
        if n < need: fails.append(f"clicks {n}<{need}")
elif raw:
    f.append("rec=missing"); fails.append("rec missing")
else: f.append("rec=n/a rms=n/a clicks=n/a")
bt = [i for i in ids if re.match(r"^[0-9A-F]{2}(-[0-9A-F]{2}){5}:output$", i)]
if dry: f.append("clock_lines=skipped(dry-run)")
else:
    now = datetime.datetime.now(datetime.timezone.utc); counts = {i: 0 for i in bt}
    with open(tel, "rb") as fh:
        fh.seek(max(0, os.path.getsize(tel) - 400_000)); lines = fh.read().decode("utf-8", "replace").splitlines()
    for l in lines:
        if '"bt_clock_deviation"' not in l: continue
        try: r = json.loads(l); ts = datetime.datetime.fromisoformat(r["ts"].replace("Z", "+00:00"))
        except (ValueError, KeyError): continue
        if r.get("uid") in counts and (now - ts).total_seconds() <= clock_win: counts[r["uid"]] += 1
    f.append("clock_lines=" + (",".join(f"{k}:{v}" for k, v in counts.items()) or "none-needed"))
    fails += [f"clock {k}:0" for k, v in counts.items() if v == 0]
load = os.getloadavg()[0]; f.append(f"load={load:.2f}")
if load >= load_warn:
    top = subprocess.run(["ps", "-Ao", "pcpu=,comm=", "-r"], capture_output=True, text=True).stdout.splitlines()
    fails.append(f"load {load:.2f} (busiest: {os.path.basename(top[0].split(None, 1)[1]) if top else '?'})")
print(" ".join(f)); print("\n".join(fails))
EOF
}

status() { print -r -- "$*" | tee -a "$OUT/status.log" }
typeset -A ALERT_RUN       # consecutive alerts per check in the current block
B_ABORT=0; B_PAUSED=0; B_REC_PREV=0; B_NEXT=0
CLOCK_EXEMPT=""   # Block A after the toggle: this id's clock check no longer counts toward ABORT
live_raw() {  # the growing recording the watchdog can read, or empty when there is none
  (( FAKE_AUDIO )) && return 0
  print -n -- "$OUT/block$B_NAME-raw.wav"
}
watch_check() {
  local out=$(watch_probe "$(live_raw)" $B_REC_PREV 30 $B_PAUSED ${=B_IDS}) t=$(date +%H:%M:%S)
  local -a lines=("${(@f)out}"); local fields=$lines[1] l c
  [[ $fields == rec=<->* ]] && B_REC_PREV=${${fields#rec=}%% *}
  local -a fails=(${(@)lines[2,-1]:#})
  if (( ! DRY && ! B_PAUSED )); then  # the source itself: lost audio shows here within one tick
    local flow; flow=$(audio_flow 0 15) || { fails+=("audio $flow"); log "no audio reaching the app ($flow); starting a fresh afplay"; play_start || true; }
    fields+=" audio=${${flow#peak=}%% *}"
  fi
  local -A failed
  if (( ! $#fails )); then status "OK $B_NAME $t $fields"; ALERT_RUN=(); return 0; fi
  for l in $fails; do
    c=${l%% *}
    if [[ -n $CLOCK_EXEMPT && $l == "clock $CLOCK_EXEMPT:0" ]]; then  # its failure is the measurement
      status "ALERT $B_NAME $t $c ${l#* } (the toggled Move; not counted toward ABORT)"; continue
    fi
    failed[$c]=1; ALERT_RUN[$c]=$(( ${ALERT_RUN[$c]:-0} + 1 ))
    status "ALERT $B_NAME $t $c ${l#* }"
    if (( ALERT_RUN[$c] >= ALERTS_TO_ABORT )); then
      status "ABORT $B_NAME $t $c ${l#* }"; B_ABORT=1; mark "abort_$c"; note "block $B_NAME ended early: $ALERTS_TO_ABORT alerts in a row on $c (${l#* })"
    fi
  done
  for c in ${(k)ALERT_RUN}; do (( ${+failed[$c]} )) || unset "ALERT_RUN[$c]"; done
}
watch_sleep() {  # seconds; sleeps, checking every WATCH_EVERY_S; returns at once after an abort
  local end=$(( SECONDS + $1 )) next
  while (( ! B_ABORT && SECONDS < end )); do
    if (( ! B_PAUSED )) && [[ -n $PLAY_PID ]] && ! kill -0 $PLAY_PID 2>/dev/null; then
      log "afplay ended; starting it again"; play_start || true   # a block longer than the file
    fi
    (( SECONDS >= B_NEXT )) && { watch_check; B_NEXT=$(( SECONDS + WATCH_EVERY_S )); }
    next=$(( B_NEXT < end ? B_NEXT : end )); next=$(( next < SECONDS + 5 ? next : SECONDS + 5 ))
    (( next > SECONDS )) && sleep $(( next - SECONDS ))
  done
  return 0
}

# Before Block A: the same checks once on a short probe recording; a real run
# refuses to start on any alert and says what to fix.
probe_check() {  # ids...
  local raw="$OUT/probe-raw" t=$(date +%H:%M:%S)
  play_start; rec_start "$raw"; sleep $PROBE_S
  local p=""; (( FAKE_AUDIO )) || p="$raw.wav"
  local out=$(watch_probe "$p" 0 $PROBE_S 0 "$@")
  rec_stop "$raw" || true; play_stop || true
  local -a lines=("${(@f)out}"); local -a fails=(${(@)lines[2,-1]:#}); local l fix=""
  if (( ! DRY )); then local flow; flow=$(audio_flow 0 15) || fails+=("audio $flow"); lines[1]+=" audio=${${flow#peak=}%% *}"; fi
  log "pre-flight probe: $lines[1]"
  if (( ! $#fails )); then status "OK PREFLIGHT $t $lines[1]"; return 0; fi
  for l in $fails; do
    status "ALERT PREFLIGHT $t ${l%% *} ${l#* }"
    case ${l%% *} in
      rec) fix+="The recording did not grow: check ffmpeg.log and Terminal's Microphone access. " ;;
      rms) fix+="The mic hears nothing (${l#* } dBFS): check Terminal's Microphone access and the input level in Sound settings. " ;;
      clicks) fix+="Too few clicks heard (${l#* }): check the speakers are on, selected in Audiout Dev, loud enough and 1 to 2 m away. " ;;
      clock) fix+="No bt_clock_deviation line from ${${l#* }%:0} in $CLOCK_WINDOW_S s: that Move is not playing through Audiout Dev; check it is connected and selected. " ;;
      audio) fix+="No audio is reaching Audiout Dev (${l#* }): check afplay is running and Audiout Dev holds the default output (its aggregate). " ;;
      load) fix+="The Mac is busy (load ${l#* }): stop that work, including test runs routed to this Mac, and start again. " ;;
    esac
  done
  (( DRY )) && { note "a real run would stop here: $fix"; return 0; }
  die "pre-flight probe failed. $fix"
}

# Block bookkeeping: blocks.tsv feeds the summary writer.
print -r -- $'block\tstatus\tbytes_from\tbytes_to\trec_start\tevents\tids' > "$OUT/blocks.tsv"
B_NAME=""; B_FROM=0; B_T0=0; B_EVENTS=""; B_IDS=""
block_begin() {  # $1 = A/B/C, then the selected ids
  B_NAME=$1; B_IDS=${(j: :)@[2,-1]}; B_FROM=$(tel_size); B_EVENTS=""; print -n -- $1 > "$OUT/.block"
  B_ABORT=0; B_PAUSED=0; B_REC_PREV=0; ALERT_RUN=(); CLOCK_EXEMPT=""; B_NEXT=$(( SECONDS + WATCH_EVERY_S ))
  status "BLOCK-START $1 $(date +%H:%M:%S)"
  rec_start "$OUT/block$1-raw"; B_T0=$(now)
  log "block $1: recording, telemetry offset $B_FROM"
  case $1 in  # this Mac is also the remote test Mac; the owner changes its permit count by these lines
    A) log "Block A started at $(date +%H:%M); set remoteSlots to 0 on the dev Mac now (git config audiout.remoteSlots 0)" ;;
    C) log "Block C started at $(date +%H:%M); raise remoteSlots to 1 on the dev Mac now only if tests must keep flowing" ;;
  esac
}
mark() { B_EVENTS+="$1@$(( $(now) - B_T0 ));"; log "block $B_NAME: $1" }
block_end() {
  rec_stop "$OUT/block$B_NAME-raw" || log "block $B_NAME: recording did not stop cleanly"
  play_stop || true
  local bytes_to=$(tel_size) dur=$(( $(now) - B_T0 ))
  if (( FAKE_AUDIO )); then synth "$OUT/block$B_NAME.wav" $dur
  else afconvert -f WAVE -d LEI16 "$(raw_file "$OUT/block$B_NAME-raw")" "$OUT/block$B_NAME.wav" || log "block $B_NAME: conversion failed"; fi
  "$PYTHON" "$ANALYSER" "$OUT/block$B_NAME.wav" > "$OUT/block$B_NAME.txt" || log "block $B_NAME: analysis failed"
  print -r -- "$B_NAME"$'\tok\t'"$B_FROM"$'\t'"$bytes_to"$'\t'"$B_T0"$'\t'"$B_EVENTS"$'\t'"$B_IDS" >> "$OUT/blocks.tsv"
  print -n -- - > "$OUT/.block"
  status "BLOCK-END $B_NAME $(date +%H:%M:%S)"
  log "block $B_NAME: done, telemetry offset $bytes_to"
}
block_skip() { print -r -- "$1"$'\tskipped: '"$2"$'\t0\t0\t0\t\t' >> "$OUT/blocks.tsv"; note "block $1 skipped: $2" }

# ---- The night --------------------------------------------------------------
preflight

if (( ! ONLY_C )); then
# Block A: both Moves; the c-move's partner is disconnected for A_OFF_S near the
# end (after the 2026-10-03 smoke run's reconnect it stayed silent all night).
if ! choose_speakers A $IDS_A; then block_skip A "both Moves could not be selected (see driver.log and status.log)"
elif probe_check $IDS_A && ! play_verified; then block_skip A "no audio reached the app after two play commands (see notes.txt)"
else
  block_begin A $IDS_A
  watch_sleep $A_FIRST_S
  if (( B_ABORT )); then :
  elif (( DRY )); then mark toggle_skipped_dry_run; watch_sleep $A_OFF_S; watch_sleep $A_REST_S
  elif (( HAVE_BLUEUTIL )); then
    mark disconnect; CLOCK_EXEMPT=$TOGGLE_ID; bt_disconnect_wait $TOGGLE_ID || log "disconnect failed"
    watch_sleep $A_OFF_S
    mark reconnect; local_from=$(tel_size); rc_t=$SECONDS; bt_connect_wait $TOGGLE_ID || note "block A: $TOGGLE_ID did not reconnect"
    if (( ! DRY )); then
      sink_seen=0
      for w in {1..$((RECONNECT_SINK_S / 5))}; do
        tail -c +$((local_from + 1)) "$TELEMETRY" | grep '"bt_sink_\(rebuild\|anchored\)"\|"bt_clock_deviation"' | grep -q "\"uid\":\"$TOGGLE_ID\"" && { sink_seen=1; break; }
        watch_sleep 5
      done
      (( sink_seen )) && log "block A: the reconnected Move is streaming again" \
        || status "ALERT A $(date +%H:%M:%S) reconnect no Bluetooth output line for $TOGGLE_ID within $RECONNECT_SINK_S s of the reconnect"
    fi
    watch_sleep $(( A_REST_S > SECONDS - rc_t ? A_REST_S - (SECONDS - rc_t) : 0 ))  # the check above counts toward the rest
  else mark toggle_skipped_no_blueutil; watch_sleep $A_OFF_S; watch_sleep $A_REST_S; fi
  block_end
fi

# Block B: the c-move plus This Mac (its partner was disconnected in Block A).
if ! choose_speakers B $IDS_B; then block_skip B "the Move and This Mac could not be selected (see driver.log and status.log)"
elif ! play_verified; then block_skip B "no audio reached the app after two play commands (see notes.txt)"
else
  block_begin B $IDS_B
  watch_sleep $B_PLAY_S
  if (( ! B_ABORT )); then
    mark pause; play_pause || log "pause failed"; B_PAUSED=1  # the mic and click checks expect silence now
    watch_sleep $B_PAUSE_S
    mark resume; play_resume || log "resume failed"; B_PAUSED=0
    watch_sleep $B_PLAY_S
  fi
  block_end
fi
fi  # ONLY_C

# Block C: one Move on Bluetooth plus the other Move in Wi-Fi mode. Someone has
# to press the Move's button, so wait for Enter or the go file.
wait_for_wifi_switch() {
  if (( ! DRY )); then
    to 20 osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  fi
  rm -f "$GO_DIR/go-block-c"
  status "WAITING C $(date +%H:%M:%S) switch the other Move to Wi-Fi mode, wait for it to appear as an AirPlay speaker, then confirm (Enter here, or: touch $GO_DIR/go-block-c)"
  wait_go C && return 0
  status "ABORT C timeout waiting for the AirPlay switch"
  return 1
}
if (( WITH_AIRPLAY )); then
  if (( ! MANUAL )) && ! wait_for_wifi_switch; then block_skip C "nobody confirmed the switch to Wi-Fi mode within $WAIT_C_S s"
  elif ! choose_speakers C $IDS_C; then block_skip C "the Bluetooth Move or the Move in Wi-Fi mode could not be selected (see driver.log)"
  elif ! play_verified; then block_skip C "no audio reached the app after two play commands (see notes.txt)"
  else
    block_begin C $IDS_C
    watch_sleep $C_S
    block_end
  fi
fi
(( ! DRY && ! WITH_AIRPLAY )) && { bt_connect_wait $TOGGLE_ID || true; }
if [[ $RECONNECT_WAS == off || $RECONNECT_WAS == 0 ]]; then
  defaults write $BUNDLE_ID $RECONNECT_KEY -bool false; log "set $RECONNECT_KEY back to off"
fi

# ---- Summary ----------------------------------------------------------------
"$PYTHON" - "$OUT" "$TELEMETRY" "$JUMP_MS" "$DRY" "$AIRPLAY_NAME" "$LOAD_WARN" "$SMOKE" "$TOGGLE_ID" <<'EOF'
import sys, os, re, json, datetime, statistics
out, tel, jump_ms, dry, airplay = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4] == "1", sys.argv[5]
load_warn = float(sys.argv[6]); smoke = sys.argv[7] == "1"; toggle = sys.argv[8]
loads = {}
for l in list(open(f"{out}/load.csv"))[1:]:
    ts, blk, load1, top = (l.rstrip("\n").split(",", 3) + [""] * 4)[:4]
    try: loads.setdefault(blk, []).append((ts, float(load1), top))
    except ValueError: pass
EVTS = ["bt_clock_jump", "bt_sink_anchored", "bt_sink_release_overshoot", "bt_sink_seek_clamped",
        "tap_feed_gap", "bt_clock_deviation", "drift_window_result", "drift_window_dropped",
        "drift_correction", "bt_room_term_changed", "room_delay_changed"]
TITLES = {"A": "Block A: both Moves, 25 min, the Move that is not `--c-move` off for 10 s at minute 22",
          "B": "Block B: the `--c-move` Move + This Mac, play 60 s, pause 90 s, play 60 s",
          "C": "Block C: one Move on Bluetooth + the other Move in Wi-Fi mode (AirPlay), 60 min"}

def tel_slice(a, b):
    """Bytes a..b of the telemetry file; if it rotated in between, the tail of .1 plus the head of the new file."""
    def read(p, s, e=None):
        try:
            with open(p, "rb") as f:
                f.seek(s); return f.read() if e is None else f.read(max(0, e - s))
        except OSError: return b""
    if b >= a: return read(tel, a, b), False
    return read(tel + ".1", a) + read(tel, 0, b), True

def rows_of(txt):
    rows, fit, clean, per5 = [], None, None, None
    for line in open(txt):
        if line.startswith("# linear fit: "): fit = line[14:].strip(); continue
        if line.startswith("# clean: "): clean = line[9:].strip(); continue
        if line.startswith("# median per 5 min: "): per5 = line[20:].strip(); continue
        if line.startswith("#"): continue
        p = line.split()
        if len(p) >= 2 and p[1] != "neighbour": rows.append((float(p[0]), None if p[1] == "merged" else float(p[1])))
    return rows, fit, clean, per5

def median(v):
    v = [x for x in v if x is not None]
    return f"{statistics.median(abs(x) for x in v):.1f} ms" if v else "no separate second click"

def deviation_slopes(lines):
    by = {}
    for r in lines:
        if r.get("evt") == "bt_clock_deviation":
            by.setdefault(r.get("uid", "?"), []).append((int(r["hostNanos"]) / 1e9, float(r["ms"]), int(r.get("jumps", 0))))
    res = []
    for uid, pts in by.items():
        if len(pts) < 2: res.append(f"{uid}: {len(pts)} line, too few for a slope"); continue
        t0 = pts[0][0]; xs = [p[0] - t0 for p in pts]; ys = [p[1] for p in pts]
        n = len(xs); mx = sum(xs) / n; my = sum(ys) / n
        s = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / (sum((x - mx) ** 2 for x in xs) or 1)
        res.append(f"{uid}: {n} lines over {xs[-1]/60:.0f} min, slope {s*60:+.3f} ms/min = {s*1000:+.1f} ppm, "
                   f"jumps {sum(p[2] for p in pts)}, first {ys[0]:+.1f} last {ys[-1]:+.1f} ms")
    return res

md = [f"# {'SMOKE: ' if smoke else ''}Listening night {os.path.basename(out)}", ""]
if smoke: md += ["SMOKE run: Block A 2 min (disconnect at 1:30), Block B 20 s / 30 s / 20 s, Block C 2 min. A rehearsal; the block titles below give the full-run lengths.", ""]
if os.path.exists(f"{out}/status.log"):
    st = [l.strip() for l in open(f"{out}/status.log")]
    bad = [l for l in st if l.startswith(("ALERT", "ABORT"))]
    md += [f"Watchdog (`status.log`): {sum(l.startswith('OK') for l in st)} OK, {sum(l.startswith('ALERT') for l in st)} ALERT, {sum(l.startswith('ABORT') for l in st)} ABORT."] + [f"- `{l}`" for l in bad[:20]] + [""]
if dry: md += ["Dry run: 10 s phases, no Audiout relaunch, no Bluetooth changes. The numbers check the tooling, not the speakers.", ""]
if os.path.exists(f"{out}/notes.txt"): md += ["## Notes", ""] + [f"- {l.strip()}" for l in open(f"{out}/notes.txt")] + [""]

for line in list(open(f"{out}/blocks.tsv"))[1:]:
    name, status, a, b, t0, events, ids = (line.rstrip("\n").split("\t") + [""] * 7)[:7]
    md += [f"## {TITLES[name]}", ""]
    if status != "ok": md += [f"Not run ({status}).", ""]; continue
    marks = {k: float(v) for k, v in (e.split("@") for e in events.split(";") if "@" in e)}
    raw, rotated = tel_slice(int(a), int(b))
    text = raw.decode("utf-8", "replace").splitlines()
    lines = []
    for l in text:
        try: lines.append(json.loads(l))
        except ValueError: pass
    md += [f"Selection `{ids or 'not set'}`. Recording `block{name}.wav`, analysis `block{name}.txt`, telemetry bytes {a} to {b}"
           + (" (the file rotated during the block; the tail of telemetry.jsonl.1 is included)" if rotated else "") + ".", ""]
    if marks: md += ["Marks, in seconds into the recording: " + ", ".join(f"{k} {v:.0f} s" for k, v in marks.items()), ""]
    txt = f"{out}/block{name}.txt"
    rows, fit, clean, per5 = rows_of(txt) if os.path.exists(txt) else ([], None, None, None)
    merged = sum(1 for _, o in rows if o is None)
    md += [f"Click periods measured: {len(rows)} ({merged} with one merged arrival)."]
    if name == "A":
        if "reconnect" in marks:
            t_rc = float(t0) + marks["reconnect"]
            def after(r):
                try: return datetime.datetime.fromisoformat(r["ts"].replace("Z", "+00:00")).timestamp() >= t_rc
                except (KeyError, ValueError): return False
            mine = [r for r in lines if r.get("uid") == toggle and after(r)]
            sinks = sum(1 for r in mine if r.get("evt") in ("bt_sink_rebuild", "bt_sink_anchored"))
            clocks = sum(1 for r in mine if r.get("evt") == "bt_clock_deviation")
            pairs = sum(1 for t, o in rows if t > marks["reconnect"] and o is not None)
            md += ["", f"Toggled Move: {toggle}; sink lines after reconnect: {sinks}; clock lines after reconnect: {clocks}; mic click pairs after reconnect: {pairs}",
                   "(a click pair is a 3 s period with a separate second arrival; a merged arrival is not counted)"]
        else: md += ["", f"Toggled Move: {toggle or 'not set'}; no reconnect in this run ({', '.join(marks) or 'no marks'})."]
    if name == "B" and "pause" in marks and "resume" in marks:
        before = [o for t, o in rows if t < marks["pause"]][-5:]
        after = [o for t, o in rows if t > marks["resume"]]
        md += ["", "| | offset of the second arrival |", "|---|---|",
               f"| before the pause (last 5 periods) | {median(before)} |",
               f"| right after resume (first 3 periods) | {median(after[:3])} |",
               f"| one minute after resume (last 3 periods) | {median(after[-3:])} |"]
    else:
        offs = [o if o is not None else 0.0 for _, o in rows]
        jumps = sum(1 for x, y in zip(offs, offs[1:]) if abs(y - x) > jump_ms)
        md += ["", f"Linear fit: {fit or 'fewer than 4 periods, no fit'}",
               f"Clean periods: {clean or 'not reported'}",
               f"Median offset per 5 min: {per5 or 'not reported'}",
               f"Jumps (offset change over {jump_ms:g} ms between neighbouring 3 s periods): {jumps}"]
    counts = {e: sum(1 for r in lines if str(r.get("evt", "")).startswith(e)) for e in EVTS}
    md += ["", "| telemetry line | count |", "|---|---|"] + [f"| `{e}` | {c} |" for e, c in counts.items()]
    slopes = deviation_slopes(lines)
    if slopes: md += ["", "`bt_clock_deviation` per speaker:", ""] + [f"- {s}" for s in slopes]
    ld = loads.get(name, [])
    if ld:
        peak = max(ld, key=lambda r: r[1])
        md += ["", f"Load (1-minute average, {len(ld)} samples in load.csv): max {peak[1]:.2f}, mean {sum(r[1] for r in ld)/len(ld):.2f}."]
        if peak[1] > load_warn:
            md += [f"**Warning:** load went above {load_warn:g} (peak {peak[1]:.2f} at {peak[0]}, busiest process {peak[2]}); something else was working on this Mac, so treat this block's timing with suspicion."]
    else: md += ["", "Load: no sample fell inside this block."]
    keep = [l for l in text if re.search(r'"evt":"(' + "|".join(EVTS) + ')', l)]
    with open(f"{out}/block{name}-telemetry.jsonl", "w") as f: f.write("\n".join(keep) + ("\n" if keep else ""))
    md += [""]

md += ["## Reading Blocks A and C (table from runbook 2)", "",
"| Acoustic slide (linear fit) | `bt_clock_deviation` slope | Meaning | What we build |",
"|---|---|---|---|",
"| ≥ ~0.3 ms/min (≥ 5 ppm) | same sign and within ~30 % of the acoustic number | The speaker follows the Mac's delivery rate and the app can see that rate | The servo steers the sink's resampler from the pacing-clock error against host time. Cheap, continuous, no mic needed for rate. |",
"| ≥ ~0.3 ms/min | flat (< 2 ppm) | The speaker's own buffer or clock is doing it, invisibly to the host | Rate is a microphone problem: event-driven acoustic re-checks plus a slow correction, no host servo for rate |",
"| flat (< 0.2 ms/min, < 3 ms over the hour) | flat | No common-mode drift in this setup | The servo still earns its place for pulls, lock misses and pauses (Runbook 1), but rate is not the field problem; the 1.2.0 creep came from something else |",
"| steps, not a line | `jumps` > 0 at the same times | Latency events, not drift | The event-driven design is right; check that a mic window fires on each |",
"", "Block A has two identical Moves, so a pass for fix 1 is an offset that stays flat (mostly merged arrivals); a step at the reconnect that stays is a fail. Offsets at or beyond 500 ms are neighbouring clicks and are dropped before the fit and the medians.",
"", "Block B (runbook 1): the same offset before and after within ~5 ms means a pause does not lose time; a jump that stays means the drain is real; a jump that walks back over seconds means something re-anchors.", ""]
open(f"{out}/summary.md", "w").write("\n".join(md))
print(f"{out}/summary.md")
EOF
if (( WITH_AIRPLAY )); then status "DONE switch the Move back to Bluetooth mode if you want both on Bluetooth tomorrow"
else status "DONE $(date +%H:%M:%S)"; fi
log "done; set remoteSlots back to 2 on the dev Mac (git config audiout.remoteSlots 2)"
