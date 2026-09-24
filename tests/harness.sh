set -euo pipefail
EXPECTED_VERSION=26.9.1
EXPECTED_REVISION=0ea4c5d
TEST_BASE="${TREE_IT_ROOT:-/tmp/opencode/tree-vfs-it}"

new_env() {
  SCENARIO="$1"
  local version revision stamp
  version="$(yazi --version | awk '/Version:/ {print $2; exit}')"
  revision="$(yazi --version | sed -n 's/.*(\([0-9a-f]*\).*/\1/p' | head -1)"
  [[ "$version" == "$EXPECTED_VERSION" && "$revision" == "$EXPECTED_REVISION" ]] || { echo "STOP: expected Yazi $EXPECTED_VERSION @ $EXPECTED_REVISION; found $version @ $revision" >&2; return 2; }
  mkdir -p "$TEST_BASE"
  stamp="${SCENARIO}-$(date +%s)-$$-${RANDOM}"
  DIR="$(mktemp -d "$TEST_BASE/$stamp.XXXXXX")"
  CFG="$DIR/config"; STATE="$DIR/state"; RUN="$DIR/run"; FIXTURE="$DIR/fixture"
  LOG="$STATE/yazi/yazi.log"; SOCK="tvfs-${stamp//[^a-zA-Z0-9_-]/-}"
  SESSION="tree-vfs"
  mkdir -p "$CFG/plugins" "$STATE/yazi" "$RUN" "$FIXTURE/alpha/shared" "$FIXTURE/beta" "$DIR/cache" "$DIR/tmp"
  chmod 700 "$RUN"
  ln -s "$ROOT" "$CFG/plugins/tree-vfs.yazi"
  printf ROOT >"$FIXTURE/root.txt"
  printf A1 >"$FIXTURE/alpha/a1.txt"
  printf DUP >"$FIXTURE/alpha/shared/dup.txt"
  printf B1 >"$FIXTURE/beta/b1.txt"
  if [[ "$SCENARIO" == navigation_deep ]]; then ln -s alpha "$FIXTURE/linked-alpha"; fi
  local style="${TREE_TEST_STYLE:-indent}"
  local yazi_tree=0
  if [[ "$SCENARIO" == setup_no_tree_scheme ]]; then
    yazi_tree=1
    cat >"$CFG/init.lua" <<LUA
assert(vf.tree == nil, "isolated no-vfs config unexpectedly has a tree scheme")
local embedded = os.getenv("YAZI_TREE") == "1"
require("tree-vfs"):setup({ style = "$style", startup = { tree = embedded, preview = not embedded }, filter_mode = "adopt" })
assert(vf.tree ~= nil and vf.tree.default ~= nil, "setup did not create tree.default")
ya.dbg("[tvfs-test] absent-scheme-registered")
LUA
  else
    cat >"$CFG/init.lua" <<LUA
vf.tree = { sibling = { kind = "view", run = "tree-vfs" } }
local embedded = os.getenv("YAZI_TREE") == "1"
require("tree-vfs"):setup({ style = "$style", startup = { tree = embedded, preview = not embedded }, filter_mode = "adopt" })
assert(vf.tree.sibling ~= nil, "tree-vfs setup overwrote the sibling tree domain")
ya.dbg("[tvfs-test] sibling-domain-preserved")
LUA
  fi
  cat >"$CFG/keymap.toml" <<'TOML'
[[mgr.prepend_keymap]]
on = ["t", "t"]
run = "plugin tree-vfs tab_create"
[[mgr.prepend_keymap]]
on = ["t", "v"]
run = "plugin tree-vfs toggle"
[[mgr.prepend_keymap]]
on = ["t", "p"]
run = "plugin tree-vfs preview"
[[mgr.prepend_keymap]]
on = "h"
run = "plugin tree-vfs left"
[[mgr.prepend_keymap]]
on = "l"
run = "plugin tree-vfs right"
[[mgr.prepend_keymap]]
on = "H"
run = "plugin tree-vfs root_up"
[[mgr.prepend_keymap]]
on = "L"
run = "plugin tree-vfs root_down"
[[mgr.prepend_keymap]]
on = "a"
run = "plugin tree-vfs create"
[[mgr.prepend_keymap]]
on = "<C-a>"
run = "plugin tree-vfs -- create --dir"
[[mgr.prepend_keymap]]
on = "A"
run = "plugin tree-vfs bulk_create"
[[mgr.prepend_keymap]]
on = "p"
run = "plugin tree-vfs paste"
[[mgr.prepend_keymap]]
on = "P"
run = "plugin tree-vfs -- paste --force"
[[mgr.prepend_keymap]]
on = "<Enter>"
run = "plugin tree-vfs open"
[[mgr.prepend_keymap]]
on = "f"
run = "plugin tree-vfs filter"
[[mgr.prepend_keymap]]
on = "<Esc>"
run = "plugin tree-vfs escape"
[[mgr.prepend_keymap]]
on = "<C-[>"
run = "plugin tree-vfs escape"
[[mgr.prepend_keymap]]
on = "r"
run = "plugin tree-vfs rename"
[[mgr.prepend_keymap]]
on = "["
run = "tab_switch 0"
[[mgr.prepend_keymap]]
on = "]"
run = "tab_switch 1"
[[mgr.prepend_keymap]]
on = "G"
run = "arrow bot"
[[mgr.prepend_keymap]]
on = "F"
run = "arrow top"
[[mgr.prepend_keymap]]
on = "Z"
run = "plugin tree-vfs preview"
TOML
  printf '\n[[mgr.prepend_keymap]]\non = "X"\nrun = "cd %s"\n' "$FIXTURE" >>"$CFG/keymap.toml"
  cat >"$CFG/yazi.toml" <<'TOML'
[mgr]
ratio = [1, 3, 4]
sort_by = "none"
TOML
  tmux -L "$SOCK" new-session -d -x 120 -y 24 -s "$SESSION" \
    "env YAZI_TREE='$yazi_tree' YAZI_CONFIG_HOME='$CFG' XDG_CACHE_HOME='$DIR/cache' XDG_STATE_HOME='$STATE' XDG_RUNTIME_DIR='$RUN' TMPDIR='$DIR/tmp' TERM=xterm-256color YAZI_LOG=debug yazi '$FIXTURE'; sleep 30"
  local n
  for n in {1..40}; do [[ -f "$LOG" ]] && break; sleep 0.1; done
  wait_log '\[tvfs\] realcwd' || fail "setup/initial cd did not run"
  if [[ "$SCENARIO" == setup_no_tree_scheme ]]; then
    wait_log '\[tvfs-test\] absent-scheme-registered' || fail "setup did not register tree.default without a tree scheme"
    wait_log "\[tvfs\] ReadDir tab=.*root=$FIXTURE" || fail "YAZI_TREE=1 did not enter the newly registered provider View"
  else
    wait_log '\[tvfs-test\] sibling-domain-preserved' || fail "tree.default setup did not preserve a pre-existing sibling VFS domain"
  fi
}
begin_scenario() { new_env "$1"; trap cleanup_env EXIT; }

