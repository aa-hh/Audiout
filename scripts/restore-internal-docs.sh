#!/bin/bash
# Brings back the internal docs (handoffs, .scratch/, dev/notes/, docs/plans/,
# docs/notes/, PROGRESS.md, docs-delta.md) that merging the commit "Keep
# internal docs off GitHub" deleted from this checkout. They are gitignored
# since that commit, so the restored copies stay local and never get pushed.
# Never overwrites a file that already exists.
#
# Run once in the main checkout after sync-main fast-forwards past that
# commit, and in any worktree or clone after it merges main.
#
# Usage: bash scripts/restore-internal-docs.sh
set -euo pipefail

[ "$#" -eq 0 ] || { echo "usage: bash scripts/restore-internal-docs.sh" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)"

commit=$(git log -1 --format=%H --grep='^Keep internal docs off GitHub$' HEAD)
if [ -z "$commit" ]; then
    echo "restore-internal-docs: HEAD does not contain the removal commit yet; nothing to restore" >&2
    exit 1
fi

restored=0
while IFS= read -r -d '' f; do
    [ -e "$f" ] && continue
    mkdir -p "$(dirname "$f")"
    git cat-file blob "$commit^:$f" > "$f"
    restored=$((restored + 1))
done < <(git ls-tree -r -z --name-only "$commit^" | git check-ignore -z --no-index --stdin)

echo "restore-internal-docs: restored $restored file(s) from ${commit:0:8}^"
