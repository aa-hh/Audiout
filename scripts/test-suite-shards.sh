#!/bin/bash
# Tests for scripts/lib/suite-shards.sh, the suite split shared by the GitHub
# `tests` workflow and scripts/run-tests.sh, and for the runner's sharded full
# run on the mule.
#
# The last part drives the real runner in a throwaway clone with `swift`,
# `ssh` and `rsync` replaced by stubs. The ssh stub runs the real mule-side
# script on this Mac, against permit files in the scratch folder, so no Swift
# code is compiled or tested and the mule and its permits are never touched.
#
# Usage: scripts/test-suite-shards.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

. "$SCRIPT_DIR/lib/suite-shards.sh"

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
ok() { echo "  ok — $1"; }

# shellcheck disable=SC2086
join() { printf '%s\n' $1 | paste -sd '|' -; }
L1=$(join "$suite_shard_1")
L2=$(join "$suite_shard_2")

# --- a. the flag and regex for each shard ------------------------------------
# Catches: a shard that drops or misjoins a list, a last shard that filters
# instead of skipping, or a one-shard split that is not a full run.
suite_shards_args 1 3
[ "$suite_shards_flag" = "--filter" ] && [ "$suite_shards_regex" = "[./]($L1)\\b" ] \
    && ok "a: shard 1/3 is --filter list 1" || fail "a: shard 1/3 gave $suite_shards_flag ${suite_shards_regex:0:60}"
suite_shards_args 3 3
[ "$suite_shards_flag" = "--skip" ] && [ "$suite_shards_regex" = "[./]($L1|$L2)\\b" ] \
    && ok "a: shard 3/3 is --skip lists 1 and 2" || fail "a: shard 3/3 gave $suite_shards_flag ${suite_shards_regex:0:60}"
suite_shards_args 2 2
[ "$suite_shards_flag" = "--skip" ] && [ "$suite_shards_regex" = "[./]($L1)\\b" ] \
    && ok "a: shard 2/2 is --skip list 1" || fail "a: shard 2/2 gave $suite_shards_flag ${suite_shards_regex:0:60}"
suite_shards_args 1 1
[ -z "$suite_shards_flag" ] && [ -z "$suite_shards_regex" ] \
    && ok "a: shard 1/1 is a full run" || fail "a: shard 1/1 gave '$suite_shards_flag' '$suite_shards_regex'"

# --- b. every listed name is a real suite, and in one list only --------------
# Catches: a renamed or deleted suite left in a list (its shard runs nothing
# for it), or a suite listed twice and run twice.
grep -rhoE '(struct|class|enum|actor) [A-Za-z0-9_]+' "$REPO/AudioutCore/Tests" \
    | awk '{print $2}' | sort -u > "$TMP_DIR/declared"
missing=
for n in $suite_shard_1 $suite_shard_2; do
    grep -qx "$n" "$TMP_DIR/declared" || missing="$missing $n"
done
[ -z "$missing" ] && ok "b: every listed name is declared under AudioutCore/Tests" \
    || fail "b: not declared under AudioutCore/Tests:$missing"
# shellcheck disable=SC2086
dups=$(printf '%s\n' $suite_shard_1 $suite_shard_2 | sort | uniq -d | tr '\n' ' ')
[ -z "$dups" ] && ok "b: no name is in both lists" || fail "b: listed twice: $dups"

# --- c. the workflow runs every shard through the runner ---------------------
# Catches: a matrix that drifts from suite_shards_max, so a shard never runs
# on GitHub, or a workflow that stops passing --shard to the runner.
WF="$REPO/.github/workflows/tests.yml"
grep -qF 'shard: [1, 2, 3]' "$WF" && grep -qF -- '--shard ${{ matrix.shard }}' "$WF" \
    && ok "c: tests.yml runs shards [1, 2, 3] through --shard" \
    || fail "c: tests.yml lacks 'shard: [1, 2, 3]' or '--shard \${{ matrix.shard }}'"
