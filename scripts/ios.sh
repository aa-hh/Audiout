#!/bin/sh
# Build or test the iOS companion app, on whichever Mac has the capacity.
#
#   scripts/ios.sh build [--root DIR] [extra xcodebuild args]
#   scripts/ios.sh test  [--root DIR] [extra xcodebuild args]
#   scripts/ios.sh shot  [--root DIR] [--out DIR] [--appearance dark|light|both]
#
# WHY THIS EXISTS: run-tests.sh and build.sh route SwiftPM work to the other Mac
# and know nothing about xcodebuild, so every iOS build and every iOS test ran
# here regardless of load — measured at load 22 on this machine while the other
# sat at 1.35 with eight idle cores. This is the xcodebuild half of the same
# routing, reusing lib/remote.sh so there is one answer to "which machine", not
# two that drift.
#
# AUDIOUTER_IOS_REMOTE_ONLY=1 turns the local fallback into a hard stop, for
# when running here is the thing being ruled out. Off by default.
#
# --root exists because `ios/` and this script currently live on DIFFERENT
# branches: the companion app is on claude/companion-app-phase2-ios, which
# predates scripts/lib/ entirely. Point --root at that worktree to use this
# before the two meet on main. After they merge it can be omitted.
#
# THE DESTINATION IS RESOLVED, NEVER NAMED. The two machines carry different
# Xcode versions and therefore different simulator runtimes, so any hard-coded
# `name=iPhone <model>` is wrong on one of them, and goes stale on both at the
# next Xcode update. ios/AGENTS.md already documented a device that stopped
# existing. Ask the machine instead.
#
# AND NOTE WHAT THIS SCRIPT IS NOT. The companion app is VERIFIED on Alec's
# physical iPhone 15 Pro, always — see ios/AGENTS.md. `test` and `shot` below
# drive a resolved simulator, which makes them a compile-and-smoke signal and
# nothing more: device and Simulator builds are separate paths, and the
# Simulator cannot discover a real Mac over Bonjour, raise the local-network
# prompt, or make a speaker play. Never report an iOS change as verified on
# the strength of this script.

set -eu

mode=${1:-}
case "$mode" in
    build|test|shot) shift ;;
    *) echo "usage: scripts/ios.sh build|test|shot [--root DIR] [xcodebuild args...]" >&2; exit 64 ;;
esac

script_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$script_dir/.." && pwd)
if [ "${1:-}" = "--root" ]; then
    [ -n "${2:-}" ] || { echo "ios.sh: --root needs a directory" >&2; exit 64; }
    root=$(cd "$2" && pwd)
    shift 2
fi

out_dir=$(pwd)
appearances="dark light"
if [ "$mode" = shot ]; then
    while [ $# -gt 0 ]; do
        case "$1" in
            --out) [ -n "${2:-}" ] || { echo "ios.sh: --out needs a directory" >&2; exit 64; }
                   out_dir=$2; shift 2 ;;
            --appearance)
                   case "${2:-}" in
                       dark|light) appearances=$2 ;;
                       both)       appearances="dark light" ;;
                       *) echo "ios.sh: --appearance needs dark|light|both" >&2; exit 64 ;;
                   esac
                   shift 2 ;;
            *) echo "ios.sh: unknown shot option '$1'" >&2; exit 64 ;;
        esac
    done
fi

project="ios/AudiouterRemote/AudiouterRemote.xcodeproj"
[ -e "$root/$project" ] || {
    echo "ios.sh: no $project under $root" >&2
    echo "        (the companion app lives on claude/companion-app-phase2-ios — pass --root <that worktree>)" >&2
    exit 66
}

