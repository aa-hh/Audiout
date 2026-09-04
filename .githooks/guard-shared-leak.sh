#!/bin/sh
# GUARD (shared-leak): staged changes must not re-create audiout-shared's
# public types locally instead of editing the package.
#
# Called by pre-commit; runnable standalone while iterating on it:
#   sh .githooks/guard-shared-leak.sh    (exit 0 = would pass)
#
# Why this exists: SyncProbeCorrelator was hand-copied from audiout-shared
# into a consumer repo and drifted — a byte-identical duplicate sat on this
# repo's main, undetected, because nothing mechanical stopped it. The rule
# ("don't copy shared code") was already written down; it just had no teeth.
# This gives it teeth. Two checks, both staged-only:
#
#   1. A NEW file whose basename is one of audiout-shared's public type
#      names is almost certainly that type pasted in wholesale.
#   2. A NEW `struct`/`class`/`enum`/`actor` declaration line, ADDED to any
#      staged Swift file (not just a new one), re-declaring one of those
#      names — catches the type dropped into an existing file, not just a
#      dedicated one.
#
# The list below is the public top-level type surface of audiout-shared's
# two products (AudioutProtocol, ProbeKit) as of this writing — verify
# against ~/Projects/audiout-shared/Sources/ if it might have drifted; this
# guard has no way to check that automatically since it's a separate repo.
# Nested types (e.g. CompanionProto.TXTKey, SyncProbeCorrelator.Arrival)
# are deliberately excluded — their names are generic enough to collide
# with unrelated local types, and copying one alone isn't the leak this
# guards against.
shared_types="CompanionCommand CompanionMessage CompanionGoodbyeReason CompanionEnvelope MainOutState DeviceState GroupState AppRouteState SettingsState Snapshot AppIconPayload CompanionAppIcons CompanionProto ProbeAnalysis ProbeAnalysisError ProbeAnalyzer SyncProbe SyncProbeCorrelator"

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

print_instead() {
    echo "" >&2
    echo "  Instead: edit the type in ~/Projects/audiout-shared, tag a" >&2
    echo "  release, and bump the pin in both consumers — see \"Shared-code" >&2
    echo "  changes\" in AGENTS.md." >&2
    echo "" >&2
    echo "  ('git commit --no-verify' for a real emergency, as ever.)" >&2
    echo "" >&2
}

# --- Check 1: a new file named after a shared type ------------------------
added_files=$(git diff --cached --name-only --diff-filter=A -- '*.swift' 2>/dev/null)
file_hits=""
for f in $added_files; do
    base=$(basename "$f" .swift)
    for t in $shared_types; do
        if [ "$base" = "$t" ]; then
            file_hits="$file_hits\n  $f"
        fi
    done
done

# Any new path with a ProbeKit/ or AudioutProtocol/ directory component.
dir_hits=$(printf '%s\n' "$added_files" | grep -E '(^|/)(ProbeKit|AudioutProtocol)/')

if [ -n "$file_hits" ] || [ -n "$dir_hits" ]; then
    echo "" >&2
    echo "  REFUSED (shared-leak guard): staged file(s) look like a local copy" >&2
    echo "  of an audiout-shared type, not a use of it." >&2
    [ -n "$file_hits" ] && printf "%b\n" "$file_hits" >&2
    [ -n "$dir_hits" ] && printf '%s\n' "$dir_hits" | sed 's/^/    /' >&2
    print_instead
    exit 1
fi

# --- Check 2: a new declaration re-creating a shared type's name ----------
added_decls=$(git diff --cached -U0 -- '*.swift' 2>/dev/null | grep -E '^\+[^+]')
decl_hits=""
for t in $shared_types; do
    hit=$(printf '%s\n' "$added_decls" | grep -E "^\+[[:space:]]*(public[[:space:]]+)?(struct|class|enum|actor)[[:space:]]+${t}\b")
    if [ -n "$hit" ]; then
        decl_hits="$decl_hits\n$(printf '%s\n' "$hit" | sed 's/^+/    /')"
    fi
done

if [ -n "$decl_hits" ]; then
    echo "" >&2
    echo "  REFUSED (shared-leak guard): staged Swift re-declares a type that" >&2
    echo "  belongs to audiout-shared:" >&2
    printf "%b\n" "$decl_hits" >&2
    print_instead
    exit 1
fi

exit 0
