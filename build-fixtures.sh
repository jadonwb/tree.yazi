#!/usr/bin/env bash
# Build the isolated fixture tree and reset prototype runtime state.
# Everything stays under the prototype root; the real ~/.config/yazi is never touched.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

rm -rf "$ROOT/fixture" "$ROOT/state" "$ROOT/out"
mkdir -p "$ROOT/fixture/alpha/shared" \
         "$ROOT/fixture/beta/shared" \
         "$ROOT/fixture/delta" \
         "$ROOT/fixture/gamma" \
         "$ROOT/state" \
         "$ROOT/out" \
         "$ROOT/out/logs" \
         "$ROOT/xdg/cache" "$ROOT/xdg/state" "$ROOT/xdg/run" "$ROOT/xdg/tmp"

printf 'ROOT'      > "$ROOT/fixture/root.txt"
printf 'ALPHA-A1'  > "$ROOT/fixture/alpha/a1.txt"
printf 'DUP-ALPHA' > "$ROOT/fixture/alpha/shared/dup.txt"
printf 'BETA-B1'   > "$ROOT/fixture/beta/b1.md"
printf 'DUP-BETA'  > "$ROOT/fixture/beta/shared/dup.txt"
printf 'GAMMA-G1'  > "$ROOT/fixture/gamma/g1.bin"

# Expansion state is a plain newline-separated set of absolute real dir paths.
: > "$ROOT/state/expanded"

echo "fixtures built under $ROOT/fixture"
find "$ROOT/fixture" | sort