# Newest available iPhone simulator on whichever machine evaluates this. simctl
# groups devices by runtime in ascending version order, so the devices under the
# LAST `-- iOS ...` heading are the newest runtime installed; each heading resets
# the list. Among those, a Pro Max is preferred so a screenshot taken on either
# machine comes back the same size — otherwise the pick is whatever is there.
newest_iphone='xcrun simctl list devices available 2>/dev/null | awk "
    /^-- iOS/       { ok = 1; split(\"\", d); n = 0; next }
    /^--/           { ok = 0 }
    ok && /iPhone/  { sub(/ \\(.*/, \"\"); sub(/^ +/, \"\"); d[++n] = \$0 }
    END             { for (i = 1; i <= n; i++) if (d[i] ~ /Pro Max/) { print d[i]; exit }
                      if (n) print d[n] }
"'

# `shot` — one PNG per appearance in about a second each, against an app that is
# already installed. It exists because the only other thing in this repo that
# produces a screenshot is the four-tab XCUITest, which boots, installs,
# navigates and encodes four images: ~50s for ONE appearance, ~100s for two.
#
# It routes like everything else here. `simctl` drives CoreSimulator fine over a
# plain ssh session — boot, install, launch and screenshot all verified on the
# mule — so the capture happens wherever the work went and the PNGs are rsynced
# back with `remote_fetch`. Which is why the output directory is an ARGUMENT:
# a remote run writes into the synced tree (relative, fetchable), a local run
# writes straight where the caller asked.
#
# WHICH TAB YOU GET: the Connection tab, not Speakers. `-uitest-isolated` (the
# app's only launch argument, RootView.swift:65) skips Bonjour browsing, and
# `RootView` starts on `.connection` and only jumps to Speakers once a session
# goes live. Nothing reaches Speakers from outside the process: the app has no
# URL scheme and no `onOpenURL`, tab selection is plain `@State` (not
# `@SceneStorage`), and `simctl` has no tap subcommand. The only clean fix is a
# launch argument in the app itself.
# razor: filenames stay `speakers-<mode>.png` as specified; upgrade path is a
# tab launch argument in RootView, after which the name becomes true.
#
# $1 = output directory, as the machine that runs this will see it.
shot_cmd_for() {
    printf '%s' "dev=\$($newest_iphone); \
    [ -n \"\$dev\" ] || { echo 'ios.sh: no iPhone simulator installed' >&2; exit 70; }; \
    udid=\$(xcrun simctl list devices available | grep -F \"\$dev (\" | tail -1 \
            | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}'); \
    [ -n \"\$udid\" ] || { echo \"ios.sh: no udid for '\$dev'\" >&2; exit 70; }; \
    echo \"  simulator: \$dev (\$udid)\" >&2; \
    dd=\"\${TMPDIR:-/tmp/}audiouter-ios-shot/$(basename "$root")\"; \
    xcodebuild -project $project -scheme AudiouterRemote \
        -destination \"platform=iOS Simulator,id=\$udid\" \
        -derivedDataPath \"\$dd\" -quiet build || exit 65; \
    app=\$(find \"\$dd/Build/Products\" -maxdepth 2 -type d -name 'AudiouterRemote.app' | head -1); \
    [ -n \"\$app\" ] || { echo 'ios.sh: no AudiouterRemote.app was built' >&2; exit 70; }; \
    bundle=\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"\$app/Info.plist\"); \
    xcrun simctl bootstatus \"\$udid\" -b >/dev/null; \
    xcrun simctl install \"\$udid\" \"\$app\"; \
    xcrun simctl terminate \"\$udid\" \"\$bundle\" >/dev/null 2>&1 || true; \
    xcrun simctl launch \"\$udid\" \"\$bundle\" -uitest-isolated >/dev/null; \
    sleep 2; \
    mkdir -p \"$1\"; \
    for look in $appearances; do \
        xcrun simctl ui \"\$udid\" appearance \"\$look\"; \
        sleep 1; \
        xcrun simctl io \"\$udid\" screenshot \"$1/speakers-\$look.png\" >/dev/null || exit 70; \
    done; \
    xcrun simctl ui \"\$udid\" appearance dark"
}

# `build` needs no device at all, so it never depends on a runtime being
# installed — only on the platform being present.
build_cmd="xcodebuild -project $project -scheme AudiouterRemote \
    -destination 'generic/platform=iOS Simulator' build"

test_cmd="dev=\$($newest_iphone); \
    [ -n \"\$dev\" ] || { echo 'ios.sh: no iPhone simulator installed' >&2; exit 70; }; \
    echo \"  simulator: \$dev\" >&2; \
    xcodebuild -project $project -scheme AudiouterRemote \
        -destination \"platform=iOS Simulator,name=\$dev\" test"

# Where a REMOTE shot writes its PNGs: inside the synced tree, so remote_fetch
# can name them relative to the repo root. The next run's `rsync --delete`
# clears it, which is exactly the housekeeping we want.
shot_remote_out=.shot

# `shot` is the one mode whose command is not machine-independent — it names an
# output directory — so it gets built once per destination.
case "$mode" in
    build) cmd=$build_cmd;                            local_cmd=$build_cmd ;;
    test)  cmd=$test_cmd;                             local_cmd=$test_cmd ;;
    shot)  cmd=$(shot_cmd_for "$shot_remote_out");    local_cmd=$(shot_cmd_for "$out_dir") ;;
esac
if [ $# -gt 0 ]; then
    cmd="$cmd $*"
    local_cmd="$local_cmd $*"
fi

# xcodebuild, not swift: this remote has Xcode but the probe would otherwise ask
# about a Swift toolchain that has nothing to do with the work.
remote_toolchain=xcodebuild
. "$script_dir/lib/remote.sh"

# Opt-in, never the default. The local re-confirm below exists because the two
# Macs carry different Xcode versions and a false refusal costs more than a
# false pass — other callers depend on that. This is for the case where running
# here is the thing being ruled out (a loaded machine), and then a remote that
# cannot be used has to be LOUD rather than quietly satisfied by doing nothing.
remote_only=${AUDIOUTER_IOS_REMOTE_ONLY:-}

# 75 = EX_TEMPFAIL: the work never ran, and that is different from it failing.
refuse_local() {
    echo "ios.sh: AUDIOUTER_IOS_REMOTE_ONLY=1 — $1; refusing to run locally." >&2
    exit 75
}

fetch_shots() {
    mkdir -p "$out_dir"
    for look in $appearances; do
        if remote_fetch "$root" "$shot_remote_out/speakers-$look.png" \
                        "$out_dir/speakers-$look.png"; then
            echo "  wrote $out_dir/speakers-$look.png" >&2
        else
            echo "ios.sh: ran on $remote_host but could not fetch speakers-$look.png" >&2
            exit 70
        fi
    done
}

if remote_wins; then
    if remote_run "$root" "$cmd"; then
        echo "  ran on $remote_host." >&2
        if [ "$mode" = shot ]; then fetch_shots; fi
        exit 0
    elif [ "${remote_status:-}" = "" ]; then
        # Infrastructure, not a verdict — normally fall through and run here.
        if [ -n "$remote_only" ]; then
            refuse_local "$remote_host could not be used at all (see the reason above)"
        fi
    else
        # A remote FAILURE is re-confirmed locally before it blocks anything:
        # the Xcode versions differ, and the expensive error is a false refusal.
        if [ -n "$remote_only" ]; then
            echo "ios.sh: AUDIOUTER_IOS_REMOTE_ONLY=1 — $remote_host failed (exit $remote_status); not re-running here." >&2
            exit "$remote_status"
        fi
        echo "  remote reported failure — re-running here to confirm." >&2
    fi
elif [ -n "$remote_only" ]; then
    refuse_local "no remote was chosen (audiouter.remoteHost unset, or audiouter.testPrefer is 'local')"
fi

cd "$root"
eval "$local_cmd"
