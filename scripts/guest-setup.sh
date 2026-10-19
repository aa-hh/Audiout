#!/usr/bin/env bash
#
# guest-setup.sh — one-time setup INSIDE the tart macOS VM so the mule can
# drive it over ssh (needed by run-on-vm.sh's full-auto launch).
#
# Run it in the VM's OWN Terminal:
#     bash "/Volumes/My Shared Files/build/guest-setup.sh"
#
# It's idempotent — safe to run again if something looks off.
set -uo pipefail

KEY="/Volumes/My Shared Files/build/mule-key.pub"

echo "==> Enabling Remote Login (may prompt for your password)"
sudo systemsetup -setremotelogin on \
  || echo "   (couldn't set it here — turn on System Settings > General > Sharing > Remote Login)"

echo "==> Installing the mule's public key"
# sshd ignores authorized_keys if the home dir is group/other-writable
# (its StrictModes check). Tighten it — the usual reason key auth silently fails.
chmod go-w ~ 2>/dev/null || true
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if [ -f "$KEY" ]; then
  touch ~/.ssh/authorized_keys
  # don't append a duplicate on re-run
  grep -qxF "$(cat "$KEY")" ~/.ssh/authorized_keys || cat "$KEY" >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
else
  echo "   ERROR: $KEY not found — is the folder shared into this VM?" >&2
fi

# Write diagnostics into the shared folder so the mule can read them directly.
DIAG="/Volumes/My Shared Files/build/guest-diag.txt"
{
  echo "user:  $(whoami)"
  echo "macOS: $(sw_vers -productVersion)"
  echo "--- key file ---";        ls -l "$KEY" 2>&1
  echo "--- authorized_keys ---"; cat ~/.ssh/authorized_keys 2>&1
  echo "--- perms (home/.ssh/keys) ---"; ls -ld ~ ~/.ssh ~/.ssh/authorized_keys 2>&1
  echo "--- remote login ---";    sudo systemsetup -getremotelogin 2>&1 || true
} | tee "$DIAG"

echo
echo "==> Diagnostics written to the shared folder (guest-diag.txt)."
echo "==> Done. Back on your main Mac:  bash scripts/run-on-vm.sh"
