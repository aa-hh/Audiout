#!/bin/sh
# Staged-diff readability self-review (the flow Guard 7 enforces).
#
# Prints the rubric checklist and the staged Swift diff stats, then writes a
# receipt hashed over the staged Swift diff. Guard 7 refuses a Swift commit
# whose staged state has no matching receipt — so the sequence is:
#
#   1. Stage your changes.
#   2. Run this script.
#   3. ACTUALLY READ your staged Swift diff against the checklist
#      (git diff --cached -- '*.swift'). Fix findings, restage.
#   4. Restaging changed the hash — run this script again.
#   5. Commit.
#
# The receipt proves the flow ran against these exact bytes; the review itself
# happens in the committer's head/context. That is deliberate (see
# docs/REVIEW-RUBRIC.md "Mechanics" for why there is no LLM call here).

set -u
git_dir=$(git rev-parse --git-dir 2>/dev/null) || {
    echo "self-review: not inside a git repository" >&2; exit 1; }
repo_root=$(git rev-parse --show-toplevel)

if [ -z "$(git diff --cached --name-only -- '*.swift')" ]; then
    echo "self-review: no staged Swift changes — Guard 7 will not ask for a receipt."
    exit 0
fi

# Identical computation to guard-self-review.sh's — a direct pipe, so the
# bytes hashed here are the bytes the guard re-hashes at commit time.
hash=$(git diff --cached -- '*.swift' | shasum -a 256 | cut -d' ' -f1)

echo ""
echo "  Staged Swift changes:"
git diff --cached --stat -- '*.swift' | sed 's/^/    /'
echo ""
echo "  Review checklist (full rubric: docs/REVIEW-RUBRIC.md):"
echo "    - change-log narration? (\"replaces the old\", dates, \"this session\", hashes)"
echo "    - comments whose claims you did not re-verify? (stale = worse than none)"
echo "    - narration restating the next line? reviewer-speak? hedges?"
echo "    - names that mislead, or journey/type-echo names?"
echo "    - doc comments adding nothing beyond the signature?"
echo "    - orphan task tags? (doc-anchored SPEC/D#/Q#/STABILITY tags STAY)"
echo "    - protected content intact? (trap comments, string literals, test_* seams)"
echo ""
echo "  Read the full diff:  git diff --cached -- '*.swift'"
echo ""

printf '%s\n' "$hash" > "$git_dir/audiout-review-receipt"
echo "  Receipt written for this exact staged state ($(printf '%s' "$hash" | cut -c1-12)…)."
echo "  Restaging any Swift change invalidates it — review and run again."
exit 0
