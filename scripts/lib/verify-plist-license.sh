#!/bin/sh
# The check that decides paid vs free at ship time: does this app bundle's
# Info.plist carry AudioutLicenseServerURL, and does it name the server we
# meant? make-app.sh writes the key only when a licence URL is supplied, so
# its absence IS the free source build — and its presence with the wrong
# value is an artifact that validates no keys and never updates.
#
# SOURCED, never executed. Callers: scripts/make-staging.sh,
# scripts/test-license-guards.sh.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# WHY A SHARED FILE: the check guards the shipped artifact in make-staging.sh,
# and a check that guards a release must be testable without building one.
# The test sources this same function; a copy in the test would drift and
# then test nothing.

# verify_app_plist_license_url <path to .app bundle> <expected URL>
# Returns 0 when the bundle's AudioutLicenseServerURL equals the expected URL
# exactly; otherwise prints an ERROR naming actual and expected to stderr and
# returns 1. plutil failing (missing key, missing plist) reads as '<missing>'.
# The blanking on failure is deliberate: newer plutil prints its error to
# STDOUT (observed on the macos-15 CI runner), and without it that text would
# masquerade as the extracted value in the message.
verify_app_plist_license_url() {
  _vapl_actual="$(plutil -extract AudioutLicenseServerURL raw -o - "$1/Contents/Info.plist" 2>/dev/null)" || _vapl_actual=""
  [ "$_vapl_actual" = "$2" ] || { echo "ERROR: Info.plist AudioutLicenseServerURL is '${_vapl_actual:-<missing>}', expected '$2' — the shipped app validates no keys and never updates" >&2; return 1; }
}
