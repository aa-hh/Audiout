#!/bin/sh
# GUARD (shared-leak): changes must not re-create audiout-shared's public
# types locally instead of editing the package.
#
#   sh .githooks/guard-shared-leak.sh          staged changes (pre-commit)
#   sh .githooks/guard-shared-leak.sh <base>   commits since merge-base with
#                                              <base> (CI: the PR's diff)
#   exit 0 = pass, 1 = refused or the type list could not be read.
#
# This file is byte-identical in the Mac repo and audiout-remote. Edit both,
# and run scripts/test-guard-shared-leak.sh in each.
#
# Why this exists: SyncProbeCorrelator was hand-copied from audiout-shared
# into a consumer repo and drifted — a byte-identical duplicate sat on this
# repo's main, undetected, because nothing mechanical stopped it. Two checks:
#
#   1. A new, renamed or copied Swift file named after a shared type, or under
#      a directory named after a shared target (ProbeKit/, AudioutProtocol/…).
#   2. A Swift file that declares a shared type's name more times than before:
#      `struct|class|enum|actor|protocol|typealias <Name>`, matched after
#      comments and string literals are blanked, so any attribute, modifier,
#      backtick or line break between the words is still caught.
#
# The type list is never written down here. It is read from audiout-shared at
# the exact revision this repo's Package.resolved pins: every `public`/`open`
# type declared at the top level of its Sources/. Nested types (e.g.
# CompanionProto.TXTKey) are left out: their names are generic enough to
# collide with unrelated local types. Where the pinned revision comes from,
# first hit wins: $AUDIOUT_SHARED_DIR, ~/Projects/audiout-shared, then a bare
# clone of the pin's URL cached in $AUDIOUT_SHARED_CACHE (default
# ~/.cache/audiout-shared-guard), fetched only when the revision is missing.
#
# Known gap: a renamed copy (`struct MySnapshot` with Snapshot's body) passes.

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
cd "$(git rev-parse --show-toplevel)" || exit 1

if [ -n "${1:-}" ]; then
    old_rev=$(git merge-base "$1" HEAD) || { echo "shared-leak guard: no merge-base with $1" >&2; exit 1; }
    new_prefix="HEAD:"
    changes=$(git -c core.quotePath=false diff --name-status -M -C --diff-filter=ACMR "$old_rev" HEAD -- '*.swift')
else
    old_rev=$(git rev-parse -q --verify HEAD)
    new_prefix=":"
    changes=$(git -c core.quotePath=false diff --cached --name-status -M -C --diff-filter=ACMR -- '*.swift')
fi
[ -n "$changes" ] || exit 0

refuse() {
    echo "" >&2
    printf '%s\n' "$@" >&2
    echo "" >&2
    exit 1
}

