#!/usr/bin/env bash
# Gate 0: verify the installed build registers the View service and resolves a
# scheme/Url-source. Stops early (exit 2) if the mechanism is absent.
set -euo pipefail
R="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$R/env.sh"

rm -f "$LOG"

cat > "$R/out/compat.json" <<JSON
{
  "argv": ["yazi", "--cwd-file", "$R/out/cwd.txt", "$R/fixture"],
  "env": {
    "YAZI_CONFIG_HOME": "$R/config",
    "XDG_CACHE_HOME": "$R/xdg/cache",
    "XDG_STATE_HOME": "$R/xdg/state",
    "XDG_RUNTIME_DIR": "$R/xdg/run",
    "TMPDIR": "$R/xdg/tmp",
    "TERM": "$TERM",
    "YAZI_LOG": "debug"
  },
  "keys": ["t", "sleep:0.8", "q"],
  "delay": 0.4,
  "out": "$R/out/compat.raw"
}
JSON

yazi --version > "$R/out/debug.txt" 2>&1 || true

python3 "$R/harness/drive.py" "$R/out/compat.json" >/dev/null 2>&1 || true

if [ ! -f "$LOG" ]; then
  echo "STOP: no yazi log at $LOG (launch failed)"
  exit 2
fi

if ! grep -q '\[tvfs\] vf=' "$LOG"; then
  echo "WARN: dynamic vf global probe missing"
fi
grep -o '\[tvfs\] vf=[a-z]*' "$LOG" | tail -1
if ! grep -q '\[tvfs\] url-ok=true' "$LOG"; then
  echo "STOP: View/Url-source unsupported by installed build"
  grep -E '\[tvfs\]|VFS service' "$LOG" || true
  exit 2
fi
if grep -q 'No such VFS service: tree' "$LOG"; then
  echo "STOP: tree view service not registered"
  exit 2
fi
if ! grep -q '\[tvfs\] enter' "$LOG"; then
  echo "WARN: enter action did not log (keybinding not delivered?)"
fi
if ! grep -q '\[tvfs\] ReadDir' "$LOG"; then
  echo "STOP: ReadDir never called -> provider registration/contract wrong"
  grep -E '\[tvfs\]|WARN|ERROR|error' "$LOG" | tail -40 || true
  exit 2
fi

echo "GATE 0 PASS"
grep -E '\[tvfs\]' "$LOG" | sed 's/^/  /'
