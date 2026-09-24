#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SELF="$HERE/$(basename "$0")"
SCENARIOS=(setup_no_tree_scheme modes_toggle_preview navigation_deep navigation_native_hover navigation_view_exit filter_live tabs_view_clone create_nested paste_nested rename_nested remove_nested external_hover_preview)
source "$HERE/harness.sh"
source "$HERE/scenarios_modes.sh"
source "$HERE/scenarios_setup.sh"
source "$HERE/scenarios_navigation.sh"
source "$HERE/scenarios_filter.sh"
source "$HERE/scenarios_tabs.sh"
source "$HERE/scenarios_create_paste.sh"
source "$HERE/scenarios_rename.sh"
source "$HERE/scenarios_remove.sh"
source "$HERE/scenarios_external.sh"

if [[ "${1:-}" == "--list" ]]; then printf '%s\n' "${SCENARIOS[@]}"; exit 0; fi
jobs=1
if [[ "${1:-}" == "--jobs" ]]; then jobs="${2:-}"; [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo "invalid --jobs value" >&2; exit 2; }; shift 2; fi
if (( $# == 0 )); then set -- "${SCENARIOS[@]}"; fi
for name in "$@"; do
  found=false; for known in "${SCENARIOS[@]}"; do [[ "$name" == "$known" ]] && found=true; done
  $found || { echo "unknown scenario: $name" >&2; exit 2; }
done
if (( jobs == 1 )); then
  for name in "$@"; do "scenario_$name"; done
  exit 0
fi
pids=(); failed=0
for name in "$@"; do
  "$SELF" "$name" & pids+=("$!")
  if (( ${#pids[@]} >= jobs )); then
    finished=""
    wait -n -p finished || failed=1
    next=(); for pid in "${pids[@]}"; do [[ "$pid" == "$finished" ]] || next+=("$pid"); done
    pids=("${next[@]}")
  fi
done
while (( ${#pids[@]} )); do
  finished=""; wait -n -p finished || failed=1
  next=(); for pid in "${pids[@]}"; do [[ "$pid" == "$finished" ]] || next+=("$pid"); done
  pids=("${next[@]}")
done
exit "$failed"
