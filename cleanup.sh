#!/usr/bin/env bash
# Kill any leftover prototype yazi processes and drop its runtime sockets.
# Scoped to processes launched with the prototype cwd-file/fixture paths.
set -uo pipefail
R="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

pkill -f "$R/out/cwd.txt" 2>/dev/null || true
pkill -f "yazi .*$R/fixture" 2>/dev/null || true
sleep 0.3
rm -rf "$R/xdg/run"/* 2>/dev/null || true

echo "cleanup: remaining prototype yazi processes:"
pgrep -af "$R" | grep -v cleanup.sh || true
