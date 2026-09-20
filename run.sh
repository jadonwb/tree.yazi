#!/usr/bin/env bash
# Manual, isolated launcher. Never reads ~/.config/yazi, toml user fixtures or tmux.
set -euo pipefail
R="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$R/xdg/cache" "$R/xdg/state" "$R/xdg/run" "$R/xdg/tmp" "$R/out"
export YAZI_CONFIG_HOME="$R/config" \
       XDG_CACHE_HOME="$R/xdg/cache" \
       XDG_STATE_HOME="$R/xdg/state" \
       XDG_RUNTIME_DIR="$R/xdg/run" \
       TMPDIR="$R/xdg/tmp" \
       TERM="${TERM:-xterm-256color}" \
       YAZI_LOG=debug
exec yazi --cwd-file="$R/out/cwd.txt" "$R/fixture"
