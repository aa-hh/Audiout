#!/bin/bash
# Cloud sessions only: install the Linux Swift toolchain. The Mac checkouts use Xcode.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ] || [ "$(uname -s)" != "Linux" ]; then
  exit 0
fi

SWIFT_VERSION=6.4.1
SWIFT_ROOT=/opt/swift

if [ "$("$SWIFT_ROOT/usr/bin/swift" --version 2>/dev/null | grep -o "swift-$SWIFT_VERSION-RELEASE" || true)" != "swift-$SWIFT_VERSION-RELEASE" ]; then
  rm -rf "$SWIFT_ROOT"
  mkdir -p "$SWIFT_ROOT"
  curl -fsSL --retry 3 \
    "https://download.swift.org/swift-$SWIFT_VERSION-release/ubuntu2404/swift-$SWIFT_VERSION-RELEASE/swift-$SWIFT_VERSION-RELEASE-ubuntu24.04.tar.gz" \
    | tar -xz -C "$SWIFT_ROOT" --strip-components=1
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$SWIFT_ROOT/usr/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi
