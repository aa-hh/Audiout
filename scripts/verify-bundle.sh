#!/bin/bash
# verify-bundle.sh — refuse to ship a .app that carries anything beyond what the
# product sanctions.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# WHY THIS EXISTS (2026-09-05): a dev performance watchdog — a `perfwatch.sh`
# plus a `com.audiouter.perfwatch` LaunchAgent — was found running on the
# owner's Mac for 6 days 22 hours. It was never in this repo: some earlier dev
# session wrote it straight into the app's live data directory and loaded a
# LaunchAgent for it. Nothing at build time would have stopped that same
# session from putting it inside the shipped bundle instead, where it would
# have gone out under a Developer ID signature. This gate is the mechanical
# stop: a user-facing build cannot CONTAIN anything the product does not
# sanction, and the app's only route to INSTALLING a persistent background
# process stays SMAppService, which routes every registration through the
# user's own Login Items approval.
#
# WHITELIST MINDSET, ENUMERABLE CHECKS. The bundle's sanctioned content is a
# short list — the three Mach-Os in Contents/MacOS, Contents/Resources
# (Assets.car / AppIcon.icns / the SwiftPM resource bundle / the wordmark
# font), Contents/Frameworks (Sparkle plus any bundled Homebrew dylibs),
# Info.plist, and exactly ONE launchd plist. Rather than diff that whole list
# (which would fight every legitimate resource change), each check below scans
# for one specific category of thing that has no business shipping. Add a
# check when a new category appears; never loosen one to let a file through.
#
# Usage: scripts/verify-bundle.sh <path-to-.app> <sanctioned-launchd-label>
#   e.g. scripts/verify-bundle.sh build/Audiout.app com.audiout.Audiout.ptphelper
#
# Exits 1 with FATAL on the first category that has any hit, listing every
# offending path. Run standalone against any built .app; make-app.sh invokes it
# after assembly and before codesigning.
#
# Every path below is QUOTED: this repo's own checkout path contains a space,
# and an unquoted expansion in make-app.sh silently broke the custom-symbol
# compile this same week.

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <path-to-.app> <sanctioned-launchd-label>" >&2
  exit 1
fi

APP_BUNDLE="$1"
SANCTIONED_LABEL="$2"
CONTENTS="$APP_BUNDLE/Contents"
# The ONE launchd plist a shipped bundle may carry: the root PTP helper daemon,
# registered at runtime through SMAppService. Its filename must equal
# Label + ".plist" — SMAppService.daemon(plistName:) resolves it by exact name.
SANCTIONED_PLIST="$CONTENTS/Library/LaunchDaemons/$SANCTIONED_LABEL.plist"
# Same file, BUNDLE-RELATIVE — every scan below matches against relative paths.
SANCTIONED_REL="Contents/Library/LaunchDaemons/$SANCTIONED_LABEL.plist"

test -d "$CONTENTS" || { echo "FATAL: $APP_BUNDLE has no Contents/ — not an app bundle" >&2; exit 1; }

echo "==> Verifying bundle contents (release content gate)"

# One loud exit path, so every category fails the same way. $1 is the reason,
# $2 the newline-separated list of offending paths. Called directly, never
# through a pipe — an `exit` inside a pipeline only leaves the subshell.
# Every `find` runs from INSIDE the bundle, so a path pattern can only ever
# match the bundle's own layout. Matching absolute paths instead made check 6
# reject every build made in a worktree, because the worktrees live under a
# .claude/ directory and so does everything inside them (caught 2026-09-05).
scan() {
  ( cd "$APP_BUNDLE" && find Contents "$@" 2>/dev/null ) || true
}

fail() {
  echo "FATAL: $1" >&2
  printf '%s\n' "$2" | sed 's/^/       /' >&2
  echo "       This build is REFUSED. See the header of scripts/verify-bundle.sh." >&2
  exit 1
}

# --- 1. launchd plists ------------------------------------------------------
# Anything under a LaunchAgents/ or LaunchDaemons/ directory, at any depth,
# that is not the one sanctioned daemon plist.
HITS="$(scan \( -path '*/LaunchAgents/*' -o -path '*/LaunchDaemons/*' \) -type f ! -path "$SANCTIONED_REL")"
[ -z "$HITS" ] || fail "unsanctioned launchd plist in the bundle — only $SANCTIONED_LABEL.plist may ship" "$HITS"
test -f "$SANCTIONED_PLIST" || fail "the sanctioned PTP-helper daemon plist is MISSING" "$SANCTIONED_PLIST"

