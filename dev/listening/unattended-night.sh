#!/bin/zsh
# Unattended listening night for the Bluetooth sync fixes. See README.md here.
#
#   ./unattended-night.sh [--dry-run | --smoke] [--with-airplay] [--move1 ID] [--move2 ID] [--airplay-id ID] [--c-move ID]
#   ./unattended-night.sh --list-devices      # ids this Mac has seen, in the form the driver takes
#   ./unattended-night.sh --check [flags]     # tools, ids and build only, then exit (launch-tonight.sh runs it)
#
# Block A (25 min): both Moves, click track loops, mic records; at minute 20 the
#   second Move is disconnected for 10 s and reconnected (needs blueutil).
# Block B (~5 min): Move 1 + This Mac; play 60 s, pause 90 s, play 60 s.
# Block C (60 min, --with-airplay only): one Move on Bluetooth (--c-move, default
#   Move 1) + the other Move in Wi-Fi mode as an AirPlay speaker (--airplay-id).
#   A Move is Bluetooth or AirPlay, never both, and switching is a button press,
#   so before Block C the driver waits for someone to switch it and confirm.
# Then: convert, run click-pair-spacing.py, cut each block's telemetry lines,
# write results/<date>/summary.md.
#
# --dry-run: every phase lasts 10 s, Audiout is not relaunched and Bluetooth is
# not touched. Exercises QuickTime, recording, conversion, analysis and the
# summary on any Mac. If the mic or QuickTime cannot be used it falls back to a
# synthetic recording and says so in the summary.
#
# --smoke: the real run, shortened for a rehearsal with the owner in the room:
# Block A 2 min (disconnect at minute 1), Block B 20 s / 30 s / 20 s, Block C 2 min.
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
GO_FILE="$HOME/listening/go-block-c"   # touch this to confirm the Wi-Fi switch (Enter works too at a terminal)
WAIT_C_S=1800           # how long to wait for that confirmation
AIRPLAY_NAME="AirPlay speaker"
MAC_ID=local-mac         # This Mac; the same id on every Mac
MAC_VOLUME=50            # system output volume set before each relaunch; Audiout adopts it as its master level
# Recording: auto = ffmpeg if installed, else QuickTime. MIC_INDEX empty = find
# the built-in mic in `ffmpeg -f avfoundation -list_devices true -i ""`.
RECORDER=${RECORDER:-auto}
MIC_INDEX=""
MIC_PATTERN='MacBook.*Microphone|Built-in Microphone'
CLICK_WAV="$HERE/click-track-3s.wav"      # beside the script (the ~/listening copy); else the repo's runbooks folder
ANALYSER="$HERE/click-pair-spacing.py"
[[ -f $CLICK_WAV ]] || CLICK_WAV="$HERE/../notes/bt-sync-discovery/runbooks/click-track-3s.wav"
[[ -f $ANALYSER ]] || ANALYSER="$HERE/../notes/bt-sync-discovery/runbooks/click-pair-spacing.py"
PYTHON=${PYTHON:-python3}
TELEMETRY="$HOME/Library/Logs/Audiout/telemetry.jsonl"
RESULTS_ROOT="$HERE/results"
SETTLE_S=60          # Bluetooth clocks step for ~40 s after a connect
A_FIRST_S=1200       # Block A: 20 min, then the disconnect
A_OFF_S=10
A_REST_S=300         # Block A: 5 min after the reconnect
B_PLAY_S=60
B_PAUSE_S=90
C_S=3600
JUMP_MS=5            # an offset change bigger than this between 3 s rows is a jump
OSA_TIMEOUT_S=30     # an osascript call longer than this is waiting on a permission prompt
LOAD_EVERY_S=60      # load.csv sample interval
LOAD_WARN=4          # summary.md warns, and the watchdog alerts, above this 1-minute load average
WATCH_EVERY_S=60     # watchdog interval during a block
RMS_FLOOR_DB=-80     # mic level over the last 10 s must be above this (digital silence is -inf)
CLICKS_MIN=8         # 3 s periods with a click found in the last 30 s
CLOCK_WINDOW_S=90    # every selected Bluetooth speaker must log bt_clock_deviation within this
ALERTS_TO_ABORT=3    # consecutive alerts on one check that end a block early
PROBE_S=20           # pre-flight probe recording before Block A

