#!/bin/sh
# One-time setup per clone. Safe to re-run.
#
#   sh scripts/setup.sh                 hooks only
#   sh scripts/setup.sh --sync-main     also install the macOS launchd job that
#                                       keeps local main a mirror of origin/main
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

git config core.hooksPath .githooks
chmod +x .githooks/* scripts/*.sh .claude/hooks/*.sh 2>/dev/null || true
echo "hooks: core.hooksPath -> .githooks"

if grep -rq '{{PROJECT_NAME}}' AGENTS.md CLAUDE.md docs 2>/dev/null; then
    echo "note: {{PROJECT_NAME}} placeholders remain — see README-TEMPLATE.md step 2." >&2
fi

if [ "${1:-}" = --sync-main ]; then
    [ "$(uname)" = Darwin ] || { echo "--sync-main uses launchd (macOS only); on Linux use a cron line: */2 * * * * sh '$repo/scripts/sync-main.sh'" >&2; exit 1; }
    slug=$(basename "$repo" | tr 'A-Z ' 'a-z-')
    label="com.$slug.sync-main"
    plist="$HOME/Library/LaunchAgents/$label.plist"
    sed -e "s#{{LABEL}}#$label#g" -e "s#{{REPO}}#$repo#g" scripts/launchd/sync-main.plist.template > "$plist"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    echo "sync-main: installed $label (remove: launchctl bootout gui/\$(id -u)/$label)"
fi
