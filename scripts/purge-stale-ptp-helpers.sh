#!/bin/bash
# purge-stale-ptp-helpers.sh — dev-only tool: find and remove stale root
# PTP-helper launchd daemons left behind by old or side-by-side Audiout dev
# builds (T-ZOMBIE).
#
# WHY THIS EXISTS: scripts/make-app.sh derives each build's helper daemon
# label as "${BUNDLE_ID}.ptphelper" (see that script and scripts/ptp-helper.plist
# for the exact derivation) and registers it as a root SMAppService LaunchDaemon.
# BUNDLE_ID is deliberately env-overridable so side-by-side dev copies get their
# own daemon identity instead of colliding — but every distinct BUNDLE_ID ever
# used (default com.audiout.Audiout, a "Coexist" id, ad-hoc *-test/*-dev
# override ids, ...) leaves its OWN separate always-on root daemon registered
# with launchd, forever, until someone boots it out by hand. Live testing has
# piled up over a dozen of these across unrelated dev builds in a single
# session. Hand-purging them one `sudo launchctl bootout` at a time is the
# pain this script removes: it finds every one of them, whatever bundle-id
# variant produced it, and boots them all out in one command.
#
# THIS IS A DEV TOOL, NOT SHIPPING CODE. It needs sudo to actually remove
# anything (booting out a system/root-domain launchd daemon requires root —
# there is no way around that), so --apply CANNOT run unattended: expect a
# sudo password prompt unless you already have a live sudo timestamp.
#
# SAFETY:
#   - Dry run by default. With no flags this script only LISTS candidates —
#     it never calls bootout, never touches launchd, mutates nothing.
#   - --apply is required to actually remove anything.
#   - The match is hard-scoped to labels whose name ends EXACTLY in
#     ".ptphelper" (checked with a real string-suffix comparison, not a
#     substring grep, so "com.foo.ptphelperbackup" does NOT match). This
#     script must never be able to touch an unrelated system job — do not
#     loosen this filter.
#
# Usage:
#   scripts/purge-stale-ptp-helpers.sh            # list candidates (dry run)
#   scripts/purge-stale-ptp-helpers.sh --apply     # actually bootout each one
#   scripts/purge-stale-ptp-helpers.sh --apply --keep com.audiout.Audiout.ptphelper
#   scripts/purge-stale-ptp-helpers.sh --help
# Every command below is a paste-proof one-liner — no backslash continuations.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: purge-stale-ptp-helpers.sh [--apply] [--keep LABEL]... [--help]

Enumerates every root launchd daemon in the system domain whose label ends in
".ptphelper" (the PTP-helper daemon scripts/make-app.sh registers per
BUNDLE_ID — see that script's HELPER_LABEL). Stale copies from old or
side-by-side dev builds pile up as always-on root daemons and block live
testing.

  (no flags)   Dry run (default). List every matching label and its current
               launchd state. Mutates nothing.
  --apply      Actually boot each matched daemon out via
               `sudo launchctl bootout system/<label>`. Requires sudo — you
               will be prompted for your password unless you already have a
               live sudo timestamp. Best-effort: a label with no currently
               loaded job (override-only) is reported, not treated as a
               failure.
  --keep LABEL Exclude one exact label from the sweep — it is skipped in the
               listing and never booted out. Repeatable. Used by
               scripts/purge-dev-installs.sh to spare the SHIPPING build's
               helper while clearing every dev one.
  --help       Show this message.

This is a dev-only tool. It is not run in CI and cannot run fully unattended
in --apply mode.
EOF
}

# Hard-coded, not a variable someone could accidentally widen at a call site —
# this literal IS the safety boundary (see header SAFETY note).
LABEL_SUFFIX=".ptphelper"

APPLY=0
# Labels to spare. Newline-delimited rather than an array so the emptiness
# check below stays a plain string test (see the bash 3.2 note further down on
# why empty-array expansion under `set -u` is a trap worth designing around).
KEEP_LABELS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --keep)
      [ "$#" -ge 2 ] || { echo "error: --keep needs a label" >&2; exit 1; }
      KEEP_LABELS="$KEEP_LABELS
$2"
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Exact whole-string match against the --keep list — a substring or prefix
# match here would let one spared label accidentally shield its neighbours.
is_kept() {
  [ -n "$KEEP_LABELS" ] || return 1
  printf '%s\n' "$KEEP_LABELS" | grep -qxF "$1"
}

