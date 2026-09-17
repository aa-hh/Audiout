#!/bin/bash
# Build the G2b aggregate-device spike CLI. No sudo, writes only into ./build.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -O aggtool.swift -o build/aggtool -framework CoreAudio -framework AudioToolbox
echo "built: $(pwd)/build/aggtool"
