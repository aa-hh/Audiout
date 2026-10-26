#!/usr/bin/env bash
# Setup script for the Audiout Claude Code cloud environment.
#
# Paste this file's contents into the environment's settings (cloud
# environment menu in the session title bar › Edit › Setup script). It runs
# once when a new session's container starts, before Claude does.
#
# Installs three Claude Code plugins at user scope:
#   - Skills For Real Engineers  mattpocock-skills@mattpocock   (github: mattpocock/skills, public)
#   - Impeccable                 impeccable@impeccable           (github: pbakaus/impeccable, public)
#   - Scope and run              scope-and-run@alec-plugins      (github: aa-hh/scope-and-run-plugin, PRIVATE)
#
# The private marketplace only clones when aa-hh/scope-and-run-plugin is
# added under Repositories in the environment's settings; a saved secret will
# not fetch it. A plugin that fails to install is reported and skipped so
# the session still starts with the others.

set -uo pipefail

# marketplace-repo  marketplace-name  plugin-name
PLUGINS=(
  "mattpocock/skills           mattpocock    mattpocock-skills"
  "pbakaus/impeccable          impeccable    impeccable"
  "aa-hh/scope-and-run-plugin  alec-plugins  scope-and-run"
)

if ! command -v claude >/dev/null 2>&1; then
  echo "cloud-setup: claude CLI not on PATH; no plugins installed" >&2
  exit 0
fi

failed=()
for entry in "${PLUGINS[@]}"; do
  read -r repo marketplace plugin <<<"$entry"
  echo "cloud-setup: $plugin@$marketplace (from $repo)"

  if ! claude plugin marketplace list 2>/dev/null | grep -qE "^\s*>\s*$marketplace\s*$"; then
    if ! claude plugin marketplace add "$repo"; then
      failed+=("$plugin (marketplace $repo did not clone)")
      continue
    fi
  fi

  if ! claude plugin install "$plugin@$marketplace" --scope user; then
    failed+=("$plugin (install failed)")
  fi
done

# scope-and-run's stall timer needs python3.
command -v python3 >/dev/null 2>&1 || echo "cloud-setup: warning: python3 missing; scope-and-run's stall timer will not work" >&2

if ((${#failed[@]})); then
  printf 'cloud-setup: not installed: %s\n' "${failed[@]}" >&2
fi
claude plugin list 2>/dev/null | grep '>' || true
exit 0