# --- Enumerate: every label registered in the system (root) launchd domain --
# `launchctl print system` dumps the whole system-domain state (loaded jobs in
# its "services" block, plus a separate "disabled services" override table —
# a label can appear in either, or both, and a stale registration commonly
# survives in the override table even after the daemon itself is gone). No
# sudo needed just to read this. Runs from the repo, but doesn't need to.
RAW="$(launchctl print system 2>/dev/null || true)"
if [ -z "$RAW" ]; then
  echo "error: 'launchctl print system' returned nothing — is launchd reachable?" >&2
  exit 1
fi

# Pull every token made of label-safe characters, then keep only the ones
# whose FULL string ends in LABEL_SUFFIX (awk substr equality, not a grep
# substring match) — this is what makes "com.foo.ptphelperbackup" a
# non-match: it contains ".ptphelper" but does not END with it.
CANDIDATES_RAW="$(
  printf '%s\n' "$RAW" \
    | grep -oE '[A-Za-z0-9_.-]+' \
    | awk -v suf="$LABEL_SUFFIX" '
        { s = $0; n = length(s); m = length(suf)
          if (n >= m && substr(s, n - m + 1) == suf) print s
        }' \
    | sort -u
)"

# Build the candidates array without ever expanding "${arr[@]}" while it might
# be empty — bash 3.2 (macOS's stock /bin/bash) raises "unbound variable" for
# that expansion under `set -u` even though `${#arr[@]}` itself is fine (see
# scripts/make-app.sh's TIMESTAMP_FLAG comment for the same trap). Appending
# one at a time from an empty array is safe; only the later expansions need
# the length-guard below.
candidates=()
spared=""
if [ -n "$CANDIDATES_RAW" ]; then
  while IFS= read -r label; do
    if is_kept "$label"; then
      spared="$spared    keeping (--keep): $label
"
      continue
    fi
    candidates+=("$label")
  done <<< "$CANDIDATES_RAW"
fi

echo "==> Scanning system launchd domain for labels ending in '$LABEL_SUFFIX'"
[ -n "$spared" ] && printf '%s' "$spared"
if [ "${#candidates[@]}" -eq 0 ]; then
  echo "==> No matching PTP-helper daemons found. Nothing to do."
  exit 0
fi

echo "==> Found ${#candidates[@]} candidate(s):"
echo
for label in "${candidates[@]}"; do
  # Defense in depth: re-check the suffix right before we do anything with a
  # label, even though the awk filter above already enforced it — a script
  # that can bootout arbitrary system daemons should never trust a filter
  # exactly once. This can only ever fire on a bug in the code above.
  case "$label" in
    *"$LABEL_SUFFIX") ;;
    *)
      echo "    internal error: '$label' does not end in '$LABEL_SUFFIX' — refusing to touch it" >&2
      exit 1
      ;;
  esac

  # `|| true` on every grep here: a label with no currently loaded job (an
  # override-only "disabled services" entry) legitimately has no "state ="
  # line at all, so grep finding nothing is expected, not an error — without
  # this, grep's exit 1 inside the command substitution would trip `set -e`
  # and abort the whole scan on the very first stale entry.
  detail="$(launchctl print "system/$label" 2>/dev/null || true)"
  state="$(printf '%s\n' "$detail" | grep -m1 -E '^\s*state = ' | sed 's/^[[:space:]]*state = //' || true)"
  parent="$(printf '%s\n' "$detail" | grep -m1 -E '^\s*parent bundle identifier = ' | sed 's/^[[:space:]]*parent bundle identifier = //' || true)"
  [ -n "$state" ] || state="unknown (override-only entry, no loaded job)"
  [ -n "$parent" ] || parent="unknown"

  printf '  %s\n      state: %s\n      parent bundle: %s\n' "$label" "$state" "$parent"
done
echo

if [ "$APPLY" -eq 0 ]; then
  echo "==> Dry run — nothing was changed. Re-run with --apply to bootout the above (requires sudo)."
  exit 0
fi

echo "==> --apply: booting out ${#candidates[@]} daemon(s) (requires sudo)"
failures=0
for label in "${candidates[@]}"; do
  case "$label" in
    *"$LABEL_SUFFIX") ;;
    *)
      echo "    REFUSING non-matching label (should be unreachable): $label" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  echo "    sudo launchctl bootout system/$label"
  if sudo launchctl bootout "system/$label"; then
    echo "    removed: $label"
  else
    # Best-effort: a label that only exists as a disabled-services override
    # (no currently loaded job) has nothing to bootout — that's not a failure
    # of this script, just nothing left to do for that entry.
    echo "    (nothing to bootout — likely already unloaded / override-only): $label"
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "==> Done, with $failures label(s) refused above." >&2
  exit 1
fi
echo "==> Done."
