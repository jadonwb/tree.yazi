#!/usr/bin/env bash
# Option A workaround: turn a Yazi cwd-file into a shell-usable real path.
#
# Usage: tools/realcwd.sh [path/to/cwd.txt]
#   Reads the cwd-file (default: out/cwd.txt) and prints the physical path.
#   For a pure view the file contains:
#     tree://default/@d105depthi0//home/jadon/.config/yazi/plugins/tree-vfs.yazi/fixture
#   The encoded auth (`@d105depthi0`) must not contain a `/`; for richer data
#   payloads use the auxiliary real-cwd file (out/realcwd.txt) instead, which
#   is maintained from the prototype's cd state.
set -uo pipefail
R="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
file="${1:-$R/out/cwd.txt}"
cwd="$(cat "$file" 2>/dev/null)"
case "$cwd" in
  tree://*)
    printf '%s' "$cwd" | sed -E 's#^tree://[^/]+/[^/]+/(.*)$#\1#'
    ;;
  *)
    printf '%s' "$cwd"
    ;;
esac