wf_max=$(sed -n 's/.*shard: \[\(.*\)\].*/\1/p' "$WF" | tr -d ' ' | tr ',' '\n' | sort -n | tail -1)
[ "$wf_max" = "$suite_shards_max" ] && ok "c: the matrix's last shard is suite_shards_max ($wf_max)" \
    || fail "c: matrix ends at '$wf_max', suite_shards_max is $suite_shards_max"

# --- d. end to end: the real runner, swift / ssh / rsync stubbed -------------
CLONE="$TMP_DIR/clone"
git clone -q --shared "$REPO" "$CLONE" || { fail "d: git clone failed"; CLONE=; }
if [ -n "$CLONE" ]; then
    # The working-tree copies, so an uncommitted change is what gets tested.
    cp "$SCRIPT_DIR/run-tests.sh" "$CLONE/scripts/run-tests.sh"
    cp "$SCRIPT_DIR"/lib/*.sh "$CLONE/scripts/lib/"
    # The orphan reaper scans the whole machine; nothing to reap here.
    printf '#!/bin/sh\nexit 0\n' > "$CLONE/scripts/reap-orphaned-swift.sh"
    # A warm checkout folder skips the runner's `swift package resolve` step.
    mkdir -p "$CLONE/AudioutCore/.build/checkouts/stub"
    # The mule's home: remote_run cds into audiout-remote-tests.noindex/clone.
    FAKE_HOME="$TMP_DIR/mule-home"
    mkdir -p "$FAKE_HOME/audiout-remote-tests.noindex"
    ln -s "$CLONE" "$FAKE_HOME/audiout-remote-tests.noindex/clone"

    mkdir -p "$TMP_DIR/bin"
    SWIFT_LOG="$TMP_DIR/swift.log"
    SSH_LOG="$TMP_DIR/ssh"
    printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/rsync"
    # printf, not echo: the regexes end in \b, which sh's echo would turn
    # into a backspace. The failure line carries the glyph real swift prints,
    # because remote_run names failed tests only from " Test ... failed after ".
    cat > "$TMP_DIR/bin/swift" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$SWIFT_LOG"
if [ -n "\${SHARD_FAIL_MATCH:-}" ]; then
    case "\$*" in *"\$SHARD_FAIL_MATCH"*)
        echo "✘ Test broken() failed after 0.100 seconds with 1 issue."
        exit 1 ;;
    esac
fi
if [ -n "\${SHARD_NO_SUMMARY:-}" ]; then
    case "\$*" in *"\$SHARD_NO_SUMMARY"*) exit "\${SHARD_NO_SUMMARY_RC:-0}" ;; esac
fi
# Only a run on this Mac lacks --disable-keychain.
if [ -n "\${LOCAL_FAIL:-}" ]; then
    case "\$*" in *--disable-keychain*) ;; *) exit 1 ;; esac
fi
case "\$1" in build) echo "Build complete! (1,00 secs)"; exit 0 ;; esac
case "\$*" in
    *--filter*) echo "Test run with 10 tests in 2 suites passed after 1.000 seconds." ;;
    *--skip*)   echo "Test run with 20 tests in 5 suites passed after 2.000 seconds." ;;
    *)          echo "Test run with 30 tests in 7 suites passed after 3.000 seconds." ;;
esac
exit 0
EOF
    # The last argument is the mule-side script. A run script (REMOTE_EXIT)
    # executes here with its permit files moved into the scratch folder; the
    # permit-table script prints MULE_TABLE; anything else succeeds. A run
    # script matching MULE_REFUSE_MATCH gets exit 98, the mule's "no free
    # permit" answer.
    cat > "$TMP_DIR/bin/ssh" <<EOF
#!/bin/sh
for last; do :; done
# One file per call: the shards' ssh calls run at once, and long scripts
# appended to one shared file can interleave.
mkdir -p "$SSH_LOG"
printf '%s\n' "\$last" > "$SSH_LOG/\$\$"
case "\$last" in
    *REMOTE_EXIT*)
        if [ -n "\${MULE_REFUSE_MATCH:-}" ]; then
            case "\$last" in *"\$MULE_REFUSE_MATCH"*) exit 98 ;; esac
        fi
        script=\$(printf '%s' "\$last" | sed "s|/tmp/audiout-remote-work.lock|$TMP_DIR/mule-lock|g")
        cd "$FAKE_HOME" && exec sh -c "\$script" ;;
    *audiout-remote-work.lock*)
        [ -n "\${MULE_TABLE:-}" ] && printf '%s\n' "\$MULE_TABLE"
        exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TMP_DIR/bin/rsync" "$TMP_DIR/bin/swift" "$TMP_DIR/bin/ssh"

    unset AUDIOUT_TEST_NO_CACHE AUDIOUT_TEST_SHARDS AUDIOUT_TEST_MODE \
          AUDIOUT_TRUST_REMOTE_FAILURE AUDIOUT_TEST_PACKAGE AUDIOUT_TEST_REMOTE_ROOT \
          SHARD_FAIL_MATCH MULE_TABLE SHARD_NO_SUMMARY SHARD_NO_SUMMARY_RC LOCAL_FAIL \
          MULE_REFUSE_MATCH KEEP_STAMPS
    STAMPS="$TMP_DIR/stamps"
    runner() {
        [ -n "${KEEP_STAMPS:-}" ] || rm -rf "$STAMPS"
        rm -rf "$SWIFT_LOG" "$SSH_LOG"
        (cd "$CLONE" && PATH="$TMP_DIR/bin:$PATH" \
            AUDIOUT_TEST_REMOTE_HOST=fake AUDIOUT_TEST_PREFER=remote \
            AUDIOUT_TEST_REMOTE_SLOTS=3 AUDIOUT_TEST_CACHE_DIR="$STAMPS" \
            AUDIOUT_TEST_SLOTS=1 AUDIOUT_TEST_LOCK_FILE="$TMP_DIR/lock" \
            AUDIOUT_NO_HOUSEKEEPING=1 AUDIOUT_TEST_LOG="$TMP_DIR/suite.log" \
            sh scripts/run-tests.sh "$@" 2>&1)
    }
    show() { printf '%s\n' "$1" | sed 's/^/    /'; sed 's/^/    swift /' "$SWIFT_LOG"; }

    P="test --disable-keychain --parallel --skip-build --ignore-lock"

    # Catches: a full mule run that still runs as one process, builds more
    # than once, splits differently from the workflow, takes no mule permit
    # per process, or passes without stamping the full suite green.
    out=$(runner); rc=$?
    want=$(printf '%s\n' "$P --filter [./]($L1)\\b" "$P --filter [./]($L2)\\b" "$P --skip [./]($L1|$L2)\\b" | sort)
    got=$(sed -n '2,$p' "$SWIFT_LOG" | sort)
    if [ "$rc" -eq 0 ] && [ "$(grep -c . "$SWIFT_LOG")" -eq 4 ] \
        && [ "$(sed -n 1p "$SWIFT_LOG")" = "build --build-tests --disable-keychain" ] \
        && [ "$got" = "$want" ]; then
        ok "d: full run builds once, then runs the three shards"
    else
        fail "d: full run rc $rc, calls:"; show "$out"
    fi
    printf '%s\n' "$out" | grep -q 'Test run with 40 tests in 9 suites passed after' \
        && printf '%s\n' "$out" | grep -q ' — 3 shards on fake' \
        && ok "d: full run prints one line summed over the shards" \
        || { fail "d: no combined summary line"; show "$out"; }
    ls "$STAMPS"/*.full >/dev/null 2>&1 && ok "d: full run stamps .full" || fail "d: full run wrote no .full stamp"
    ls "$TMP_DIR"/suite.*.shard* >/dev/null 2>&1 && fail "d: shard logs left behind after the run" \
        || ok "d: the per-run shard files are removed"
    nlock=$(grep -l 'shlock -f' "$SSH_LOG"/* | grep -c .)
    [ "$nlock" -eq 4 ] && ok "d: one mule permit per build and per shard (4)" \
        || fail "d: $nlock mule-side scripts took a permit, expected 4"

    # Catches: sharding onto a mule with one free permit, which would make the
    # shards queue behind each other instead of running at once.
    single() {
        [ "$(grep -c . "$SWIFT_LOG")" -eq 1 ] && [ "$(sed -n 1p "$SWIFT_LOG")" = "$1" ]
    }
    TAB=$'\t'
    out=$(MULE_TABLE="1${TAB}111${TAB}alive${TAB}10${TAB}swift test
2${TAB}222${TAB}alive${TAB}10${TAB}swift test" runner)
    single "test --disable-keychain --parallel" && ok "d: one free mule permit runs one process" \
        || { fail "d: one free mule permit still sharded"; show "$out"; }

    # Catches: the opt-out and flake-hunting mode being sharded anyway.
    out=$(AUDIOUT_TEST_SHARDS=1 runner)
    single "test --disable-keychain --parallel" && ok "d: AUDIOUT_TEST_SHARDS=1 runs one process" \
        || { fail "d: AUDIOUT_TEST_SHARDS=1 still sharded"; show "$out"; }
    out=$(AUDIOUT_TEST_MODE=serial runner)
    single "test --disable-keychain --no-parallel" && ok "d: AUDIOUT_TEST_MODE=serial runs one process" \
        || { fail "d: serial mode still sharded"; show "$out"; }

    # Catches: a filtered run taking the build-then-shard path.
    out=$(runner --filter FooTests)
    single "test --disable-keychain --parallel --filter FooTests" && ok "d: --filter runs one process, no build step" \
        || { fail "d: --filter FooTests was sharded or built"; show "$out"; }

    # Catches: --shard N not turning into that shard's filter, or dropping the
    # arguments after it (the workflow passes compiler flags there).
    out=$(runner --shard 2 --disable-index-store)
    single "test --disable-keychain --parallel --filter [./]($L2)\\b --disable-index-store" \
        && ok "d: --shard 2 runs list 2 with the remaining arguments" \
        || { fail "d: --shard 2 call was wrong"; show "$out"; }

    # Catches: a failing shard reported as a pass, its failure not named, the
    # full suite stamped green, or a passing shard stamped per name rather than
    # under its exact arguments: a later plain --filter is a substring match
    # that reaches other shards' suites, so a per-name stamp skips them unrun.
    out=$(SHARD_FAIL_MATCH="[./]($L2)\\b" runner); rc=$?
    first1=${suite_shard_1%% *}
    h1=$(printf '%s' "--filter [./]($L1)\\b" | shasum -a 256 | awk '{print $1}')
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'shard 2/3 FAILED' \
        && printf '%s\n' "$out" | grep -q 'broken()'; then
        ok "d: a failing shard fails the run and is named"
    else
        fail "d: failing shard: rc $rc"; show "$out"
    fi
    if [ "$(ls "$STAMPS" | grep -c .)" -eq 1 ] && ls "$STAMPS"/*".$h1" >/dev/null 2>&1; then
        ok "d: only the passing listed shard is stamped, under its exact arguments"
    else
        fail "d: stamps after a failing shard:"; ls "$STAMPS" 2>&1 | head -5 | sed 's/^/    /'
    fi
    out=$(KEEP_STAMPS=1 runner --filter "$first1")
    single "test --disable-keychain --parallel --filter $first1" \
        && ok "d: a later plain --filter of a passed shard's suite still runs" \
        || { fail "d: --filter $first1 was skipped after its shard passed"; show "$out"; }

    # Catches: a shard that exits 0 with no summary line crashing the sum or
    # counting as a pass, instead of being no verdict and re-run here in full.
    out=$(SHARD_NO_SUMMARY="[./]($L2)\\b" LOCAL_FAIL=1 runner); rc=$?
    if [ "$rc" -ne 0 ] && ! ls "$STAMPS"/*.full >/dev/null 2>&1 \
        && printf '%s\n' "$out" | grep -q 'shard 1/3: Test run with 10 tests' \
        && printf '%s\n' "$out" | grep -q 'shard 2/3 FAILED — exit 0 with no "Test run with" line' \
        && printf '%s\n' "$out" | grep -q 'shard 2/3 gave no verdict — re-running the full suite' \
        && [ "$(tail -1 "$SWIFT_LOG")" = "test --parallel" ]; then
        ok "d: a shard with no summary line is no verdict and the suite re-runs here"
    else
        fail "d: shard with no summary line: rc $rc"; show "$out"
    fi

    # Catches: a shard whose test process dies without naming a failing test
    # being reported as a build that did not finish (it runs --skip-build, so
    # it never prints "Build complete!"), instead of as no verdict.
    out=$(SHARD_NO_SUMMARY="[./]($L2)\\b" SHARD_NO_SUMMARY_RC=1 LOCAL_FAIL=1 runner); rc=$?
    if [ "$rc" -ne 0 ] && ! ls "$STAMPS"/*.full >/dev/null 2>&1 \
        && printf '%s\n' "$out" | grep -q 'shard 2/3 FAILED — its test process ended (exit 1) without naming a failing test' \
        && ! printf '%s\n' "$out" | grep -q 'build did not finish' \
        && printf '%s\n' "$out" | grep -q 'shard 2/3 gave no verdict — re-running the full suite' \
        && [ "$(tail -1 "$SWIFT_LOG")" = "test --parallel" ]; then
        ok "d: a shard that dies without naming a test is no verdict and the suite re-runs here"
    else
        fail "d: shard that died without naming a test: rc $rc"; show "$out"
    fi

    # Catches: a shard the mule refuses a permit to sending the whole suite
    # back to this Mac, or being dropped from the combined result.
    out=$(MULE_REFUSE_MATCH="[./]($L2)\\b" runner); rc=$?
    if [ "$rc" -eq 0 ] && [ "$(grep -c . "$SWIFT_LOG")" -eq 4 ] \
        && [ "$(grep -c '^test --parallel' "$SWIFT_LOG")" -eq 1 ] \
        && grep -qxF "test --parallel --filter [./]($L2)\\b" "$SWIFT_LOG" \
        && printf '%s\n' "$out" | grep -q 'shard 2/3: no mule permit — running it on this machine.' \
        && printf '%s\n' "$out" | grep -q 'Test run with 40 tests in 9 suites passed after' \
        && ls "$STAMPS"/*.full >/dev/null 2>&1; then
        ok "d: a shard refused a mule permit runs alone here and joins the total"
    else
        fail "d: refused shard: rc $rc"; show "$out"
    fi

    # Catches: a refused shard that fails on this Mac not naming its failing
    # test, or the run blaming the mule for a failure that happened here.
    out=$(MULE_REFUSE_MATCH="[./]($L2)\\b" SHARD_FAIL_MATCH="[./]($L2)\\b" runner); rc=$?
    if [ "$rc" -ne 0 ] \
        && printf '%s\n' "$out" | grep -q 'shard 2/3 FAILED — ran on this machine, swift test exited 1 — 1 test(s) failed: broken()' \
        && printf '%s\n' "$out" | grep -q 'suite: FAILED on this machine.' \
        && ! printf '%s\n' "$out" | grep -q 'FAILED on remote'; then
        ok "d: a refused shard failing here names its test and says where it failed"
    else
        fail "d: refused shard failing here: rc $rc"; show "$out"
    fi
fi

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES suite-shards test(s) FAILED" >&2
    exit 1
fi
echo "all suite-shards tests passed"