# One Perl program, three modes:
#   pin                 Package.resolved on stdin -> "<location> <revision>"
#   types FILE...       public top-level type names declared in FILEs
#   decls OLD NEW       declarations in NEW of a name in $SHARED_TYPES that NEW
#                       declares more often than OLD, as "<line>: <source>"
pl='
use strict; use warnings;
my $mode = shift;
if ($mode eq "pin") {
    require JSON::PP;
    my $j = JSON::PP::decode_json(do { local $/; <STDIN> });
    for my $p (@{ $j->{pins} || $j->{object}{pins} || [] }) {
        my $id = lc($p->{identity} || $p->{package} || "");
        next unless $id eq "audiout-shared";
        print(($p->{location} || $p->{repositoryURL}), " ", $p->{state}{revision}, "\n");
        exit 0;
    }
    exit 1;
}
sub slurp { my $f = shift; open(my $h, "<", $f) or return ""; local $/; my $t = <$h>; defined $t ? $t : "" }
sub blank { (my $s = shift) =~ s/[^\n]/ /g; $s }
sub strip {
    my $t = shift;
    $t =~ s{("""(?s:.*?)"""|/\*(?s:.*?)\*/|//[^\n]*|"(?:[^"\\\n]|\\.)*")}{blank($1)}ge;
    $t =~ s{(@\w+(?:\s*\((?:[^()]|\([^()]*\))*\))?)}{blank($1)}ge;
    $t;
}
my $kw = qr/\b(?:struct|class|enum|actor|protocol|typealias)\s+`?([A-Za-z_]\w*)`?/;
if ($mode eq "types") {
    my $mods = qr/(?:public|open|package|internal|fileprivate|private|final|indirect|distributed|nonisolated)/;
    my %seen;
    for my $f (@ARGV) {
        my $t = strip(slurp($f));
        while ($t =~ /((?:\b$mods\s+)*)$kw/g) {
            my ($m, $name, $at) = ($1, $2, $-[0]);
            my $pre = substr($t, 0, $at);
            my $depth = ($pre =~ tr/{//) - ($pre =~ tr/}//);
            print "$name\n" if $depth == 0 && $m =~ /\b(?:public|open)\b/ && !$seen{$name}++;
        }
    }
    exit 0;
}
if ($mode eq "decls") {
    my %shared = map { $_ => 1 } split " ", ($ENV{SHARED_TYPES} || "");
    my ($old, $new) = map { slurp($_) } @ARGV;
    my %before; my $o = strip($old);
    while ($o =~ /$kw/g) { $before{$1}++ if $shared{$1} }
    my $s = strip($new); my @lines = split /\n/, $new, -1; my (%after, %at);
    while ($s =~ /$kw/g) {
        next unless $shared{$1};
        $after{$1}++;
        push @{ $at{$1} }, 1 + (substr($s, 0, $-[1]) =~ tr/\n//);
    }
    for my $n (sort keys %after) {
        next if $after{$n} <= ($before{$n} || 0);
        print "$_: $lines[$_ - 1]\n" for @{ $at{$n} };
    }
    exit 0;
}
exit 2;
'

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# --- The shared type list, from the pinned revision ------------------------
pin=""
for f in $(git ls-files -- '*Package.resolved'); do
    pin=$(git show "${new_prefix}$f" 2>/dev/null | perl -e "$pl" pin) && break
done
[ -n "$pin" ] || refuse "  REFUSED (shared-leak guard): no Package.resolved here pins audiout-shared," \
    "  so the list of its types cannot be read."
location=${pin% *}
revision=${pin#* }

# Git exports GIT_DIR and GIT_INDEX_FILE to a hook run in a linked worktree,
# and they override `git -C`, so calls on the shared repo or the cache drop them.
shared_git() { env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git "$@"; }

shared_repo=""
for d in "${AUDIOUT_SHARED_DIR:-}" "$HOME/Projects/audiout-shared"; do
    if [ -n "$d" ] && shared_git -C "$d" cat-file -e "$revision^{commit}" 2>/dev/null; then
        shared_repo=$d
        break
    fi
done
if [ -z "$shared_repo" ]; then
    cache=${AUDIOUT_SHARED_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/audiout-shared-guard}
    if [ ! -d "$cache" ]; then
        shared_git clone -q --bare "$location" "$cache" 2>/dev/null
    elif ! shared_git -C "$cache" cat-file -e "$revision^{commit}" 2>/dev/null; then
        shared_git -C "$cache" fetch -q "$location" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' 2>/dev/null
    fi
    shared_git -C "$cache" cat-file -e "$revision^{commit}" 2>/dev/null && shared_repo=$cache
fi
[ -n "$shared_repo" ] || refuse "  REFUSED (shared-leak guard): cannot read audiout-shared at the pinned" \
    "  revision $revision (from $location)." \
    "  Fetch it into ~/Projects/audiout-shared, or point AUDIOUT_SHARED_DIR at a" \
    "  clone that has it."

n=0
for f in $(shared_git -C "$shared_repo" ls-tree -r --name-only "$revision" -- Sources | grep '\.swift$'); do
    n=$((n + 1))
    shared_git -C "$shared_repo" show "$revision:$f" > "$tmp/shared.$n.swift"
done
SHARED_TYPES=$(perl -e "$pl" types "$tmp"/shared.*.swift | tr '\n' ' ')
shared_dirs=$(shared_git -C "$shared_repo" ls-tree -d --name-only "$revision" -- Sources/ | sed 's|^Sources/||' | tr '\n' '|')
shared_dirs=${shared_dirs%|}
[ -n "$SHARED_TYPES" ] && [ -n "$shared_dirs" ] || refuse "  REFUSED (shared-leak guard): found no public types in audiout-shared at" \
    "  $revision — the guard's parser no longer matches that code."
export SHARED_TYPES

# --- Check 1: a new, renamed or copied file named after a shared type -----
file_hits=$(printf '%s\n' "$changes" | while IFS='	' read -r status p1 p2; do
    case $status in (A*|C*|R*) ;; (*) continue ;; esac
    path=${p2:-$p1}
    base=$(basename "$path" .swift)
    for t in $SHARED_TYPES; do
        [ "$base" = "$t" ] && { echo "    $path"; continue 2; }
    done
    printf '%s\n' "$path" | grep -Eq "(^|/)($shared_dirs)/" && echo "    $path"
done)
[ -z "$file_hits" ] || refuse "  REFUSED (shared-leak guard): file(s) look like a local copy of an" \
    "  audiout-shared type, not a use of it:" "$file_hits" "" \
    "  Instead: edit the type in ~/Projects/audiout-shared, tag a release, and" \
    "  bump the pin in both consumers — see \"Shared-code changes\" in AGENTS.md."

# --- Check 2: a declaration re-creating a shared type's name --------------
decl_hits=$(printf '%s\n' "$changes" | while IFS='	' read -r status p1 p2; do
    path=${p2:-$p1}
    : > "$tmp/old.swift"
    case $status in
        (M*) [ -n "$old_rev" ] && git show "$old_rev:$p1" > "$tmp/old.swift" 2>/dev/null ;;
        (R*) git show "$old_rev:$p1" > "$tmp/old.swift" 2>/dev/null ;;
    esac
    git show "${new_prefix}$path" > "$tmp/new.swift" 2>/dev/null
    perl -e "$pl" decls "$tmp/old.swift" "$tmp/new.swift" | sed "s|^|    $path:|"
done)
[ -z "$decl_hits" ] || refuse "  REFUSED (shared-leak guard): Swift re-declares a type that belongs to" \
    "  audiout-shared:" "$decl_hits" "" \
    "  Instead: edit the type in ~/Projects/audiout-shared, tag a release, and" \
    "  bump the pin in both consumers — see \"Shared-code changes\" in AGENTS.md." \
    "  ('git commit --no-verify' for a real emergency, as ever.)"

exit 0
