#!/bin/sh
# PreToolUse (Bash) nudge: steer `swift test` toward the fast, scoped inner
# loop. A BARE `swift test` runs all 874 tests serially (~110s) every build-test
# cycle — the cost this repo kept paying. This bounces only that bare form and
# tells the agent how to proceed; it never stops a legitimate run:
#   - swift test --filter <Suite>   → the fast inner loop (allowed)
#   - swift test --parallel         → the deliberate full run, ~70s (allowed)
#   - AIRPLAY_SERIAL_TEST=1 swift test → escape for a genuine serial run (allowed)
# Coverage is guaranteed elsewhere: .githooks/pre-commit (Guard 4) runs the full
# `swift test --parallel` at commit, so a too-narrow filter can never let a
# regression land — it only costs one extra fix cycle at commit time.
#
# Matching is delegated to swift_test_match.py, which only considers text the
# shell would actually treat as command words (quoted strings, heredoc bodies,
# and comments are excluded) — NOT a naive substring/regex match against the
# raw command. An earlier naive-regex version matched "swift test" appearing
# ANYWHERE in the command (e.g. `grep "swift test" file`) and caused a flood of
# false-positive denials (2026-07-22 incident) — see the docstring in
# swift_test_match.py for the full postmortem. If the matcher errors for any
# reason it fails toward ALLOW, never DENY — a bug here must never be able to
# block an unrelated command.
#
# Wired up in .claude/settings.json (PreToolUse → Bash).

input=$(cat)
hook_dir=$(dirname "$0")

cmd=$(printf '%s' "$input" | /usr/bin/python3 -c 'import sys,json; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)
[ -z "$cmd" ] && exit 0

verdict=$(printf '%s' "$cmd" | /usr/bin/python3 "$hook_dir/swift_test_match.py" 2>/dev/null)
[ "$verdict" = "DENY" ] || exit 0

# Bare `swift test` → deny with guidance (agent self-corrects in one step).
reason='Bare `swift test` runs all 874 tests serially (~110s) and is the slow path this repo avoids. Choose one:
  • swift test --filter <Suite>   → fast inner loop; scope to the suite(s) you changed, e.g. swift test --filter MixerWindowControllerTests
  • swift test --parallel         → the full run when you actually need it (~70s)
The full suite is enforced at commit (.githooks/pre-commit Guard 4), so filtering in the loop is safe — it cannot miss coverage. If you truly need a serial full run: AIRPLAY_SERIAL_TEST=1 swift test'

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$reason" | /usr/bin/python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"
exit 0
