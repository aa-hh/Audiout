#!/usr/bin/env bash
# Tests for .githooks/guard-shared-leak.sh. Builds a stand-in audiout-shared
# and a throwaway consumer repo pinning it, stages each known way around the
# guard, and expects a refusal; the controls expect a pass. One case reads the
# real pin from this repo's Package.resolved, so it needs ~/Projects/
# audiout-shared at that revision or network access to clone it.
#
# Usage: scripts/test-guard-shared-leak.sh

set -uo pipefail   # deliberately NOT -e: a case failing must not stop the rest

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$REPO/.githooks/guard-shared-leak.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { echo "  ok — $1"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export AUDIOUT_SHARED_CACHE="$TMP_DIR/cache"
unset AUDIOUT_SHARED_DIR

# --- Stand-in audiout-shared ----------------------------------------------
SHARED="$TMP_DIR/shared"
mkdir -p "$SHARED/Sources/AudioutProtocol" "$SHARED/Sources/ProbeKit"
git -C "$SHARED" init -q -b main
cat > "$SHARED/Sources/AudioutProtocol/Snapshot.swift" <<'EOF'
import Foundation

/// The whole state.
@available(macOS 14, *)
public struct Snapshot: Codable {
    public struct Inner {}
    public let a: Int
}

public
enum StageLook { case a }

struct InternalOnly {}
EOF
cat > "$SHARED/Sources/ProbeKit/SyncProbe.swift" <<'EOF'
public final class SyncProbe {}
EOF
git -C "$SHARED" add -A && git -C "$SHARED" commit -qm one
REV1=$(git -C "$SHARED" rev-parse HEAD)
echo 'public struct NewThing {}' > "$SHARED/Sources/ProbeKit/NewThing.swift"
git -C "$SHARED" add -A && git -C "$SHARED" commit -qm two
REV2=$(git -C "$SHARED" rev-parse HEAD)

resolved() {  # resolved <revision>
  cat <<EOF
{
  "pins" : [
    {
      "identity" : "audiout-shared",
      "kind" : "remoteSourceControl",
      "location" : "$SHARED",
      "state" : { "revision" : "$1", "version" : "0.0.1" }
    }
  ],
  "version" : 2
}
EOF
}

# --- Throwaway consumer ----------------------------------------------------
C="$TMP_DIR/consumer with space"
mkdir -p "$C/App"
git -C "$C" init -q -b main
resolved "$REV1" > "$C/Package.resolved"
printf 'struct Existing {}\n' > "$C/App/Existing.swift"
printf 'let old = 1\n' > "$C/App/Old.swift"
printf 'enum Local {\n    struct Snapshot {}\n}\n' > "$C/App/Nested.swift"
git -C "$C" add -A && git -C "$C" commit -qm base
BASE=$(git -C "$C" rev-parse HEAD)

reset() { git -C "$C" checkout -q main; git -C "$C" reset -q --hard "$BASE"; git -C "$C" clean -qfd; }
run_guard() { ERR="$(cd "$C" && sh "$GUARD" "$@" 2>&1 >/dev/null)"; RC=$?; }
expect() {  # expect <label> <rc> [stderr-substring]
  if [ "$RC" -ne "$2" ]; then fail "$1: exit $RC, wanted $2 ($ERR)"; return; fi
  if [ -n "${3:-}" ] && ! printf '%s' "$ERR" | grep -qF -- "$3"; then
    fail "$1: stderr lacks '$3' ($ERR)"; return
  fi
  ok "$1"
}
write() { printf '%s\n' "$2" > "$C/$1"; git -C "$C" add -- "$1"; }
refused() {  # refused <label> <swift source>: staged as a new App/Leak.swift
  reset; write App/Leak.swift "$2"; run_guard; expect "$1" 1 "re-declares"
}

echo "Declarations the guard must refuse:"
refused "plain struct" 'struct Snapshot {}'
refused "attribute with arguments" '@available(iOS 17, *) struct Snapshot {}'
refused "@objc(Name) class" '@objc(Foo) class SyncProbe: NSObject {}'
refused "final class (modifier, Mac copy missed it)" 'final class SyncProbe {}'
refused "@MainActor struct (attribute, Mac copy missed it)" '@MainActor struct Snapshot {}'
refused "distributed actor" 'distributed actor Snapshot {}'
refused "protocol" 'protocol Snapshot {}'
refused "typealias" 'typealias Snapshot = Int'
refused "backticked name" 'struct `Snapshot` {}'
refused "declaration split across lines" 'public
struct
 Snapshot {}'
refused "type split over 'public' newline in the package (StageLook)" 'enum StageLook {}'
reset; printf 'struct Existing {}\nstruct Snapshot {}\n' > "$C/App/Existing.swift"; git -C "$C" add -A
run_guard; expect "declaration added to an existing file" 1 "App/Existing.swift:2"

echo "Files the guard must refuse:"
reset; write App/SyncProbe.swift 'let x = 1'; run_guard; expect "new file named after a type" 1 "App/SyncProbe.swift"
reset; git -C "$C" mv App/Old.swift App/SyncProbe.swift; run_guard; expect "rename onto a type's name" 1 "App/SyncProbe.swift"
reset; mkdir -p "$C/ProbeKit"; git -C "$C" mv App/Old.swift ProbeKit/Old.swift; run_guard; expect "rename into ProbeKit/" 1 "ProbeKit/Old.swift"
reset; cp "$C/App/Nested.swift" "$C/App/Copied.swift"; git -C "$C" add -A; run_guard; expect "copy of a file holding a declaration" 1 "App/Copied.swift"

echo "The list follows the pin:"
reset; write App/Leak.swift 'struct NewThing {}'; run_guard; expect "type absent at the pinned revision passes" 0
reset; resolved "$REV2" > "$C/Package.resolved"; git -C "$C" add Package.resolved
write App/Leak.swift 'struct NewThing {}'; run_guard; expect "same type refused once the pin is bumped" 1 "NewThing"
reset; resolved 0123456789012345678901234567890123456789 > "$C/Package.resolved"; git -C "$C" add Package.resolved
write App/Leak.swift 'struct Fine {}'; run_guard; expect "unreadable pinned revision refuses" 1 "cannot read audiout-shared"
reset; cp "$REPO/AudioutCore/Package.resolved" "$C/Package.resolved"; git -C "$C" add Package.resolved
write App/Leak.swift 'public final class StageLookState {}'; run_guard
expect "real pin: a type the old hand list lacked (StageLookState)" 1 "StageLookState"

echo "Commit range (CI) mode:"
reset; git -C "$C" checkout -q -b leak; write App/Leak.swift 'protocol Snapshot {}'; git -C "$C" commit -qm leak
run_guard main; expect "leak committed on a branch, checked against main" 1 "re-declares"
reset; git -C "$C" checkout -q -b clean; write App/Fine.swift 'struct Fine {}'; git -C "$C" commit -qm fine
run_guard main; expect "clean branch against main passes" 0

echo "Controls that must pass:"
reset; run_guard; expect "nothing staged" 0
reset; write App/Fine.swift '// struct Snapshot lives in audiout-shared.
/* class SyncProbe */
let s = "struct Snapshot {}"
extension Snapshot {}
struct SnapshotView { let s: Snapshot }
typealias Shot = Snapshot'
run_guard; expect "comments, strings, extensions, uses and longer names" 0
reset; printf 'enum Local {\n    struct Snapshot {}\n    static let x = 1\n}\n' > "$C/App/Nested.swift"; git -C "$C" add -A
run_guard; expect "file that already declared the name, edited elsewhere" 0
reset; git -C "$C" mv App/Nested.swift App/Moved.swift; run_guard; expect "rename of a file that already declared the name" 0
reset; write App/Fine.swift 'struct InternalOnly {}
struct Inner {}'; run_guard; expect "internal and nested shared types are not listed" 0

echo
if [ "$FAILURES" -eq 0 ]; then echo "All shared-leak guard cases passed."; else echo "$FAILURES case(s) failed." >&2; exit 1; fi
