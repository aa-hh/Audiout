#!/bin/bash
# Installs the private scope-and-run plugin (aa-hh/scope-and-run-plugin) at user scope.
# The environment setup script runs before git access to private repos exists, so
# the clone fails there; by SessionStart it works. Idempotent; never fails the session.
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

command -v claude >/dev/null 2>&1 || { echo "session-start: claude CLI not on PATH; skipping scope-and-run" >&2; exit 0; }

if claude plugin list 2>/dev/null | grep -q 'scope-and-run@alec-plugins'; then
  echo "session-start: scope-and-run already installed"
  exit 0
fi

for attempt in 1 2 3; do
  if claude plugin marketplace add aa-hh/scope-and-run-plugin \
     && claude plugin install scope-and-run@alec-plugins --scope user; then
    echo "session-start: scope-and-run installed"
    exit 0
  fi
  sleep $((attempt * 3))
done

echo "session-start: scope-and-run NOT installed (marketplace clone or install failed)" >&2
exit 0
