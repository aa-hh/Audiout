#!/usr/bin/env bash
#
# run-on-vm.sh — build a self-contained .app and launch it inside the tart
# macOS VM on the mule, in one command.
#
# Why this exists: testing on an older macOS means a real (virtual) Mac, and
# that Mac has no Homebrew. The app links a stack of Homebrew dylibs (libevent,
# libsodium, libgcrypt, libplist, ...). Built the normal way it points at
# /opt/homebrew and dies at launch inside the VM with:
#     Library not loaded: /opt/homebrew/opt/libevent/lib/libevent-2.1.7.dylib
# make-app.sh bundles those dylibs into the app ONLY when AUDIOUT_BUNDLE_DYLIBS=1,
# so this script always sets it. That is the whole "make sure the VM has its
# dependencies" story: the app carries them, the VM installs nothing.
#
# Pipeline: build here -> rsync to the mule -> start the VM if it's down -> over
# two ssh hops (this Mac -> mule -> guest) stream the app onto the guest's disk
# and launch it with dummy devices.
#
# One thing it cannot do: START the VM. macOS refuses to bring up a GUI VM over
# an ssh connection ("could not switch to audit session"), so the VM must
# already be running, started at the mule itself. The script says so and gives
# the exact command if it finds the VM stopped.
#
# First run needs a one-time guest setup (SSH off by default in the image):
#   see the "GUEST NOT REACHABLE" message the script prints, or the top of
#   run-on-vm.README below.
#
# Config (all overridable via env):
#   APP_NAME       display name / .app basename      (default "Audiout VMTest")
#   BUNDLE_ID      bundle id                          (default com.audiout.Audiout.vmtest)
#   MULE_HOST      user@host of the mule              (default: git config audiout.remotehost)
#   VM_NAME        tart VM name                       (default sonoma-14.4)
#   VM_SHARE_DIR   mule folder shared into the VM     (default "/Volumes/Space/Audiout Build")
#   VM_SHARE_TAG   tart --dir tag                     (default build)
#   VM_GUEST_USER  login user inside the VM           (default admin)
set -euo pipefail

APP_NAME="${APP_NAME:-Audiout VMTest}"
BUNDLE_ID="${BUNDLE_ID:-com.audiout.Audiout.vmtest}"
MULE="${MULE_HOST:-$(git config --get audiout.remotehost)}"
VM="${VM_NAME:-sonoma-14.4}"
SHARE_DIR="${VM_SHARE_DIR:-/Volumes/Space/Audiout Build}"
SHARE_TAG="${VM_SHARE_TAG:-build}"
GUEST_USER="${VM_GUEST_USER:-alec}"
# Env the app is launched with inside the VM (space-separated KEY=VAL). The VM
# has no real audio/Bluetooth hardware, so the defaults give a fake speaker fleet
# (AIRPLAY_BACKEND=mock) with one fake Bluetooth speaker (AUDIOUT_MOCK_BLUETOOTH=1,
# for the Bluetooth UI and wizard), and skip the first-run onboarding and licence
# window, which otherwise cover the device list in a fresh VM. Override with
# VM_APP_ENV.
APP_ENV="${VM_APP_ENV:-AIRPLAY_BACKEND=mock AUDIOUT_MOCK_BLUETOOTH=1 AIRPLAY_SETUP=skip AUDIOUT_LICENSE_GATE=skip}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -n "$MULE" ] || { echo "ERROR: no mule host (set MULE_HOST or git config audiout.remotehost)" >&2; exit 1; }

# --- 1. build, dylibs bundled -------------------------------------------------
echo "==> Building '$APP_NAME' ($BUNDLE_ID) with Homebrew dylibs bundled"
# Build LOCALLY: the target VM runs on the mule, so routing the compile there
# too starves the VM (it froze and stopped once when they competed).
AUDIOUT_BUILD_LOCAL=1 AUDIOUT_BUNDLE_DYLIBS=1 APP_NAME="$APP_NAME" BUNDLE_ID="$BUNDLE_ID" bash "$SCRIPT_DIR/make-app.sh"

