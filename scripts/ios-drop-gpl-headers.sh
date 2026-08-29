#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Take the GPL header off the iPhone companion app's own sources.
#
# WHY: the Mac app is GPL because AirPlayEngine vendors OwnTone, and that
# obligation is real. The phone app inherits none of it — it links no engine
# code and reaches the Mac over a network, which makes it no derivative — so
# its GPL headers were a choice rather than an obligation. They have to go
# before the app moves to its own private repo as a paid product, because the
# headers travel with the files.
#
# SCOPE IS THE ENTIRE POINT OF THIS SCRIPT. It rewrites the app's OWN sources
# and nothing else. The roots below are hard-coded, not arguments, so that a
# stray path can never widen it:
#
#   ios/AudioutRemote/AudioutRemote/        the app
#   ios/AudioutRemote/AudioutRemoteTests/
#   ios/AudioutRemote/AudioutRemoteUITests/
#
# It must never reach ios/AudioutRemote/ProbeKit/ — that package is MIT, it is
# shared with the Mac, and its correlator has to stay byte-identical to the
# Mac's copy of the same file. AudioutProtocol/ is likewise already MIT and
# lives outside ios/ entirely. Both are guarded below.
#
# Idempotent: a file already carrying the new notice is left alone, so a
# re-run after adding files does only the new ones.
#
# Usage:  bash scripts/ios-drop-gpl-headers.sh [--dry-run]

set -euo pipefail

readonly OLD='// SPDX-License-Identifier: GPL-2.0-or-later'
readonly NEW='// Copyright (c) 2026 ahh. All rights reserved.'

readonly ROOTS=(
    "ios/AudioutRemote/AudioutRemote"
    "ios/AudioutRemote/AudioutRemoteTests"
    "ios/AudioutRemote/AudioutRemoteUITests"
)

dry_run=false
[[ "${1:-}" == "--dry-run" ]] && dry_run=true

cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

changed=0
skipped=0

for root in "${ROOTS[@]}"; do
    [[ -d "$root" ]] || { echo "missing root: $root" >&2; exit 1; }

    while IFS= read -r file; do
        # Belt and braces: the roots cannot reach these, but a future edit to
        # ROOTS must not be able to either.
        case "$file" in
            */ProbeKit/*|*/AudioutProtocol/*)
                echo "REFUSING (shared package): $file" >&2; exit 1 ;;
        esac

        case "$(head -1 "$file")" in
            "$OLD")
                if $dry_run; then
                    echo "would rewrite  $file"
                else
                    tmp="$(mktemp)"
                    { printf '%s\n' "$NEW"; tail -n +2 "$file"; } > "$tmp"
                    mv "$tmp" "$file"
                    echo "rewrote        $file"
                fi
                changed=$((changed + 1)) ;;
            "$NEW")
                skipped=$((skipped + 1)) ;;
            *)
                echo "left alone (no licence header on line 1): $file" >&2
                skipped=$((skipped + 1)) ;;
        esac
    done < <(find "$root" -type f -name '*.swift' | sort)
done

echo
$dry_run && echo "dry run: $changed file(s) would change, $skipped already correct or unrecognised" \
         || echo "done: $changed file(s) rewritten, $skipped already correct or unrecognised"
