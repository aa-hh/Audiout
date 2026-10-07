#!/bin/sh
# Keeps local main a fast-forward mirror of origin/main. Main takes changes
# only through GitHub's merge queue, so nothing local ever needs to commit on
# it; this runs every 2 minutes from launchd
# (scripts/launchd/sync-main.plist.template, installed by scripts/setup.sh) so main follows a merge
# within minutes, with no session involved.
#
# Never merges, never discards anything: a dirty main checkout, or a local
# main holding commits origin lacks, is left alone with one line on stderr.
# Silent when there is nothing to do. Exits 0 except on a usage error, so a
# timer run never reports failure for an offline fetch.
#
# Usage: sh scripts/sync-main.sh
set -eu

[ "$#" -eq 0 ] || { echo "usage: sh scripts/sync-main.sh" >&2; exit 2; }

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
git fetch -q --prune origin 2>/dev/null || exit 0
git worktree prune || true

git rev-parse -q --verify refs/remotes/origin/main > /dev/null || exit 0
target=$(git rev-parse origin/main)
current=$(git rev-parse -q --verify refs/heads/main || true)
[ "$current" = "$target" ] && exit 0

if [ "$(git symbolic-ref -q --short HEAD || true)" = main ]; then
    if [ -n "$(git status --porcelain)" ]; then
        echo "sync-main: left main alone: the checkout at $repo has uncommitted changes" >&2
        exit 0
    fi
    if git merge -q --ff-only origin/main 2>/dev/null; then
        echo "sync-main: main -> $(git rev-parse --short HEAD)"
    else
        echo "sync-main: left main alone: it has commits origin/main lacks" >&2
    fi
    exit 0
fi

# main checked out in another worktree: moving the ref under it would leave
# that worktree's files behind its HEAD.
if git worktree list --porcelain | grep -qx 'branch refs/heads/main'; then
    echo "sync-main: left main alone: it is checked out in another worktree" >&2
    exit 0
fi
if [ -z "$current" ] || git merge-base --is-ancestor main origin/main; then
    git update-ref refs/heads/main "$target"
    echo "sync-main: main -> $(git rev-parse --short main)"
else
    echo "sync-main: left main alone: it has commits origin/main lacks" >&2
fi
exit 0