# ---- Flags ------------------------------------------------------------------
MODE=night; DRY=0; SMOKE=0; WITH_AIRPLAY=0
while (( $# )); do
  case $1 in
    --dry-run) DRY=1 ;;
    --smoke) SMOKE=1 ;;
    --with-airplay) WITH_AIRPLAY=1 ;;
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
  A_FIRST_S=60; A_OFF_S=10; A_REST_S=50; B_PLAY_S=20; B_PAUSE_S=30; C_S=120
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
if [[ $RECORDER == auto ]]; then
  command -v ffmpeg >/dev/null && RECORDER=ffmpeg || RECORDER=quicktime
fi
[[ $RECORDER == ffmpeg ]] && need ffmpeg "brew install ffmpeg"
BLUE_PROBLEM=""
if ! command -v blueutil >/dev/null; then BLUE_PROBLEM="blueutil not installed"
elif ! to 15 blueutil --power >/dev/null 2>&1; then BLUE_PROBLEM="blueutil cannot reach Bluetooth (Terminal needs Bluetooth access in Privacy & Security)"; fi
HAVE_BLUEUTIL=$([[ -z $BLUE_PROBLEM ]] && print 1 || print 0)

KEY_PROBLEM=""
if [[ ! -d $APP ]]; then KEY_PROBLEM="Audiout Dev not found at $APP. Install it there (README step 2)."
elif ! grep -rqaF "$RECONNECT_KEY" "$APP/Contents/MacOS" "$APP/Contents/Frameworks" 2>/dev/null; then
  KEY_PROBLEM="Audiout Dev at $APP has no \"Reconnect last speakers when Audiout starts\" setting ($RECONNECT_KEY), so the driver cannot change the speaker selection unattended. Install a build from main after roadmap 050."
fi

