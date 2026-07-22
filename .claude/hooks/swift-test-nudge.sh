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
# Non-run/utility invocations (--help, --list-tests) pass through untouched.
# Wired up in .claude/settings.json (PreToolUse → Bash).

input=$(cat)
cmd=$(printf '%s' "$input" | /usr/bin/python3 -c 'import sys,json; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)

# Not a `swift test` invocation → allow silently.
printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])swift[[:space:]]+test([[:space:]]|$)' || exit 0

# Allowed forms: filtered, explicit parallel, utility flags, or the serial escape.
if printf '%s' "$cmd" | grep -Eq -- '--filter|--parallel|--list-tests|--help|--version|AIRPLAY_SERIAL_TEST=1'; then
    exit 0
fi

# Bare `swift test` → deny with guidance (agent self-corrects in one step).
reason='Bare `swift test` runs all 874 tests serially (~110s) and is the slow path this repo avoids. Choose one:
  • swift test --filter <Suite>   → fast inner loop; scope to the suite(s) you changed, e.g. swift test --filter MixerWindowControllerTests
  • swift test --parallel         → the full run when you actually need it (~70s)
The full suite is enforced at commit (.githooks/pre-commit Guard 4), so filtering in the loop is safe — it cannot miss coverage. If you truly need a serial full run: AIRPLAY_SERIAL_TEST=1 swift test'

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$reason" | /usr/bin/python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"
exit 0
