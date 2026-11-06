#!/bin/bash
# Cloud-session setup that has to happen after the environment's setup script:
#   1. switch on this checkout's pre-commit guards (a fresh clone has none);
#   2. put the setup script's Swift toolchain on PATH for the session's shells,
#      which do not read ~/.bashrc;
#   3. install the private scope-and-run plugin at user scope. The setup
#      script's clone of aa-hh/scope-and-run-plugin failed on 2026-10-26 while
#      the same clone worked once the session was up, so it is retried here.
# Idempotent; never fails the session.
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  git -C "$CLAUDE_PROJECT_DIR" config core.hooksPath .githooks \
    && echo "session-start: pre-commit guards on" \
    || echo "session-start: could not set core.hooksPath; commits run unguarded" >&2
fi

if [ -x /opt/swift/usr/bin/swift ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo 'export PATH="/opt/swift/usr/bin:$PATH"' >> "$CLAUDE_ENV_FILE"
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