# Ids per block; a real run refuses an empty or unknown id before anything plays.
typeset -a IDS_A IDS_B IDS_C
C_MOVE_ID=${C_MOVE_ID:-$MOVE1_ID}
IDS_A=($MOVE1_ID $MOVE2_ID); IDS_B=($MOVE1_ID $MAC_ID); IDS_C=($C_MOVE_ID $AIRPLAY_ID)
ids_problem=""
for pair in MOVE1_ID:$MOVE1_ID MOVE2_ID:$MOVE2_ID $( (( WITH_AIRPLAY )) && print AIRPLAY_ID:$AIRPLAY_ID ); do
  [[ -n ${pair#*:} ]] || ids_problem+="${pair%%:*} is empty (run --list-devices and set it). "
done
unknown=$(devices check $MOVE1_ID $MOVE2_ID $( (( WITH_AIRPLAY )) && print -- $C_MOVE_ID $AIRPLAY_ID )) || ids_problem+="$unknown "
[[ -z $C_MOVE_ID || $C_MOVE_ID == *:output ]] || ids_problem+="--c-move must be a Bluetooth id (ending :output): $C_MOVE_ID. "

if (( ! DRY )); then
  [[ -z $KEY_PROBLEM$ids_problem ]] || die "$ids_problem$KEY_PROBLEM"
fi
if [[ $MODE == check ]]; then
  log "check passed: tools present, ids known, build has $RECONNECT_KEY; recorder $RECORDER; ${BLUE_PROBLEM:-blueutil works}"
  exit 0
fi

SUFFIX=""; (( DRY )) && SUFFIX=-dry-run; (( SMOKE )) && SUFFIX=-smoke
OUT="$RESULTS_ROOT/$(date +%Y-%m-%d_%H%M)$SUFFIX"
mkdir -p "$OUT"
log "results: $OUT; recorder: $RECORDER; dry run: $DRY; smoke: $SMOKE"
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
trap 'kill $LOAD_PID 2>/dev/null' EXIT
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

FAKE_AUDIO=0      # 1 once the mic or QuickTime turned out to be unusable (dry run only)
QT_DOC=${CLICK_WAV:t}

qt() { to $OSA_TIMEOUT_S osascript -e "tell application \"QuickTime Player\" to $1" >/dev/null }
play_start() {
  (( FAKE_AUDIO )) && return 0
  to $OSA_TIMEOUT_S osascript >/dev/null <<EOF
tell application "QuickTime Player"
  set d to open (POSIX file "$CLICK_WAV")
  set looping of d to true
  play d
end tell
EOF
}
play_pause() { (( FAKE_AUDIO )) && return 0; qt "pause document \"$QT_DOC\"" }
play_resume() { (( FAKE_AUDIO )) && return 0; qt "play document \"$QT_DOC\"" }
play_stop() { (( FAKE_AUDIO )) && return 0; qt "close document \"$QT_DOC\" saving no" }

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
  if [[ $RECORDER == ffmpeg ]]; then
    ffmpeg -nostdin -hide_banner -loglevel error -f avfoundation -i ":$MIC_INDEX" -ac 1 -y "$1.wav" 2>>"$OUT/ffmpeg.log" &
    REC_PID=$!
  else
    to $OSA_TIMEOUT_S osascript >/dev/null <<'EOF'
tell application "QuickTime Player"
  set r to new audio recording
  start r
end tell
EOF
  fi
}
rec_stop() {  # $1 = raw file without extension; leaves $1.wav or $1.m4a
  (( FAKE_AUDIO )) && return 0
  if [[ $RECORDER == ffmpeg ]]; then
    kill -TERM $REC_PID 2>/dev/null || true; wait $REC_PID 2>/dev/null || true
  else
    # A stopped recording reopens as a new document; `save` fails on it, `export` works.
    to 600 osascript >/dev/null <<EOF || return 1
tell application "QuickTime Player"
  set r to first document whose name is not "$QT_DOC"
  stop r
  delay 2
  set r to first document whose name is not "$QT_DOC"
  export r in (POSIX file "$1.m4a") using settings preset "Audio Only"
end tell
EOF
    local size=-1 i; for i in {1..300}; do  # export can return before the file is complete
      [[ -f $1.m4a && $(stat -f %z "$1.m4a") == $size ]] && break
      [[ -f $1.m4a ]] && size=$(stat -f %z "$1.m4a"); sleep 2
    done
    qt "close (first document whose name is not \"$QT_DOC\") saving no"
  fi
}
raw_file() { [[ -f $1.wav ]] && print -n -- "$1.wav" || print -n -- "$1.m4a" }

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

# Before the night starts: can this process drive QuickTime and hear the mic?
preflight() {
  [[ $RECORDER == ffmpeg ]] && find_mic
  local why=""
  play_start 2>>"$OUT/driver.log" || why="QuickTime could not be driven by osascript within $OSA_TIMEOUT_S s (Automation permission: error -1743 means denied, a timeout means a prompt is waiting on screen)"
  if [[ -z $why ]]; then
    rec_start "$OUT/preflight" 2>>"$OUT/driver.log" || why="recording could not start (QuickTime recording timed out or failed)"
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
  [[ -z $why ]] && { log "preflight: QuickTime and mic both work"; return 0; }
  (( DRY )) || die "preflight failed: $why. Run the dry run once while present to approve the prompts."
  FAKE_AUDIO=1
  note "DRY RUN FALLBACK: $why. Playback and recording are replaced by a synthetic recording (two clicks per 3 s, the second 42 ms later)."
}

bt_connected() { [[ $(to 15 blueutil --is-connected "$1") == 1 ]] }
bt_addr() { print -n -- ${1%:output} }
ensure_connected() {  # Bluetooth ids...
  (( DRY || ! HAVE_BLUEUTIL )) && return 0
  local a; for a in "$@"; do
    a=$(bt_addr $a)
    bt_connected $a && continue
    log "connecting $a"; to 30 blueutil --connect $a || true; sleep 5
    bt_connected $a || { log "$a did not connect"; return 1; }
  done
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
    from=$(tel_size); t0=$SECONDS
    open "$APP"
    play_start || log "playback did not start"   # sinks only build with audio flowing
    sleep $LIVE_CHECK_S
    got=$(selection_mismatch "$ROUTING" "$@")
    live=$(live_mismatch $from "$@")
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
live_raw() {  # the growing recording the watchdog can read, or empty when there is none
  (( FAKE_AUDIO )) || [[ $RECORDER != ffmpeg ]] && return 0
  print -n -- "$OUT/block$B_NAME-raw.wav"
}
watch_check() {
  local out=$(watch_probe "$(live_raw)" $B_REC_PREV 30 $B_PAUSED ${=B_IDS}) t=$(date +%H:%M:%S)
  local -a lines=("${(@f)out}"); local fields=$lines[1] l c
  [[ $fields == rec=<->* ]] && B_REC_PREV=${${fields#rec=}%% *}
  local -a fails=(${(@)lines[2,-1]:#})
  local -A failed
  if (( ! $#fails )); then status "OK $B_NAME $t $fields"; ALERT_RUN=(); return 0; fi
  for l in $fails; do
    c=${l%% *}; failed[$c]=1; ALERT_RUN[$c]=$(( ${ALERT_RUN[$c]:-0} + 1 ))
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
    (( SECONDS >= B_NEXT )) && { watch_check; B_NEXT=$(( SECONDS + WATCH_EVERY_S )); }
    next=$(( B_NEXT < end ? B_NEXT : end )); (( next > SECONDS )) && sleep $(( next - SECONDS ))
  done
  return 0
}

# Before Block A: the same checks once on a short probe recording; a real run
# refuses to start on any alert and says what to fix.
probe_check() {  # ids...
  local raw="$OUT/probe-raw" t=$(date +%H:%M:%S)
  play_start; rec_start "$raw"; sleep $PROBE_S
  local p=""; (( FAKE_AUDIO )) || [[ $RECORDER != ffmpeg ]] || p="$raw.wav"
  local out=$(watch_probe "$p" 0 $PROBE_S 0 "$@")
  rec_stop "$raw" || true; play_stop || true
  local -a lines=("${(@f)out}"); local -a fails=(${(@)lines[2,-1]:#}); local l fix=""
  log "pre-flight probe: $lines[1]"
  if (( ! $#fails )); then status "OK PREFLIGHT $t $lines[1]"; return 0; fi
  for l in $fails; do
    status "ALERT PREFLIGHT $t ${l%% *} ${l#* }"
    case ${l%% *} in
      rec) fix+="The recording did not grow: check ffmpeg.log and Terminal's Microphone access. " ;;
      rms) fix+="The mic hears nothing (${l#* } dBFS): check Terminal's Microphone access and the input level in Sound settings. " ;;
      clicks) fix+="Too few clicks heard (${l#* }): check the speakers are on, selected in Audiout Dev, loud enough and 1 to 2 m away. " ;;
      clock) fix+="No bt_clock_deviation line from ${${l#* }%:0} in $CLOCK_WINDOW_S s: that Move is not playing through Audiout Dev; check it is connected and selected. " ;;
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
  B_ABORT=0; B_PAUSED=0; B_REC_PREV=0; ALERT_RUN=(); B_NEXT=$(( SECONDS + WATCH_EVERY_S ))
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

# Block A: both Moves.
if ensure_connected $IDS_A && select_speakers $IDS_A; then
  probe_check $IDS_A
  play_start; block_begin A $IDS_A
  watch_sleep $A_FIRST_S
  if (( B_ABORT )); then :
  elif (( DRY )); then mark toggle_skipped_dry_run; watch_sleep $A_OFF_S
  elif (( HAVE_BLUEUTIL )); then
    mark disconnect; to 30 blueutil --disconnect $(bt_addr $MOVE2_ID) || log "disconnect failed"
    watch_sleep $A_OFF_S
    mark reconnect; to 30 blueutil --connect $(bt_addr $MOVE2_ID) || log "reconnect failed"
    watch_sleep 5; bt_connected $(bt_addr $MOVE2_ID) || note "block A: second Move did not reconnect"
  else mark toggle_skipped_no_blueutil; watch_sleep $A_OFF_S; fi
  watch_sleep $A_REST_S
  block_end
else block_skip A "both Moves could not be connected or selected (see driver.log)"; fi

# Block B: Move 1 plus This Mac. The second Move is disconnected so it cannot play.
(( ! DRY && HAVE_BLUEUTIL )) && { to 30 blueutil --disconnect $(bt_addr $MOVE2_ID) || true; }
if ensure_connected $MOVE1_ID && select_speakers $IDS_B; then
  play_start; block_begin B $IDS_B
  watch_sleep $B_PLAY_S
  if (( ! B_ABORT )); then
    mark pause; play_pause || log "pause failed"; B_PAUSED=1  # the mic and click checks expect silence now
    watch_sleep $B_PAUSE_S
    mark resume; play_resume || log "resume failed"; B_PAUSED=0
    watch_sleep $B_PLAY_S
  fi
  block_end
else block_skip B "Move 1 could not be connected or selected with This Mac (see driver.log)"; fi

# Block C: one Move on Bluetooth plus the other Move in Wi-Fi mode. Someone has
# to press the Move's button, so wait for Enter or the go file.
wait_for_wifi_switch() {
  if (( ! DRY )); then
    to 20 osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  fi
  rm -f "$GO_FILE"
  status "WAITING C $(date +%H:%M:%S) switch the other Move to Wi-Fi mode, wait for it to appear as an AirPlay speaker, then confirm (Enter here, or: touch $GO_FILE)"
  local end=$(( SECONDS + WAIT_C_S ))
  while (( SECONDS < end )); do
    [[ -f $GO_FILE ]] && { rm -f "$GO_FILE"; log "Block C confirmed by $GO_FILE"; return 0; }
    if [[ -t 0 ]]; then read -t 2 -r _ && { log "Block C confirmed by Enter"; return 0; }
    else sleep 2; fi
  done
  status "ABORT C timeout waiting for the AirPlay switch"
  return 1
}
if (( WITH_AIRPLAY )); then
  if ! wait_for_wifi_switch; then block_skip C "nobody confirmed the switch to Wi-Fi mode within $WAIT_C_S s"
  elif ensure_connected $C_MOVE_ID && select_speakers $IDS_C; then
    play_start; block_begin C $IDS_C
    watch_sleep $C_S
    block_end
  else block_skip C "the Bluetooth Move or the Move in Wi-Fi mode could not be selected (see driver.log)"; fi
fi
(( ! DRY && HAVE_BLUEUTIL && ! WITH_AIRPLAY )) && { to 30 blueutil --connect $(bt_addr $MOVE2_ID) || true; }
if [[ $RECONNECT_WAS == off || $RECONNECT_WAS == 0 ]]; then
  defaults write $BUNDLE_ID $RECONNECT_KEY -bool false; log "set $RECONNECT_KEY back to off"
fi

# ---- Summary ----------------------------------------------------------------
"$PYTHON" - "$OUT" "$TELEMETRY" "$JUMP_MS" "$DRY" "$AIRPLAY_NAME" "$LOAD_WARN" "$SMOKE" <<'EOF'
import sys, os, re, json
out, tel, jump_ms, dry, airplay = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4] == "1", sys.argv[5]
load_warn = float(sys.argv[6]); smoke = sys.argv[7] == "1"
loads = {}
for l in list(open(f"{out}/load.csv"))[1:]:
    ts, blk, load1, top = (l.rstrip("\n").split(",", 3) + [""] * 4)[:4]
    try: loads.setdefault(blk, []).append((ts, float(load1), top))
    except ValueError: pass
EVTS = ["bt_clock_jump", "bt_sink_anchored", "bt_sink_release_overshoot", "bt_sink_seek_clamped",
        "tap_feed_gap", "bt_clock_deviation", "drift_window_result", "drift_window_dropped",
        "drift_correction", "bt_room_term_changed", "room_delay_changed"]
TITLES = {"A": "Block A: both Moves, 25 min, one Move off for 10 s at minute 20",
          "B": "Block B: one Move + This Mac, play 60 s, pause 90 s, play 60 s",
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
    rows, fit = [], None
    for line in open(txt):
        if line.startswith("# linear fit: "): fit = line[14:].strip(); continue
        if line.startswith("#"): continue
        p = line.split()
        if len(p) >= 2: rows.append((float(p[0]), None if p[1] == "merged" else float(p[1])))
    return rows, fit

def mean(v):
    v = [x for x in v if x is not None]
    return f"{sum(v)/len(v):+.1f} ms" if v else "no separate second click"

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
if smoke: md += ["SMOKE run: Block A 2 min (disconnect at minute 1), Block B 20 s / 30 s / 20 s, Block C 2 min. A rehearsal; the block titles below give the full-run lengths.", ""]
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
    rows, fit = rows_of(txt) if os.path.exists(txt) else ([], None)
    merged = sum(1 for _, o in rows if o is None)
    md += [f"Click periods measured: {len(rows)} ({merged} with one merged arrival)."]
    if name == "B" and "pause" in marks and "resume" in marks:
        before = [o for t, o in rows if t < marks["pause"]][-5:]
        after = [o for t, o in rows if t > marks["resume"]]
        md += ["", "| | offset of the second arrival |", "|---|---|",
               f"| before the pause (last 5 periods) | {mean(before)} |",
               f"| right after resume (first 3 periods) | {mean(after[:3])} |",
               f"| one minute after resume (last 3 periods) | {mean(after[-3:])} |"]
    else:
        offs = [o if o is not None else 0.0 for _, o in rows]
        jumps = sum(1 for x, y in zip(offs, offs[1:]) if abs(y - x) > jump_ms)
        md += ["", f"Linear fit: {fit or 'fewer than 4 periods, no fit'}",
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
"", "Block A has two identical Moves, so a pass for fix 1 is an offset that stays flat (mostly merged arrivals); a step at the reconnect that stays is a fail.",
"", "Block B (runbook 1): the same offset before and after within ~5 ms means a pause does not lose time; a jump that stays means the drain is real; a jump that walks back over seconds means something re-anchors.", ""]
open(f"{out}/summary.md", "w").write("\n".join(md))
print(f"{out}/summary.md")
EOF
if (( WITH_AIRPLAY )); then status "DONE switch the Move back to Bluetooth mode if you want both on Bluetooth tomorrow"
else status "DONE $(date +%H:%M:%S)"; fi
log "done; set remoteSlots back to 2 on the dev Mac (git config audiout.remoteSlots 2)"
