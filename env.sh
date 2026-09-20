# Shared isolated environment for the prototype. Source, never execute.
# All XDG/config/state/runtime paths live below the prototype root.
R="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$R/xdg/cache" "$R/xdg/state" "$R/xdg/run" "$R/xdg/tmp" "$R/out/logs" "$R/state"

export YAZI_CONFIG_HOME="$R/config"
export XDG_CACHE_HOME="$R/xdg/cache"
export XDG_STATE_HOME="$R/xdg/state"
export XDG_RUNTIME_DIR="$R/xdg/run"
export TMPDIR="$R/xdg/tmp"
export TERM="${TERM:-xterm-256color}"
export YAZI_LOG=debug

LOG="$R/xdg/state/yazi/yazi.log"