APP="build/$APP_NAME.app"
[ -d "$APP" ] || { echo "ERROR: '$APP' missing after build" >&2; exit 1; }

# Guard: a surviving absolute Homebrew path means bundling missed something and
# the app WILL crash in the VM. Catch it here, not from a crash log later.
if otool -L "$APP/Contents/MacOS/AudioutApp" | grep -qiE '/opt/homebrew|/usr/local'; then
  echo "ERROR: app still references Homebrew paths — it would crash in the VM:" >&2
  otool -L "$APP/Contents/MacOS/AudioutApp" | grep -iE '/opt/homebrew|/usr/local' >&2
  exit 1
fi

# --- 2. ship to the mule's shared folder --------------------------------------
# macOS rsync is old and lacks --protect-args, so escape spaces by hand for the
# remote shell. Sync bundle-contents-into-bundle so --delete stays scoped.
RPATH="$SHARE_DIR/$APP_NAME.app/"
echo "==> Shipping to $MULE:$RPATH"
rsync -a --delete "$APP/" "$MULE:${RPATH// /\\ }"

# --- 3. make sure the VM is up -------------------------------------------------
# macOS can't start a GUI VM directly over ssh, but `open` hands the job to the
# desktop session, which can. The starter runs tart in a Terminal window on the
# mule; close that window to stop the VM and free the mule's CPU (we do NOT keep
# it running in the background). Start and state checks are each their own short
# ssh call: a single long session once ended silently right after the VM
# started, and short reconnecting calls don't depend on one connection surviving.
vm_state() {
  ssh -n -o ConnectTimeout=10 "$MULE" "zsh -lc 'tart list'" 2>/dev/null \
    | awk -v v="$VM" '$2==v {print $NF}'
}
if [ "$(vm_state)" != "running" ]; then
  echo "==> VM '$VM' not running — starting it via the mule's desktop session"
  ssh "$MULE" "VM='$VM' SHARE_DIR='$SHARE_DIR' SHARE_TAG='$SHARE_TAG' zsh -ls" <<'START_VM'
set -euo pipefail
STARTER="$HOME/Desktop/start-audiout-vm.command"
if [ ! -x "$STARTER" ]; then
  cat > "$STARTER" <<STARTER_EOF
#!/bin/bash
# Auto-generated by run-on-vm.sh. Double-click to start the Audiout test VM;
# close this window to stop it.
export TART_HOME="$TART_HOME"
exec "$(command -v tart)" run "$VM" --dir=$SHARE_TAG:"$SHARE_DIR"
STARTER_EOF
  chmod +x "$STARTER"
fi
open "$STARTER"
START_VM
  for i in $(seq 1 30); do sleep 2; [ "$(vm_state)" = "running" ] && break; done
  if [ "$(vm_state)" != "running" ]; then
    echo "ERROR: VM '$VM' did not start within ~60s." >&2
    # Seen 2026-09-13: tart failed "utimes(2) failed: Operation not permitted"
    # because Terminal had lost macOS permission to the external drive the VM
    # lives on (ssh still had it, so nothing else looked wrong).
    echo "Most likely cause: Terminal on the mule can't access the drive holding the VM." >&2
    echo "Check the starter's Terminal window there. If it says 'utimes(2) failed: Operation not permitted'," >&2
    echo "turn on System Settings > Privacy & Security > Files & Folders > Terminal > Removable Volumes," >&2
    echo "quit Terminal (Cmd-Q), then re-run." >&2
    exit 3
  fi
fi

# --- 4. launch inside the VM (this Mac -> mule -> guest) -----------------------
echo "==> Launching inside VM '$VM'"
LAUNCH_LOG="$(mktemp -t run-on-vm)"
# `|| true`: if this ssh fails, let the GUEST-LAUNCHED check below report it,
# rather than `set -e` ending the script here with no message at all.
ssh "$MULE" "APP_NAME='$APP_NAME' VM='$VM' SHARE_DIR='$SHARE_DIR' SHARE_TAG='$SHARE_TAG' GUEST_USER='$GUEST_USER' APP_ENV='$APP_ENV' zsh -ls" <<'MULE_SIDE' | tee "$LAUNCH_LOG" || true
set -euo pipefail