cleanup_env() {
  local rc=$?
  tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  if [[ "$rc" == 0 && "${TREE_IT_KEEP:-0}" != 1 ]]; then
    if ! rm -rf "$DIR"; then sleep 0.1; rm -rf "$DIR"; fi
  else echo "scenario artifacts: $DIR" >&2; fi
}
fail() { echo "FAIL [$SCENARIO] $* (artifacts $DIR)" >&2; tmux -L "$SOCK" capture-pane -p -t "$SESSION" >"$DIR/pane-fail.txt" 2>/dev/null || true; exit 1; }
wait_log() {
  local pattern="$1" n
  for n in {1..50}; do grep -Eq "$pattern" "$LOG" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
press() { tmux -L "$SOCK" send-keys -t "$SESSION" "$@"; }
type_text() { tmux -L "$SOCK" send-keys -t "$SESSION" -l -- "$1"; }
pane() { tmux -L "$SOCK" capture-pane -p -t "$SESSION" >"$DIR/pane-$1.txt"; }
enter_view() { press t v; wait_log "\[tvfs\] ReadDir tab=.*root=$FIXTURE" || fail "toggle did not enter provider View"; }
assert_log_clean() {
  local unexpected
  unexpected="$(grep -E 'ERROR|Lua runtime failed|stack traceback' "$LOG" | grep -v "Error when running fetcher 'mime.local'" || true)"
  if [[ -n "$unexpected" ]]; then printf '%s\n' "$unexpected" >&2; fail "Yazi log contains provider/runtime errors"; fi
}
finish() { assert_log_clean; echo "PASS [$SCENARIO]"; }
