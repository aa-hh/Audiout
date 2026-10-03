#!/bin/zsh
# Schedule unattended-night.sh for a clock time, inside this Mac's logged-in session.
#
#   ./launch-tonight.sh HH:MM [unattended-night.sh flags...]
#   e.g. ./launch-tonight.sh 23:30 --with-airplay
#
# Run it in Terminal on the Mac that does the listening (Screen Sharing is fine).
# A one-shot LaunchAgent opens Terminal at HH:MM and runs the driver there, so the
# driver gets the Microphone, Automation and Bluetooth grants Terminal received
# during the dry run. The LaunchAgent removes itself when it fires. caffeinate
# holds the Mac awake from now until the driver exits.
set -euo pipefail
HERE=${0:A:h}
LABEL=com.audiout.listening-night
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
WRAPPER="$HERE/results/night.command"
DOMAIN="gui/$(id -u)"
die() { print -u2 "STOP: $*"; exit 1 }

[[ ${1:-} =~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]$' ]] || die "usage: $0 HH:MM [unattended-night.sh flags...]"
TIME=$1; shift
HH=$((10#${TIME%%:*})); MM=$((10#${TIME##*:}))
now=$(date +%s)
start=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%Y-%m-%d) $(printf %02d:%02d $HH $MM):00" +%s)
(( start > now + 60 )) || start=$(( start + 86400 ))

launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && die "a night is already scheduled; cancel it first: launchctl bootout $DOMAIN/$LABEL; rm '$PLIST'"

# Fails loudly on a missing tool, an unknown or empty id, or a build without the select key.
"$HERE/unattended-night.sh" --check "$@"

mkdir -p "$HERE/results" "${PLIST:h}"
{
  print '#!/bin/zsh'
  print -r -- "launchctl bootout $DOMAIN/$LABEL 2>/dev/null; rm -f ${(q)PLIST}"
  print -r -- "caffeinate -dims ${(q)HERE}/unattended-night.sh ${(q)@}"
  print -r -- 'print "unattended-night.sh exited with status $?"'
} > "$WRAPPER"
chmod +x "$WRAPPER"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-a</string><string>Terminal</string><string>${WRAPPER//&/&amp;}</string></array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$HH</integer><key>Minute</key><integer>$MM</integer></dict>
</dict>
</plist>
EOF
plutil -lint -s "$PLIST" || die "the LaunchAgent plist did not validate: $PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST" || die "launchctl bootstrap $DOMAIN failed; run this in Terminal on that Mac while logged in, not over ssh"

# Awake until the start, plus margin; the wrapper's own caffeinate covers the night itself.
nohup caffeinate -dims -t $(( start - now + 600 )) >/dev/null 2>&1 &!
print "Scheduled for $(date -r $start '+%a %H:%M'). Mac held awake until then by caffeinate (pid $!)."
print "Results will land in $HERE/results/<date>_<time>/summary.md"
print "Cancel: launchctl bootout $DOMAIN/$LABEL; rm '$PLIST'; kill $!"