IP=$(tart ip "$VM")
# One home for the guest-ssh options (a function, so zsh doesn't mangle it the
# way it would an unquoted string var). Dedicated passphrase-less key: the mule's
# normal key needs a passphrase, unusable non-interactively; IdentitiesOnly stops
# ssh offering that key first and giving up before it tries this one.
guest_ssh() {
  ssh -i "$HOME/.ssh/id_tart_guest" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 "$@"
}

# Wait for the guest desktop to finish auto-login. Opening an app before
# WindowServer/Dock are up fails with "Domain does not support specified action".
echo "==> Waiting for the guest desktop to be ready…"
READY=""
for _ in $(seq 1 45); do
  # </dev/null: this whole mule-side script arrives on ssh's stdin, and a bare
  # ssh here would read (and silently swallow) every line after it.
  if guest_ssh "$GUEST_USER@$IP" 'pgrep -x Dock >/dev/null 2>&1' </dev/null; then READY=1; break; fi
  sleep 2
done
if [ -z "$READY" ]; then
  cat >&2 <<SETUP
ERROR: guest not reachable + desktop-ready at $IP within ~90s.
If this is the VM's FIRST use, do the one-time setup in its OWN Terminal:
    sudo systemsetup -setremotelogin on
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    cat "/Volumes/My Shared Files/$SHARE_TAG/mule-key.pub" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
(The mule's public key is staged in the shared folder as mule-key.pub.)
SETUP
  exit 4
fi

# Stream the app from the mule straight onto the guest's own disk over ssh.
# NOT through the shared folder: the guest's view of it caches file contents, so
# after the mule replaces the bundle the guest keeps reading the OLD binary
# (seen 2026-09-13: new build on the mule, 13:03 build inside the VM).
echo "==> Copying '$APP_NAME.app' into the guest"
tar -C "$SHARE_DIR" -cf - "$APP_NAME.app" | guest_ssh "$GUEST_USER@$IP" \
  "pkill -f '$APP_NAME.app/Contents/MacOS/AudioutApp'; mkdir -p ~/AudioutVM && rm -rf ~/AudioutVM/'$APP_NAME.app' && tar -C ~/AudioutVM -xf -"

# Launch through a small .command rather than `open App.app`: make-app.sh pins
# AIRPLAY_BACKEND=native in the bundle's LSEnvironment, which LaunchServices
# applies on every `open` and which beats any env we set. Executing the binary
# directly skips LSEnvironment. Opening the .command keeps that exec inside the
# guest's desktop session (a bare exec over ssh has no WindowServer). The
# Terminal window it opens holds the app; closing it quits the app.
echo "==> Guest $GUEST_USER@$IP: launching"
SLUG="${APP_NAME// /-}"
GUEST_SCRIPT=$(cat <<GUEST
set -e
DST="\$HOME/AudioutVM/$APP_NAME.app"
LAUNCHER="\$HOME/AudioutVM/launch-$SLUG.command"
{
  echo '#!/bin/bash'
  echo '# Generated by run-on-vm.sh: direct exec so the bundle LSEnvironment is skipped.'
  echo "export $APP_ENV"
  echo "exec \"\$DST/Contents/MacOS/AudioutApp\""
} > "\$LAUNCHER"
chmod +x "\$LAUNCHER"
open "\$LAUNCHER"
echo "GUEST-LAUNCHED: \$DST (env: $APP_ENV)"
GUEST
)
echo "$GUEST_SCRIPT" | guest_ssh "$GUEST_USER@$IP" 'bash -s'
MULE_SIDE

# The guest prints GUEST-LAUNCHED last. If it's missing, part of the remote
# script never ran (e.g. a swallowed stdin) even though ssh exited 0.
grep -q '^GUEST-LAUNCHED' "$LAUNCH_LOG" \
  || { echo "ERROR: the app was not launched in the VM (no GUEST-LAUNCHED line)" >&2; exit 1; }
echo "==> Done — the app is opening on the VM screen at the mule."