# --- 2. launchd job keys in any other plist ---------------------------------
# A launchd job does not need to live in a LaunchDaemons/ directory to be
# loadable — `launchctl load <path>` takes a plist from anywhere. So scan EVERY
# plist in the bundle for the two keys that make one a job, and allow them only
# in the sanctioned file. Info.plists (the app's, Sparkle's, its XPC services')
# carry neither key.
#
# Normalised through plutil first: a plist is loadable in binary format too,
# and a raw grep for "<key>Label</key>" would sail straight past a binary one.
HITS=""
while IFS= read -r rel; do
  [ "$rel" = "$SANCTIONED_REL" ] && continue
  xml="$(plutil -convert xml1 -o - "$APP_BUNDLE/$rel" 2>/dev/null || true)"
  case "$xml" in
    *'<key>Label</key>'*|*'<key>ProgramArguments</key>'*) HITS="$HITS$rel"$'\n' ;;
  esac
done < <(scan -name '*.plist' -type f)
HITS="${HITS%$'\n'}"   # the loop appends a newline per hit; drop the trailing one
[ -z "$HITS" ] || fail "plist carrying launchd job keys (Label / ProgramArguments) outside the sanctioned daemon" "$HITS"
# The sanctioned file must be the daemon it claims to be, not something that
# merely took its name.
grep -q "<string>$SANCTIONED_LABEL</string>" "$SANCTIONED_PLIST" \
  || fail "the sanctioned daemon plist does not carry Label $SANCTIONED_LABEL" "$SANCTIONED_PLIST"

# --- 3. shell scripts -------------------------------------------------------
# The app ships three Mach-Os and data. It runs no script, ever, so a .sh in
# the bundle is either dev tooling that rode along or something worse — and a
# script inside a signed bundle inherits the bundle's trust.
HITS="$(scan -name '*.sh' -type f)"
[ -z "$HITS" ] || fail "shell script inside the bundle — the app executes no scripts" "$HITS"

# --- 4. dev tooling by name -------------------------------------------------
# The names this repo's own dev tooling uses, plus the watchdog shape of the
# 2026-09-05 incident. Belt-and-braces over check 3: a watchdog with no .sh
# suffix, or a compiled one, still gets caught here.
HITS="$(scan \( -name 'perfwatch*' -o -name '*watchdog*' -o -name 'purge-*' -o -name 'livetest*' -o -name 'self-review*' -o -name 'guard-*' \))"
[ -z "$HITS" ] || fail "dev tooling inside the bundle" "$HITS"

# --- 5. repo docs -----------------------------------------------------------
# Agent-facing documentation is not product. Its presence means a directory was
# copied wholesale out of the checkout — that mechanism is what this catches,
# not the files themselves.
HITS="$(scan \( -name 'AGENTS.md' -o -name 'AGENTS-HISTORY.md' -o -name 'CLAUDE.md' -o -name 'docs-delta*' \))"
[ -z "$HITS" ] || fail "repo documentation inside the bundle — a source directory was copied wholesale" "$HITS"

# --- 6. dev/ and .claude/ directories --------------------------------------
HITS="$(scan \( -path '*/dev/*' -o -path '*/.claude/*' -o -name 'dev' -o -name '.claude' \))"
[ -z "$HITS" ] || fail "dev/ or .claude/ content inside the bundle" "$HITS"

# --- 7. no launchd manipulation inside the shipped binaries -----------------
# The source audit says the shipped targets reach launchd through exactly one
# API — SMAppService, which routes every registration through the user's own
# Login Items approval — and never through launchctl or ~/Library/LaunchAgents.
# That is a claim about source; this checks the same claim against the bytes
# that actually ship, so a future edit reintroducing either route fails the
# build rather than the review.
#
# A RAW byte scan, deliberately, NOT `strings`: Apple's /usr/bin/strings parses
# the Mach-O and dumps only its sections even under -a, so anything appended
# past the code-signature blob is invisible to it (measured 2026-09-05 — a
# planted "launchctl" line sailed through a `strings -a` check and was caught
# by this one). grep -a reads the file as bytes and has no such blind spot.
#
# Both needles are at ZERO in all three shipped Mach-Os today (measured
# 2026-09-05 on this release build): SMAppService is a framework call, so
# neither string is linked in.
for macho in "$CONTENTS/MacOS/AudioutApp" "$CONTENTS/MacOS/ptp-helper" "$CONTENTS/MacOS/tcc-probe"; do
  test -f "$macho" || fail "expected Mach-O missing from the bundle" "$macho"
  for needle in launchctl LaunchAgents; do
    # `|| true` because grep exits 1 on no match and this runs under `set -e`;
    # the count it printed is still the answer.
    n="$(grep -a -c "$needle" "$macho" || true)"
    [ "$n" -eq 0 ] || fail "'$needle' appears in $(basename "$macho") — the only sanctioned route to a background process is SMAppService" "$macho"
  done
done

echo "    bundle content gate PASSED (1 sanctioned launchd plist, no scripts, no dev tooling, no launchctl/LaunchAgents in the binaries)"
