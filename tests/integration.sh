#!/usr/bin/env bash
# Reusable integration harness for tree.yazi.
#
# Creates isolated Yazi configs (an isolated YAZI_CONFIG_HOME that links the
# checked-out plugin), deterministic filesystem fixtures, an isolated state
# dir, an isolated tmux server and an isolated XDG runtime dir, then drives the
# installed Yazi through tmux and asserts on pane text, debug logs, and
# filesystem state.
#
# Usage:
#   tests/integration.sh                 # run every scenario
#   tests/integration.sh startup filter  # run selected scenarios
#   tests/integration.sh --list          # list scenario names
#
# Environment:
#   TREE_IT_ROOT   base directory for temporary state (default /tmp/opencode/tree-it)
#   TREE_IT_KEEP=1 keep the temporary root even on success
#
# Nothing here touches the user's real config, plugin fixtures, or tmux
# sessions: every session runs on a private tmux server (-L) and every path
# lives under TREE_IT_ROOT.

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
ROOT_BASE="${TREE_IT_ROOT:-/tmp/opencode/tree-it}"
STAMP="$(date +%s)-$$-${RANDOM}"
ROOT="$ROOT_BASE/$STAMP"
SOCK="tree-it-$STAMP"
KEEP="${TREE_IT_KEEP:-0}"

COLS=110
ROWS=32

SCENARIOS=(
	startup
	expand_collapse
	deep_expand_collapse
	symlink_noexpand
	reroot
	filter
	filter_adopt
	filter_suspend
	filter_clear
	rename
	rename_caret
	rename_deep
	rename_dir_deep
	overwrite
	create
	create_overwrite
	create_collisions
	paste
	cut_paste
	remove_trash
	remove_delete
	remove_dir_trash
	remove_multi
	remove_hovered_elsewhere_preserved
	remove_hovered_root_fallback
	remove_subtree_inside_fallback
	remove_filtered_unrelated
	cd_return_restores
	cd_return_new_root
	home_roundtrip
	reroot_roundtrip
	back_forward
	multitab_isolated
	toggle_roundtrip
	toggle_multitab
	tab_mode_independent
	tab_preview_local
	tab_inherit_new
	tab_rapid_switch
	tab_filter_local
	tab_sort_local
	cross_tab_remove_prunes_saved
	cross_tab_rename_rekeys_saved
	cross_tab_move_prunes_saved
	background_cd_tracking
	tab_close_prunes_state
	toggle_filter
	filter_roundtrip
	rename_root_roundtrip
	remove_root_while_away
	startup_tracking_clean
	cleanup
)

# Per-scenario state (set by new_env).
SCENARIO=""
SESSION=""
DIR=""
CFG=""
STATE=""
FIXTURE=""
RUN=""
LOG=""
CWD_FILE=""

# ---------------------------------------------------------------------------
# Reporting / lifecycle
# ---------------------------------------------------------------------------

fail() {
	printf 'FAIL: [%s] %s\n' "${SCENARIO:-harness}" "$*" >&2
	if [ -n "${DIR:-}" ]; then
		tmux -L "$SOCK" capture-pane -p -t "${SESSION:-}" >"$DIR/pane-fail.txt" 2>/dev/null || true
		if [ -f "${LOG:-}" ]; then
			cp "$LOG" "$DIR/log-fail.txt" 2>/dev/null || true
		fi
	fi
	exit 1
}

cleanup() {
	local rc=$?
	tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
	rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK" >/dev/null 2>&1 || true
	if [ "$rc" -eq 0 ] && [ "$KEEP" != "1" ]; then
		rm -rf "$ROOT"
	else
		printf 'harness artifacts: %s\n' "$ROOT" >&2
	fi
}
trap cleanup EXIT

snapshot() {
	local label="$1"
	tmux -L "$SOCK" capture-pane -p -t "$SESSION" >"$DIR/pane-$label.txt" 2>/dev/null || true
	if [ -f "$LOG" ]; then
		cp "$LOG" "$DIR/log-$label.txt"
	fi
}

# ---------------------------------------------------------------------------
# Environment setup
# ---------------------------------------------------------------------------

new_env() {
	SCENARIO="$1"
	DIR="$ROOT/$SCENARIO"
	CFG="$DIR/config"
	STATE="$DIR/state"
	FIXTURE="$DIR/fixture"
	RUN="$DIR/run"
	CWD_FILE="$DIR/cwd"
	LOG="$STATE/yazi/yazi.log"
	SESSION=""
	mkdir -p "$CFG/plugins" "$STATE" "$RUN" "$FIXTURE"
	chmod 700 "$RUN"
	ln -sfn "$PLUGIN_DIR" "$CFG/plugins/tree.yazi"
}

write_config() {
	local tree="$1" mode="$2"
	cat >"$CFG/init.lua" <<LUA
require("tree"):setup({
	filter_mode = "$mode",
	startup = { tree = $tree, preview = false },
})
LUA
	cat >"$CFG/yazi.toml" <<'TOML'
[mgr]
ratio = [1, 3, 4]
TOML
	cat >"$CFG/keymap.toml" <<'TOML'
[[mgr.prepend_keymap]]
on = "T"
run = "plugin tree toggle"

[[mgr.prepend_keymap]]
on = "V"
run = "plugin tree preview"

[[mgr.prepend_keymap]]
on = "l"
run = "plugin tree right"

[[mgr.prepend_keymap]]
on = "h"
run = "plugin tree left"

[[mgr.prepend_keymap]]
on = "H"
run = "plugin tree root_up"

[[mgr.prepend_keymap]]
on = "L"
run = "plugin tree root_down"

[[mgr.prepend_keymap]]
on = "a"
run = "plugin tree create"

[[mgr.prepend_keymap]]
on = "p"
run = "plugin tree paste"

# The `--` separator keeps `--force` inside the plugin's own argument list
# instead of the outer action's (mirrors the stock `plugin <name> -- ...` form).
[[mgr.prepend_keymap]]
on = "P"
run = "plugin tree -- paste --force"

[[mgr.prepend_keymap]]
on = "f"
run = "plugin tree filter"

[[mgr.prepend_keymap]]
on = "<Esc>"
run = "plugin tree escape"

[[mgr.prepend_keymap]]
on = "r"
run = "plugin tree rename"

[[mgr.prepend_keymap]]
on = "s"
run = "sort size --reverse=no"

[[mgr.prepend_keymap]]
on = "S"
run = "sort mtime --reverse=no"

# Close the second tab by index (0-based) while another tab stays active, so a
# background tab close can be exercised.
[[mgr.prepend_keymap]]
on = "X"
run = "tab_close 1"
TOML
}

# Extra keymaps for the per-root/tab persistence scenarios. `dest0` and `dest9`
# are absolute cwd destinations (the fixture root and a second root); `[`/`]`
# drive stock history back/forward and `t` opens a new tab in the current cwd.
add_cd_keymaps() {
	local dest0="$1" dest9="$2"
	cat >>"$CFG/keymap.toml" <<TOML

[[mgr.prepend_keymap]]
on = "0"
run = "cd $dest0"

[[mgr.prepend_keymap]]
on = "9"
run = "cd $dest9"

[[mgr.prepend_keymap]]
on = "["
run = "back"

[[mgr.prepend_keymap]]
on = "]"
run = "forward"

[[mgr.prepend_keymap]]
on = "t"
run = "tab_create --current"
TOML
}

# root fixture: alpha/child.txt, aa.txt, beta.txt
make_fixture() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/alpha"
	printf 'AAA' >"$FIXTURE/aa.txt"
	printf 'BBB' >"$FIXTURE/beta.txt"
	printf 'child data' >"$FIXTURE/alpha/child.txt"
}

# overwrite fixture: alpha/aaa.txt and alpha/bbb.txt with distinct contents.
make_fixture_overwrite() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/alpha"
	printf 'AAA' >"$FIXTURE/alpha/aaa.txt"
	printf 'BBB' >"$FIXTURE/alpha/bbb.txt"
}

# deep fixture: alpha/beta/gamma/leaf.txt, alpha/beta/beta2.txt,
# alpha/child.txt, zz.txt. Sorted DFS order is alpha, beta, gamma, leaf.txt,
# beta2.txt, child.txt, zz.txt.
make_fixture_deep() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/alpha/beta/gamma"
	printf 'AAA' >"$FIXTURE/alpha/child.txt"
	printf 'BBB' >"$FIXTURE/alpha/beta/beta2.txt"
	printf 'CCC' >"$FIXTURE/alpha/beta/gamma/leaf.txt"
	printf 'ZZZ' >"$FIXTURE/zz.txt"
}

# symlink fixture: real/ with inner.txt plus a link pointing at it.
make_fixture_symlink() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/real"
	printf 'INNER' >"$FIXTURE/real/inner.txt"
	ln -s real "$FIXTURE/link"
	printf 'PLAIN' >"$FIXTURE/plain.txt"
}

# reroot fixture: sub/deep/leaf.txt plus sub/subfile.txt.
make_fixture_reroot() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/sub/deep"
	printf 'LEAF' >"$FIXTURE/sub/deep/leaf.txt"
	printf 'SUBFILE' >"$FIXTURE/sub/subfile.txt"
}

# create fixture: alpha/existing.txt plus a root file.
make_fixture_create() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/alpha"
	printf 'EXIST' >"$FIXTURE/alpha/existing.txt"
	printf 'ROOT' >"$FIXTURE/rootfile.txt"
}

# paste/cut fixture: src/a.txt plus an empty dst/ directory.
make_fixture_paste() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/src" "$FIXTURE/dst"
	printf 'AAA' >"$FIXTURE/src/a.txt"
}

# deep rename fixture: alpha/beta/deep.txt plus alpha/top.txt.
make_fixture_rename_deep() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/alpha/beta"
	printf 'DEEP' >"$FIXTURE/alpha/beta/deep.txt"
	printf 'TOP' >"$FIXTURE/alpha/top.txt"
}

# create-overwrite fixture: alpha/existing.txt, alpha/adir/inside.txt, and a
# symlink alpha/alink -> existing.txt.
make_fixture_create_overwrite() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/alpha/adir"
	printf 'KEEP' >"$FIXTURE/alpha/existing.txt"
	printf 'DIRKEEP' >"$FIXTURE/alpha/adir/inside.txt"
	ln -s existing.txt "$FIXTURE/alpha/alink"
}

# directory-rename fixture: alpha/beta/gamma/leaf.txt, alpha/beta/beta.txt,
# alpha/top.txt.
make_fixture_rename_dir() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/alpha/beta/gamma"
	printf 'LEAF' >"$FIXTURE/alpha/beta/gamma/leaf.txt"
	printf 'BETA' >"$FIXTURE/alpha/beta/beta.txt"
	printf 'TOP' >"$FIXTURE/alpha/top.txt"
}

# cut/move fixture: source/move.txt plus an empty target/ directory.
make_fixture_cut() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/source" "$FIXTURE/target"
	printf 'MOVEDATA' >"$FIXTURE/source/move.txt"
}

# removal fixture: alpha/child1.txt, alpha/child2.txt, alpha/sub/subchild.txt,
# gamma/g1.txt, root.txt. Root order is alpha, gamma, root.txt.
make_fixture_remove() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/alpha/sub" "$FIXTURE/gamma"
	printf 'C1' >"$FIXTURE/alpha/child1.txt"
	printf 'C2' >"$FIXTURE/alpha/child2.txt"
	printf 'SC' >"$FIXTURE/alpha/sub/subchild.txt"
	printf 'G1' >"$FIXTURE/gamma/g1.txt"
	printf 'ROOT' >"$FIXTURE/root.txt"
}

# cd-return fixture mirroring the reported repro: alpha/alpha1.txt,
# gamma/gamma1.txt, zz.txt. A sibling away/ directory is created outside the
# fixture root by make_fixture_cd so a `cd` keymap can leave and return.
make_fixture_cd() {
	rm -rf "$FIXTURE" "$DIR/away"
	mkdir -p "$FIXTURE/alpha" "$FIXTURE/gamma" "$DIR/away"
	printf 'A1' >"$FIXTURE/alpha/alpha1.txt"
	printf 'G1' >"$FIXTURE/gamma/gamma1.txt"
	printf 'ZZ' >"$FIXTURE/zz.txt"
}

# reroot fixture: alpha/sub_a/a.txt, alpha/leaf_a.txt, beta/sub_b/b.txt,
# beta/leaf_b.txt.
make_fixture_reroot_roundtrip() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/alpha/sub_a" "$FIXTURE/beta/sub_b"
	printf 'A' >"$FIXTURE/alpha/sub_a/inner_a.txt"
	printf 'LA' >"$FIXTURE/alpha/leaf_a.txt"
	printf 'B' >"$FIXTURE/beta/sub_b/inner_b.txt"
	printf 'LB' >"$FIXTURE/beta/leaf_b.txt"
}

# back/forward fixture: Amore/a1.txt and Bmore/bdir/b1.txt.
make_fixture_back_forward() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/Amore" "$FIXTURE/Bmore/bdir"
	printf 'A1' >"$FIXTURE/Amore/a1.txt"
	printf 'B1' >"$FIXTURE/Bmore/bdir/b1.txt"
}

# ---------------------------------------------------------------------------
# tmux driving
# ---------------------------------------------------------------------------

launch() {
	local cwd="$1"
	SESSION="t-${STAMP}-$((RANDOM))"
	tmux -L "$SOCK" -u new-session -d -s "$SESSION" -x "$COLS" -y "$ROWS" \
		"env YAZI_CONFIG_HOME='$CFG' XDG_STATE_HOME='$STATE' XDG_RUNTIME_DIR='$RUN' YAZI_LOG=debug yazi --cwd-file='$CWD_FILE' '$cwd'"
	wait_ready
}

# Launch with several initial cwds: Yazi's bootstrap queues one `cd` per boot
# tab while the cursor stays on the first, so every other boot tab is rerooted
# as a background tab (the only stock path that produces a background cd).
launch_cwds() {
	local args=""
	local cwd
	for cwd in "$@"; do
		args="$args '$cwd'"
	done
	SESSION="t-${STAMP}-$((RANDOM))"
	tmux -L "$SOCK" -u new-session -d -s "$SESSION" -x "$COLS" -y "$ROWS" \
		"env YAZI_CONFIG_HOME='$CFG' XDG_STATE_HOME='$STATE' XDG_RUNTIME_DIR='$RUN' YAZI_LOG=debug yazi --cwd-file='$CWD_FILE'$args"
	wait_ready
}

wait_ready() {
	local i=0
	while [ "$i" -lt 200 ]; do
		if tmux -L "$SOCK" capture-pane -p -t "$SESSION" 2>/dev/null | grep -q 'NOR'; then
			return 0
		fi
		sleep 0.05
		i=$((i + 1))
	done
	fail "yazi did not reach an interactive frame within 10s"
}

send_key() {
	tmux -L "$SOCK" send-keys -t "$SESSION" "$@"
}

send_text() {
	tmux -L "$SOCK" send-keys -t "$SESSION" -l -- "$1"
}

# Clear the open input popup regardless of where the caret starts: kill
# backwards to BOL, then forwards to EOL.
clear_input() {
	send_key C-u
	send_key C-k
}

settle() {
	sleep "${1:-0.6}"
}

capture() {
	tmux -L "$SOCK" capture-pane -p -t "$SESSION"
}

stop_session() {
	[ -n "$SESSION" ] || return 0
	tmux -L "$SOCK" kill-session -t "$SESSION" >/dev/null 2>&1 || true
	SESSION=""
}

wait_exit() {
	local i=0
	while [ "$i" -lt 100 ]; do
		if ! tmux -L "$SOCK" has-session -t "$SESSION" 2>/dev/null; then
			return 0
		fi
		sleep 0.1
		i=$((i + 1))
	done
	fail "yazi did not exit within 10s"
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

pane_has() {
	if capture | grep -qF -- "$1"; then
		return 0
	fi
	fail "${2:-pane should contain} '$1'"
}

pane_lacks() {
	if capture | grep -qF -- "$1"; then
		fail "${2:-pane should not contain} '$1'"
	fi
	return 0
}

# First line number (1-based) in the pane containing a literal string.
line_of() {
	capture | grep -nF -- "$1" | head -n 1 | cut -d: -f1
}

line_before() {
	local a b
	a="$(line_of "$1")"
	b="$(line_of "$2")"
	[ -n "$a" ] || fail "pane has no row for '$1'"
	[ -n "$b" ] || fail "pane has no row for '$2'"
	if [ "$a" -ge "$b" ]; then
		fail "'$1' (line $a) should render before '$2' (line $b)"
	fi
	return 0
}

# Hovered name is the name-shaped token following the size field on the status
# line. The size may be followed by a theme separator glyph before the name.
hovered_name() {
	local name
	name="$(capture | tail -n 1 | awk '{
		for (i = 1; i <= NF; i++)
			if ($i ~ /^[0-9.]+[BKMGT]?$/ && $i !~ /\//) {
				for (j = i + 1; j <= NF; j++)
					if ($j ~ /^[A-Za-z0-9_.@+-]+$/) { print $j; exit }
			}
	}')"
	printf '%s' "$name"
}

hovered_is() {
	local name
	name="$(hovered_name)"
	if [ "$name" != "$1" ]; then
		fail "${2:-hovered file} is '$name', expected '$1'"
	fi
	return 0
}

header_has() {
	capture | head -n 1 | grep -qF -- "$1" || fail "header should contain '$1'"
	return 0
}

header_lacks() {
	capture | head -n 1 | grep -qF -- "$1" && fail "header should not contain '$1'"
	return 0
}

# Text between the popup border glyphs on the value row of the open input box.
filter_popup_value() {
	capture | awk '
		/Filter:/ { seen = 1 }
		seen && /│/ {
			n = split($0, a, "│")
			if (n >= 3) {
				v = a[n - 1]
				gsub(/^ +| +$/, "", v)
				print v
				exit
			}
		}
	'
}

# Assert the filter popup is open with exactly the given (possibly empty) value.
filter_popup_is() {
	pane_has 'Filter:' "filter popup should be open"
	local got
	got="$(filter_popup_value)"
	if [ "$got" != "$1" ]; then
		fail "filter popup value is '$got', expected '$1'"
	fi
	return 0
}

file_exists() {
	[ -e "$1" ] || fail "expected file '$1' to exist"
	return 0
}

file_absent() {
	[ ! -e "$1" ] || fail "expected file '$1' to be gone"
	return 0
}

file_content_is() {
	local got
	[ -f "$1" ] || fail "expected file '$1' to exist"
	got="$(cat "$1")"
	[ "$got" = "$2" ] || fail "file '$1' contains '$got', expected '$2'"
	return 0
}

log_has() {
	if grep -qE -- "$1" "$LOG"; then
		return 0
	fi
	fail "${2:-log should match} /$1/"
}

log_lacks() {
	if grep -qE -- "$1" "$LOG"; then
		fail "${2:-log should not match} /$1/"
	fi
	return 0
}

# The last rebuild line must match the given ERE.
last_rebuild_has() {
	local line
	line="$(grep -a 'rebuild gen=' "$LOG" | tail -n 1)"
	if [ -n "$line" ] && printf '%s\n' "$line" | grep -qE -- "$1"; then
		return 0
	fi
	fail "last rebuild line '$line' should match /$1/"
}

# Reject WARN/ERROR level lines and Lua/plugin failures. Command/status noise
# that Yazi legitimately logs at DEBUG level is allowed.
assert_log_clean() {
	local bad
	bad="$(grep -aE 'Z +(WARN|ERROR) ' "$LOG" || true)"
	if [ -n "$bad" ]; then
		fail "log has WARN/ERROR lines:
$bad"
	fi
	bad="$(grep -aiE 'runtime error|stack traceback|incompatible plugin|failed to load plugin|plugin .* not found|lua syntax error' "$LOG" || true)"
	if [ -n "$bad" ]; then
		fail "log has Lua/plugin failures:
$bad"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

# Flicker-free startup: setup() must assign the tree ratio synchronously before
# the first render (no runtime apply/toggle), and the first frame must already
# be the collapsed single-pane layout.
scenario_startup() {
	new_env startup
	write_config true adopt
	make_fixture
	launch "$FIXTURE"

	local early
	early="$(capture)"
	if printf '%s\n' "$early" | grep -qF '│'; then
		fail "first captured frame shows a pane separator; startup is not tree-shaped"
	fi
	printf '%s\n' "$early" | grep -qF 'alpha' || fail "first captured frame is missing root rows"

	log_has 'startup tree=.*true' "startup tree mode logged"
	log_lacks 'entry action=.*toggle' "startup must not toggle at runtime"
	log_lacks 'applying ratio' "startup must not call apply() (flicker)"
	log_has 'render style=' "first render logged"

	local setup_line render_line
	setup_line="$(grep -an 'startup tree=' "$LOG" | head -n 1 | cut -d: -f1)"
	render_line="$(grep -an 'render style=' "$LOG" | head -n 1 | cut -d: -f1)"
	[ -n "$setup_line" ] || fail "no startup log line"
	[ -n "$render_line" ] || fail "no render log line"
	[ "$setup_line" -lt "$render_line" ] || fail "ratio assigned after first render (setup=$setup_line render=$render_line)"

	header_has "$FIXTURE"
	pane_has 'beta.txt'
	pane_lacks '└─' "tree must start collapsed"
	snapshot startup
	assert_log_clean
	stop_session
}

# Expand/collapse drives real rows into the native Folder; the cursor must stay
# aligned with those rows.
scenario_expand_collapse() {
	new_env expand_collapse
	write_config true adopt
	make_fixture
	launch "$FIXTURE"

	hovered_is 'alpha' "initial cursor"
	send_key l
	settle 0.9
	pane_has '└─' "expanded connector"
	pane_has 'child.txt'
	hovered_is 'alpha' "cursor stays on the expanded parent"
	line_before 'alpha' 'child.txt'

	send_key j
	settle 0.4
	hovered_is 'child.txt' "down arrow lands on the injected child"
	capture | tail -n 1 | grep -qF '2/4' || fail "status position should be 2/4 on the child"

	send_key h
	settle 0.9
	hovered_is 'alpha' "h from a child collapses back onto the parent"
	pane_lacks 'child.txt'
	pane_lacks '└─'
	capture | tail -n 1 | grep -qF '1/3' || fail "status position should be 1/3 after collapse"

	snapshot expand_collapse
	assert_log_clean
	stop_session
}

# Filter popup parity with stock: the input always opens blank while the live
# query stays applied, the first realtime typed value replaces it, and
# cancel/Escape close the popup while retaining the latest live query instead of
# clearing or restoring the hierarchy. <Esc> after the popup has closed clears.
scenario_filter() {
	new_env filter
	write_config true adopt
	make_fixture
	launch "$FIXTURE"

	send_key l
	settle 0.9

	# Opening with no active query: blank input, no filter applied.
	send_key f
	settle 0.5
	filter_popup_is ''
	header_lacks '(filter:'
	pane_has 'beta.txt'

	# Realtime typing applies the hierarchy-aware query immediately.
	send_text 'chi'
	settle 0.7
	filter_popup_is 'chi'
	header_has '(filter: chi)' "header indicator while typing"
	pane_has 'alpha'
	pane_has 'child.txt'
	pane_lacks 'beta.txt' "non-matching root hidden"
	pane_lacks 'aa.txt' "non-matching root hidden"

	# Submitting closes the popup and keeps the applied query.
	send_key Enter
	settle 0.9
	pane_lacks 'Filter:' "popup closed on submit"
	header_has '(filter: chi)' "header indicator after submit"
	pane_has 'child.txt'
	pane_lacks 'beta.txt' "submitted query stays applied"

	# Reopening while a query is live opens blank but leaves that query applied.
	send_key f
	settle 0.5
	filter_popup_is ''
	header_has '(filter: chi)' "reopened popup keeps the live query"
	pane_lacks 'beta.txt' "reopened popup must not drop the live query"

	# The first realtime typed value replaces the live query.
	send_text 'aa'
	settle 0.7
	filter_popup_is 'aa'
	header_has '(filter: aa)' "typed value replaces the live query"
	pane_has 'aa.txt'
	pane_lacks 'beta.txt'

	# Cancel closes the popup and retains the latest live query.
	send_key C-c
	settle 0.9
	pane_lacks 'Filter:' "popup closed on cancel"
	header_has '(filter: aa)' "cancel retains the latest live query"
	pane_has 'aa.txt'
	pane_lacks 'beta.txt' "cancel must not restore the full hierarchy"
	last_rebuild_has 'filter=.*aa' "cancel must not rebuild an empty query"

	# Escape while the popup is open likewise retains the live query.
	send_key f
	settle 0.5
	send_text 'be'
	settle 0.6
	header_has '(filter: be)'
	send_key Escape
	settle 0.9
	header_has '(filter: be)' "Escape retains the latest live query"
	pane_has 'beta.txt'
	pane_lacks 'aa.txt' "Escape must not restore the full hierarchy"
	send_key C-c
	settle 0.7

	# <Esc> after the popup has closed clears the active tree filter.
	send_key Escape
	settle 0.9
	pane_lacks '(filter:' "header indicator cleared"
	pane_has 'beta.txt'
	pane_has 'aa.txt'
	log_has 'filter cleared'

	snapshot filter
	assert_log_clean
	stop_session
}

# Native filter hand-off, one scenario per filter_mode.
run_filter_mode() {
	local mode="$1"
	new_env "filter_$mode"
	write_config false "$mode"
	make_fixture
	launch "$FIXTURE"

	# Establish a native filter (stock filter path; tree mode is off).
	send_key f
	settle 0.5
	send_text 'aa'
	settle 0.5
	send_key Enter
	settle 1.0
	header_has '(filter: aa)'
	pane_has 'aa.txt'
	pane_lacks 'beta.txt' "native filter hides non-matching root"

	# Enter tree mode.
	send_key T
	settle 1.2
	log_has "native filter transferred; mode=.*$mode"
	case "$mode" in
	adopt)
		header_has '(filter: aa)' "adopted query keeps the indicator"
		pane_has 'aa.txt'
		pane_lacks 'beta.txt' "adopted query stays hierarchy-aware"
		;;
	suspend | clear)
		header_lacks '(filter:' "suspended/discarded query has no indicator"
		pane_has 'beta.txt' "full tree while suspended/discarded"
		pane_has 'aa.txt'
		;;
	esac

	# Leave tree mode and check the hand-back.
	send_key T
	settle 1.2
	case "$mode" in
	adopt)
		log_has 'native filter restored; mode=.*adopt'
		header_has '(filter: aa)'
		pane_has 'aa.txt'
		pane_lacks 'beta.txt'
		;;
	suspend)
		log_has 'native filter restored; mode=.*suspend'
		header_has '(filter: aa)'
		pane_has 'aa.txt'
		pane_lacks 'beta.txt'
		;;
	clear)
		log_has 'native filter not restored; mode=.*clear'
		header_lacks '(filter:'
		pane_has 'aa.txt'
		pane_has 'beta.txt' "discarded filter is not restored"
		;;
	esac

	snapshot "filter_$mode"
	assert_log_clean
	stop_session
}

scenario_filter_adopt() {
	run_filter_mode adopt
}

scenario_filter_suspend() {
	run_filter_mode suspend
}

scenario_filter_clear() {
	run_filter_mode clear
}

# Nested rename: the row is replaced in place and the cwd never changes.
scenario_rename() {
	new_env rename
	write_config true adopt
	make_fixture
	launch "$FIXTURE"

	send_key l
	settle 0.9
	send_key j
	settle 0.4
	hovered_is 'child.txt' "child cursor before rename"

	send_key r
	settle 0.6
	pane_has 'Rename:' "rename popup should be open"

	# Clear the prefilled name (the caret starts before the extension, so a
	# plain backspace run would leave ".txt" behind), type the new one, submit.
	clear_input
	send_text 'renamed.txt'
	settle 0.3
	send_key Enter
	settle 1.3

	file_exists "$FIXTURE/alpha/renamed.txt"
	file_absent "$FIXTURE/alpha/child.txt"
	pane_has 'renamed.txt' "renamed row replaces the old one immediately"
	pane_lacks 'child.txt'
	hovered_is 'renamed.txt' "cursor follows the renamed row"
	line_before 'alpha' 'renamed.txt'

	# cwd must still be the tree root, not the child's parent.
	header_has "$FIXTURE"
	header_lacks "$FIXTURE/alpha"

	# Confirm with yazi's own exit hook that the tab cwd never moved.
	send_key q
	wait_exit
	file_exists "$CWD_FILE"
	file_content_is "$CWD_FILE" "$FIXTURE"

	snapshot rename
	assert_log_clean
	stop_session
}

# Overwrite prompt: decline keeps both files, accept replaces the target.
scenario_overwrite() {
	new_env overwrite
	write_config true adopt
	make_fixture_overwrite
	launch "$FIXTURE"

	send_key l
	settle 0.9
	send_key j
	settle 0.4
	hovered_is 'aaa.txt' "cursor on the first child"

	rename_to() {
		local target="$1"
		send_key r
		settle 0.6
		clear_input
		send_text "$target"
		settle 0.3
		send_key Enter
		settle 0.9
	}

	rename_to 'bbb.txt'
	pane_has 'Overwrite?' "overwrite confirm should appear"
	log_has 'nested rename overwrite prompt'

	send_key n
	settle 1.0
	log_has 'nested rename overwrite declined'
	file_exists "$FIXTURE/alpha/aaa.txt"
	file_content_is "$FIXTURE/alpha/bbb.txt" 'BBB'
	pane_has 'aaa.txt' "declined rename leaves the source row"
	hovered_is 'aaa.txt' "cursor stays on the source after declining"

	rename_to 'bbb.txt'
	pane_has 'Overwrite?'
	send_key y
	settle 1.4
	file_absent "$FIXTURE/alpha/aaa.txt"
	file_content_is "$FIXTURE/alpha/bbb.txt" 'AAA'
	pane_has 'bbb.txt'
	pane_lacks 'aaa.txt'
	hovered_is 'bbb.txt' "cursor follows the accepted rename"

	snapshot overwrite
	assert_log_clean
	stop_session
}

# Disabling tree mode must drop every injected descendant row.
scenario_cleanup() {
	new_env cleanup
	write_config true adopt
	make_fixture
	launch "$FIXTURE"

	send_key l
	settle 0.9
	pane_has '└─'
	pane_has 'child.txt'

	send_key T
	settle 1.3
	log_has 'toggle off;'
	pane_lacks '└─' "connectors removed after disable"
	pane_lacks 'child.txt' "injected descendants removed after disable"
	pane_has 'alpha'
	pane_has 'aa.txt'
	pane_has 'beta.txt'
	header_lacks '(filter:'
	capture | tail -n 1 | grep -qF '1/3' || fail "cursor should be back on the root list (1/3)"

	snapshot cleanup
	assert_log_clean
	stop_session
}

# Arbitrary-depth expansion: every expanded directory is read lazily and its
# children are flattened depth-first with connectors that stay correct at each
# level. h collapses the immediate parent subtree of a nested row.
scenario_deep_expand_collapse() {
	new_env deep_expand_collapse
	write_config true adopt
	make_fixture_deep
	launch "$FIXTURE"

	hovered_is 'alpha' "initial cursor"
	send_key l
	settle 1.0
	pane_has 'child.txt'
	pane_has ' └─' "depth-1 last connector"

	send_key j
	settle 0.4
	hovered_is 'beta' "down onto the nested directory"
	send_key l
	settle 1.0
	pane_has 'beta2.txt'
	pane_has ' │  └─' "depth-2 connector under a non-last parent"

	send_key j
	settle 0.4
	hovered_is 'gamma'
	send_key l
	settle 1.0
	pane_has 'leaf.txt'
	pane_has ' │  │  └─' "depth-3 connector continuation"

	line_before 'alpha' 'beta'
	line_before 'beta' 'gamma'
	line_before 'gamma' 'leaf.txt'

	# h on a nested leaf collapses its immediate parent (gamma), not the root.
	send_key h
	settle 1.0
	hovered_is 'gamma' "h collapses the immediate parent subtree"
	pane_lacks 'leaf.txt'
	pane_lacks ' │  │  └─'
	log_has 'collapse .*gamma'

	# h again prunes beta's subtree.
	send_key h
	settle 1.0
	hovered_is 'beta'
	pane_lacks 'gamma'
	pane_lacks 'beta2.txt'
	log_has 'collapse .*beta'

	# h on the now-collapsed beta prunes alpha's subtree.
	send_key h
	settle 1.0
	hovered_is 'alpha'
	pane_lacks 'beta'
	pane_lacks '└─'

	snapshot deep_expand_collapse
	assert_log_clean
	stop_session
}

# Symlinked directories never expand (cycle guard); a real sibling still does.
scenario_symlink_noexpand() {
	new_env symlink_noexpand
	write_config true adopt
	make_fixture_symlink
	launch "$FIXTURE"

	hovered_is 'link' "symlink sorts as a directory"
	send_key l
	settle 0.9
	log_has 'refusing to expand linked directory'
	pane_lacks 'inner.txt' "symlinked directory must not expand"

	send_key j
	settle 0.4
	hovered_is 'real'
	send_key l
	settle 1.0
	pane_has 'inner.txt'

	snapshot symlink_noexpand
	assert_log_clean
	stop_session
}

# H/L reroot the tree root; L on a nested file reveals it in its parent.
scenario_reroot() {
	new_env reroot
	write_config true adopt
	make_fixture_reroot
	launch "$FIXTURE"

	hovered_is 'sub' "initial cursor"
	send_key l
	settle 1.0
	hovered_is 'sub' "expansion keeps the root"
	pane_has 'deep'
	pane_has 'subfile.txt'

	send_key j
	settle 0.4
	hovered_is 'deep'
	send_key L
	settle 1.4
	header_has "$FIXTURE/sub/deep"
	hovered_is 'leaf.txt' "reroot into the hovered directory"

	send_key H
	settle 1.4
	header_has "$FIXTURE/sub"
	header_lacks "$FIXTURE/sub/deep"

	# L on a nested file reveals the file in its containing directory.
	send_key l
	settle 1.0
	hovered_is 'deep'
	send_key j
	settle 0.4
	hovered_is 'leaf.txt'
	send_key L
	settle 1.4
	header_has "$FIXTURE/sub/deep"
	hovered_is 'leaf.txt' "nested file reveal"

	snapshot reroot
	assert_log_clean
	stop_session
}

# The plugin-owned rename reproduces stock before-extension caret placement.
scenario_rename_caret() {
	new_env rename_caret
	write_config true adopt
	make_fixture
	launch "$FIXTURE"

	send_key l
	settle 0.9
	send_key j
	settle 0.4
	hovered_is 'child.txt'

	# The caret opens before ".txt", so a single typed character inserts there.
	send_key r
	settle 0.6
	pane_has 'Rename:'
	log_has 'nested rename open.*move=.*-4'
	send_text 'X'
	settle 0.3
	send_key Enter
	settle 1.3

	file_exists "$FIXTURE/alpha/childX.txt"
	file_absent "$FIXTURE/alpha/child.txt"
	pane_has 'childX.txt'
	hovered_is 'childX.txt' "cursor follows the renamed row"
	header_has "$FIXTURE"
	header_lacks "$FIXTURE/alpha"

	snapshot rename_caret
	assert_log_clean
	stop_session
}

# Rename of a two-level injected row keeps the cwd and rebuilds the hierarchy.
scenario_rename_deep() {
	new_env rename_deep
	write_config true adopt
	make_fixture_rename_deep
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	hovered_is 'beta'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	hovered_is 'deep.txt'

	send_key r
	settle 0.6
	pane_has 'Rename:'
	clear_input
	send_text 'renamed.txt'
	settle 0.3
	send_key Enter
	settle 1.4

	file_exists "$FIXTURE/alpha/beta/renamed.txt"
	file_absent "$FIXTURE/alpha/beta/deep.txt"
	pane_has 'renamed.txt'
	hovered_is 'renamed.txt' "cursor follows the deep renamed row"
	line_before 'beta' 'renamed.txt'
	header_has "$FIXTURE"
	header_lacks "$FIXTURE/alpha/beta"

	snapshot rename_deep
	assert_log_clean
	stop_session
}

# Renaming a directory re-keys every expansion keyed below it. The expanded
# descendant must survive under the new prefix for both the stock DDS path and
# the plugin-owned nested path, and a stale old-URL key must never resurrect
# expansion of a freshly created directory at that URL.
scenario_rename_dir_deep() {
	new_env rename_dir_deep
	write_config true adopt
	make_fixture_rename_dir
	launch "$FIXTURE"

	# Expand alpha, then alpha/beta, then alpha/beta/gamma.
	# DFS rows: 1 alpha, 2 beta, 3 gamma, 4 leaf.txt, 5 beta.txt, 6 top.txt.
	hovered_is 'alpha'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	hovered_is 'beta'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	hovered_is 'gamma'
	send_key l
	settle 1.0
	pane_has 'leaf.txt'
	capture | tail -n 1 | grep -qF '3/6' || fail "gamma should be row 3/6 while expanded"
	line_before 'alpha' 'beta'
	line_before 'beta' 'gamma'

	# Stock DDS path: rename the depth-0 directory alpha -> alpha2.
	send_key k
	settle 0.4
	send_key k
	settle 0.4
	hovered_is 'alpha'
	send_key r
	settle 0.6
	pane_has 'Rename:'
	clear_input
	send_text 'alpha2'
	settle 0.3
	send_key Enter
	settle 1.5

	file_exists "$FIXTURE/alpha2/beta/gamma/leaf.txt"
	file_absent "$FIXTURE/alpha"
	# The whole expanded subtree survives under the new prefix (6 rows again).
	pane_has 'alpha2'
	pane_has 'gamma'
	pane_has 'leaf.txt'
	log_has 'rename .*alpha2'
	capture | tail -n 1 | grep -qF '1/6' || fail "expanded subtree collapsed after renaming alpha"
	header_has "$FIXTURE"
	header_lacks "$FIXTURE/alpha2"

	# Stock DDS path back: alpha2 -> alpha; the same three levels stay expanded.
	send_key r
	settle 0.6
	pane_has 'Rename:'
	clear_input
	send_text 'alpha'
	settle 0.3
	send_key Enter
	settle 1.5

	file_exists "$FIXTURE/alpha/beta/gamma/leaf.txt"
	file_absent "$FIXTURE/alpha2"
	pane_has 'alpha'
	pane_has 'gamma'
	pane_has 'leaf.txt'
	capture | tail -n 1 | grep -qF '1/6' || fail "expanded subtree collapsed after renaming back"
	header_has "$FIXTURE"

	# Plugin-owned nested path: rename the expanded alpha/beta -> alpha/beta2.
	send_key j
	settle 0.4
	hovered_is 'beta'
	send_key r
	settle 0.6
	pane_has 'Rename:'
	clear_input
	send_text 'beta2'
	settle 0.3
	send_key Enter
	settle 1.5

	file_exists "$FIXTURE/alpha/beta2/gamma/leaf.txt"
	file_absent "$FIXTURE/alpha/beta"
	pane_has 'beta2'
	pane_has 'gamma'
	pane_has 'leaf.txt'
	log_has 'nested rename applied; old=.*beta.*new=.*beta2'
	capture | tail -n 1 | grep -qF '2/6' || fail "expanded subtree collapsed after nested directory rename"

	# And back through the plugin-owned path.
	send_key r
	settle 0.6
	pane_has 'Rename:'
	clear_input
	send_text 'beta'
	settle 0.3
	send_key Enter
	settle 1.5

	file_exists "$FIXTURE/alpha/beta/gamma/leaf.txt"
	file_absent "$FIXTURE/alpha/beta2"
	pane_has 'beta'
	pane_has 'gamma'
	pane_has 'leaf.txt'
	capture | tail -n 1 | grep -qF '2/6' || fail "expanded subtree collapsed after nested rename back"

	# Stale-key resurrection: move alpha away, then create a brand-new alpha
	# tree and expand it. Only the new alpha's own level may expand; the old
	# alpha/beta expansion must not have been left keyed under alpha.
	send_key k
	settle 0.4
	hovered_is 'alpha'
	send_key r
	settle 0.6
	pane_has 'Rename:'
	clear_input
	send_text 'alpha3'
	settle 0.3
	send_key Enter
	settle 1.5
	file_absent "$FIXTURE/alpha"

	mkdir -p "$FIXTURE/alpha/beta"
	printf 'STALE' >"$FIXTURE/alpha/beta/RESURRECT.txt"
	settle 1.5

	# Walk to the freshly appeared alpha root row and expand it.
	local i=0
	while [ "$i" -lt 6 ]; do
		if [ "$(hovered_name)" = "alpha" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'alpha' "fresh alpha root row"
	send_key l
	settle 1.2
	pane_has 'alpha3'
	pane_has 'beta'
	pane_lacks 'RESURRECT.txt' "stale alpha/beta expansion must not resurrect"

	snapshot rename_dir_deep
	assert_log_clean
	stop_session
}

# Target-aware create: inside a hovered directory, beside a hovered file, a
# trailing separator makes a directory, and a root-level file delegates stock.
scenario_create() {
	new_env create
	write_config true adopt
	make_fixture_create
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key a
	settle 0.6
	pane_has 'Create:' "create popup"
	send_text 'newfile.txt'
	settle 0.3
	send_key Enter
	settle 1.3
	file_exists "$FIXTURE/alpha/newfile.txt"
	header_has "$FIXTURE"
	header_lacks "$FIXTURE/alpha" "create must not change cwd"

	send_key l
	settle 1.0
	pane_has 'newfile.txt'
	pane_has 'existing.txt'

	send_key j
	settle 0.4
	hovered_is 'existing.txt'
	send_key a
	settle 0.6
	pane_has 'Create:'
	send_text 'beside.txt'
	settle 0.3
	send_key Enter
	settle 1.4
	file_exists "$FIXTURE/alpha/beside.txt"
	hovered_is 'beside.txt' "focus follows the created row"
	pane_has 'beside.txt'

	send_key k
	settle 0.4
	hovered_is 'alpha'
	send_key a
	settle 0.6
	send_text 'newdir/'
	settle 0.3
	send_key Enter
	settle 1.4
	[ -d "$FIXTURE/alpha/newdir" ] || fail "trailing separator should create a directory"
	pane_has 'newdir'

	# A root-level file resolves to cwd and delegates to stock create.
	send_key k
	settle 0.4
	hovered_is 'alpha'
	send_key h
	settle 1.0
	hovered_is 'alpha'
	send_key j
	settle 0.4
	hovered_is 'rootfile.txt'
	send_key a
	settle 0.6
	pane_has 'Create:'
	send_text 'rootnew.txt'
	settle 0.3
	send_key Enter
	settle 1.5
	file_exists "$FIXTURE/rootnew.txt"

	snapshot create
	assert_log_clean
	stop_session
}

# Create over an existing regular file: declining keeps the old bytes, accepting
# truncates in place with no unlink, no trash task, and a consistent row.
scenario_create_overwrite() {
	new_env create_overwrite
	write_config true adopt
	make_fixture_create_overwrite
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	# Rows: 1 alpha, 2 adir, 3 alink, 4 existing.txt (dirs first, then names).
	send_key j
	settle 0.3
	send_key j
	settle 0.3
	send_key j
	settle 0.3
	hovered_is 'existing.txt'

	# Decline: nothing changes.
	send_key a
	settle 0.6
	pane_has 'Create:'
	send_text 'existing.txt'
	settle 0.3
	send_key Enter
	settle 0.8
	pane_has 'Overwrite file?' "overwrite confirm for an existing file"
	send_key n
	settle 1.0
	log_has 'create overwrite declined'
	file_content_is "$FIXTURE/alpha/existing.txt" 'KEEP'
	log_lacks 'create dir collision'
	pane_has 'existing.txt'
	hovered_is 'existing.txt' "cursor stays on the declined file"

	# Accept: truncated in place, row still present, no trash task.
	send_key a
	settle 0.6
	pane_has 'Create:'
	send_text 'existing.txt'
	settle 0.3
	send_key Enter
	settle 0.8
	pane_has 'Overwrite file?'
	send_key y
	settle 1.4
	file_exists "$FIXTURE/alpha/existing.txt"
	file_content_is "$FIXTURE/alpha/existing.txt" ''
	pane_has 'existing.txt'
	hovered_is 'existing.txt' "cursor follows the overwritten file"
	log_lacks '[Tt]rash'
	log_lacks 'create dir collision'
	log_has 'create done'

	snapshot create_overwrite
	assert_log_clean
	stop_session
}

# Create collisions: an existing directory is a clean failure (no prompt, no
# EISDIR error, no trash), and an existing symlink is replaced as a link without
# touching its target.
scenario_create_collisions() {
	new_env create_collisions
	write_config true adopt
	make_fixture_create_overwrite
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	# Rows: 1 alpha, 2 adir, 3 alink, 4 existing.txt. Hovering a file targets
	# its parent directory (alpha), so a typed sibling name collides with the
	# directory/symlink entries already there.
	send_key j
	settle 0.3
	send_key j
	settle 0.3
	send_key j
	settle 0.3
	hovered_is 'existing.txt'

	# Directory collision: no overwrite prompt, a clear error, disk untouched.
	send_key a
	settle 0.6
	pane_has 'Create:'
	send_text 'adir'
	settle 0.3
	send_key Enter
	settle 1.2
	pane_lacks 'Overwrite file?' "directory collision must not prompt"
	pane_has 'already exists as a directory' "clear error notification"
	log_has 'create dir collision'
	[ -d "$FIXTURE/alpha/adir" ] || fail "directory collision must leave the directory"
	file_content_is "$FIXTURE/alpha/adir/inside.txt" 'DIRKEEP'
	log_lacks '[Tt]rash'
	hovered_is 'existing.txt' "cursor stays put after the collision"

	# Symlink collision: the link is replaced, its target keeps its bytes.
	send_key a
	settle 0.6
	pane_has 'Create:'
	send_text 'alink'
	settle 0.3
	send_key Enter
	settle 0.8
	pane_has 'Overwrite file?'
	send_key y
	settle 1.4
	[ -e "$FIXTURE/alpha/alink" ] || fail "symlink collision should leave a file at the link path"
	[ ! -L "$FIXTURE/alpha/alink" ] || fail "symlink should be replaced by a regular file"
	file_content_is "$FIXTURE/alpha/existing.txt" 'KEEP'
	file_content_is "$FIXTURE/alpha/alink" ''
	pane_has 'alink'
	log_lacks '[Tt]rash'
	log_has 'create done'

	snapshot create_collisions
	assert_log_clean
	stop_session
}

# Normal paste into a hovered nested directory copies a file; force paste
# overwrites an existing destination and a later normal paste uniquifies.
scenario_paste() {
	new_env paste
	write_config true adopt
	make_fixture_paste
	launch "$FIXTURE"

	hovered_is 'dst'
	send_key l
	settle 1.0
	hovered_is 'dst' "expand the destination"
	send_key j
	settle 0.4
	hovered_is 'src'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	hovered_is 'a.txt'
	send_key y
	settle 0.4
	send_key k
	settle 0.4
	hovered_is 'src'
	send_key k
	settle 0.4
	hovered_is 'dst'
	send_key p
	settle 2.2
	file_exists "$FIXTURE/dst/a.txt"
	file_content_is "$FIXTURE/dst/a.txt" 'AAA'
	log_has 'transfer complete'

	# Force paste overwrites the destination file content.
	printf 'OLD' >"$FIXTURE/dst/a.txt"
	send_key j
	settle 0.4
	hovered_is 'a.txt'
	send_key j
	settle 0.4
	hovered_is 'src'
	send_key j
	settle 0.4
	hovered_is 'a.txt'
	send_key y
	settle 0.4
	send_key k
	settle 0.4
	hovered_is 'src'
	send_key k
	settle 0.4
	hovered_is 'a.txt'
	send_key k
	settle 0.4
	hovered_is 'dst'
	send_key P
	settle 2.2
	file_content_is "$FIXTURE/dst/a.txt" 'AAA'

	# A later normal paste uniquifies instead of overwriting.
	send_key j
	settle 0.4
	hovered_is 'a.txt'
	send_key j
	settle 0.4
	hovered_is 'src'
	send_key j
	settle 0.4
	hovered_is 'a.txt'
	send_key y
	settle 0.4
	send_key k
	settle 0.4
	hovered_is 'src'
	send_key k
	settle 0.4
	hovered_is 'a.txt'
	send_key k
	settle 0.4
	hovered_is 'dst'
	send_key p
	settle 2.2
	file_exists "$FIXTURE/dst/a_1.txt"

	snapshot paste
	assert_log_clean
	stop_session
}

# Cut paste moves a nested file, unyanks the cut set, and refreshes the
# expanded source hierarchy so the moved row disappears.
scenario_cut_paste() {
	new_env cut_paste
	write_config true adopt
	make_fixture_cut
	launch "$FIXTURE"

	hovered_is 'source'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	hovered_is 'move.txt'
	send_key x
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'target'
	send_key p
	settle 2.2
	file_exists "$FIXTURE/target/move.txt"
	file_absent "$FIXTURE/source/move.txt"
	log_has 'cut paste unyank'
	log_has 'transfer complete'
	pane_lacks 'move.txt' "source child disappears after the move"

	snapshot cut_paste
	assert_log_clean
	stop_session
}

# Stock d (trash) on an injected nested file: the row disappears immediately,
# the sibling and other branches survive, and focus lands on the parent.
scenario_remove_trash() {
	new_env remove_trash
	write_config true adopt
	make_fixture_remove
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'child1.txt'
	pane_has 'child2.txt'
	send_key j
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'child1.txt'

	send_key d
	settle 0.6
	pane_has 'Trash 1 selected file?'
	send_key y
	settle 2.4

	file_absent "$FIXTURE/alpha/child1.txt"
	file_exists "$FIXTURE/alpha/child2.txt"
	pane_lacks 'child1.txt' "trashed row removed from the injected hierarchy"
	pane_has 'child2.txt' "sibling survives"
	pane_has 'sub' "unrelated child survives"
	hovered_is 'alpha' "focus returns to the surviving parent"
	header_has "$FIXTURE"
	log_has 'trash event urls=1 pruned_expanded=0'
	snapshot remove_trash
	assert_log_clean
	stop_session
}

# Stock D (permanent delete) on an injected nested file behaves like trash.
scenario_remove_delete() {
	new_env remove_delete
	write_config true adopt
	make_fixture_remove
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	send_key j
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'child2.txt'

	send_key D
	settle 0.6
	pane_has 'Permanently delete 1 selected file?'
	send_key y
	settle 2.4

	file_absent "$FIXTURE/alpha/child2.txt"
	file_exists "$FIXTURE/alpha/child1.txt"
	pane_lacks 'child2.txt' "permanently deleted row removed"
	pane_has 'child1.txt' "sibling survives"
	hovered_is 'alpha' "focus returns to the surviving parent"
	log_has 'delete event urls=1'
	snapshot remove_delete
	assert_log_clean
	stop_session
}

# Trashing an expanded directory prunes its expansion subtree and removes every
# injected descendant row in one rebuild.
scenario_remove_dir_trash() {
	new_env remove_dir_trash
	write_config true adopt
	make_fixture_remove
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	hovered_is 'sub'
	send_key l
	settle 1.0
	pane_has 'subchild.txt'

	send_key d
	settle 0.6
	pane_has 'Trash 1 selected file?'
	send_key y
	settle 2.4

	file_absent "$FIXTURE/alpha/sub"
	file_exists "$FIXTURE/alpha/child1.txt"
	pane_lacks 'subchild.txt' "descendant row of the trashed directory removed"
	pane_has 'child1.txt' "unrelated siblings survive"
	pane_has 'gamma' "unrelated root branch survives"
	hovered_is 'alpha' "focus returns to the surviving parent"
	log_has 'trash event urls=1 pruned_expanded=1'
	snapshot remove_dir_trash
	assert_log_clean
	stop_session
}

# Multi-selecting two unrelated injected rows (different branches) trashes both
# in one event, removes both rows, and leaves the other branches untouched.
scenario_remove_multi() {
	new_env remove_multi
	write_config true adopt
	make_fixture_remove
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'child1.txt'
	send_key Space
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'gamma'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	hovered_is 'g1.txt'
	send_key Space
	settle 0.4

	send_key d
	settle 0.6
	pane_has 'Trash 2 selected files?'
	send_key y
	settle 2.4

	file_absent "$FIXTURE/alpha/child1.txt"
	file_absent "$FIXTURE/gamma/g1.txt"
	file_exists "$FIXTURE/alpha/child2.txt"
	file_exists "$FIXTURE/alpha/sub/subchild.txt"
	pane_lacks 'child1.txt' "first selected row removed"
	pane_lacks 'g1.txt' "second selected row removed"
	pane_has 'child2.txt' "unselected sibling survives"
	pane_has 'sub' "unselected branch survives"
	pane_has 'gamma' "selected file's parent survives"
	hovered_is 'root.txt' "an unrelated hovered row is preserved across the batch"
	log_has 'trash event urls=2'
	snapshot remove_multi
	assert_log_clean
	stop_session
}

# Core regression: returning to a cached cwd must restore the saved expansion
# set instead of rendering Yazi's cached injected rows against empty state, so
# the first h on a visibly expanded directory collapses it immediately.
scenario_cd_return_restores() {
	new_env cd_return_restores
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'
	send_key j
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'gamma'
	send_key l
	settle 1.0
	pane_has 'gamma1.txt'
	capture | tail -n 1 | grep -qF '3/5' || fail "gamma should be row 3/5 before the roundtrip"

	send_key 9
	settle 1.2
	header_has "$DIR/away"
	pane_lacks 'alpha1.txt' "away root has no restored rows"

	send_key 0
	settle 1.4
	header_has "$FIXTURE"
	pane_has 'alpha1.txt' "alpha branch restored after returning"
	pane_has 'gamma1.txt' "gamma branch restored after returning"
	log_has 'cd restore;.*saved=.*true'

	# Put the cursor on gamma regardless of the restored cursor position.
	local i=0
	while [ "$i" -lt 6 ]; do
		if [ "$(hovered_name)" = "gamma" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'gamma' "cursor on gamma after return"

	# First-press h must collapse the visibly expanded row immediately.
	send_key h
	settle 1.0
	log_has 'collapse .*gamma'
	pane_lacks 'gamma1.txt' "h collapses the restored gamma branch"
	pane_has 'alpha1.txt' "collapsing gamma keeps alpha expanded"

	send_key l
	settle 1.0
	pane_has 'gamma1.txt' "l re-expands the collapsed branch"

	snapshot cd_return_restores
	assert_log_clean
	stop_session
}

# A never-visited root has no saved state: it must start collapsed and expand
# normally, with no stale rows from the root we left.
scenario_cd_return_new_root() {
	new_env cd_return_new_root
	write_config true adopt
	make_fixture_cd
	mkdir -p "$DIR/fresh/one" "$DIR/fresh/two"
	printf 'X' >"$DIR/fresh/one/x.txt"
	add_cd_keymaps "$FIXTURE" "$DIR/fresh"
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'

	send_key 9
	settle 1.4
	header_has "$DIR/fresh"
	pane_lacks 'alpha1.txt' "fresh root shows no stale rows"
	pane_lacks '└─' "fresh root starts collapsed"
	local i=0
	while [ "$i" -lt 4 ]; do
		if [ "$(hovered_name)" = "one" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'one'
	send_key l
	settle 1.0
	pane_has 'x.txt'
	send_key h
	settle 1.0
	pane_lacks 'x.txt' "h collapses normally at the fresh root"

	snapshot cd_return_new_root
	assert_log_clean
	stop_session
}

# A go-to keymap roundtrip twice over: save-then-restore must be idempotent with
# no stale or duplicated rows.
scenario_home_roundtrip() {
	new_env home_roundtrip
	write_config true adopt
	make_fixture_cd
	mkdir -p "$DIR/home"
	add_cd_keymaps "$DIR/home" "$FIXTURE"
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'gamma'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'
	pane_has 'gamma1.txt'
	capture | tail -n 1 | grep -qF '3/5' || fail "gamma row before the home trip"

	local trip
	for trip in 1 2; do
		send_key 0
		settle 1.2
		header_has "$DIR/home"
		send_key 9
		settle 1.4
		header_has "$FIXTURE"
		pane_has 'alpha1.txt' "alpha restored on trip $trip"
		pane_has 'gamma1.txt' "gamma restored on trip $trip"
		capture | tail -n 1 | grep -qF '3/5' || fail "row count drifted on trip $trip"
	done

	snapshot home_roundtrip
	assert_log_clean
	stop_session
}

# H/L reroot each keep an independent saved set; a child root's expansions never
# leak into its parent and vice versa.
scenario_reroot_roundtrip() {
	new_env reroot_roundtrip
	write_config true adopt
	make_fixture_reroot_roundtrip
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	# root0: expand alpha, then L into alpha (root1) and expand sub_a there.
	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'sub_a'
	send_key L
	settle 1.4
	header_has "$FIXTURE/alpha"
	local i=0
	while [ "$i" -lt 4 ]; do
		if [ "$(hovered_name)" = "sub_a" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'sub_a'
	send_key l
	settle 1.0
	pane_has 'inner_a.txt'

	# H back to root0: its {alpha} expansion is restored; root1's {sub_a} is not.
	send_key H
	settle 1.4
	header_has "$FIXTURE"
	pane_has 'sub_a' "alpha stays expanded at root0"
	pane_lacks 'inner_a.txt' "child root expansion does not leak into root0"

	# Re-enter root1: its own expansion is restored.
	i=0
	while [ "$i" -lt 6 ]; do
		if [ "$(hovered_name)" = "alpha" ]; then
			break
		fi
		send_key k
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'alpha'
	send_key L
	settle 1.4
	header_has "$FIXTURE/alpha"
	pane_has 'inner_a.txt' "root1 restores its own expansion"

	# H back and into root2; returning keeps root0 and root2 independent.
	send_key H
	settle 1.4
	header_has "$FIXTURE"
	i=0
	while [ "$i" -lt 8 ]; do
		if [ "$(hovered_name)" = "beta" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'beta'
	send_key L
	settle 1.4
	header_has "$FIXTURE/beta"
	send_key H
	settle 1.4
	header_has "$FIXTURE"
	pane_has 'sub_a' "root0 expansion survives the root2 trip"
	pane_lacks 'inner_b.txt' "root2 rows do not leak into root0"

	snapshot reroot_roundtrip
	assert_log_clean
	stop_session
}

# Stock history back/forward reroot through the same cd actor, so each URL's
# saved expansion set is restored in both directions.
scenario_back_forward() {
	new_env back_forward
	write_config true adopt
	make_fixture_back_forward
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	hovered_is 'Amore'
	send_key l
	settle 1.0
	pane_has 'a1.txt'
	send_key j
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'Bmore'
	send_key L
	settle 1.4
	header_has "$FIXTURE/Bmore"
	hovered_is 'bdir'
	send_key l
	settle 1.0
	pane_has 'b1.txt'

	send_key '['
	settle 1.4
	header_has "$FIXTURE"
	pane_has 'a1.txt' "back restores Amore's expansion"
	pane_lacks 'b1.txt' "Bmore rows absent at the other root"

	send_key ']'
	settle 1.4
	header_has "$FIXTURE/Bmore"
	pane_has 'b1.txt' "forward restores Bmore's expansion"
	pane_lacks 'a1.txt' "Amore rows absent at the other root"

	snapshot back_forward
	assert_log_clean
	stop_session
}

# Saved roots are isolated per tab: switching tabs restores each tab's own root
# and expansion set, and a cd in one tab never touches another tab's display.
scenario_multitab_isolated() {
	new_env multitab_isolated
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	# Tab 1: expand alpha.
	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'

	# Tab 2 (same cwd): expand gamma.
	send_key t
	settle 1.2
	header_has "$FIXTURE"
	local i=0
	while [ "$i" -lt 6 ]; do
		if [ "$(hovered_name)" = "gamma" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'gamma'
	send_key l
	settle 1.0
	pane_has 'gamma1.txt'
	pane_lacks 'alpha1.txt' "new tab starts from its own state"

	send_key 1
	settle 1.2
	pane_has 'alpha1.txt' "tab1 keeps its own expansion"
	pane_lacks 'gamma1.txt' "tab2 expansion does not leak into tab1"

	send_key 2
	settle 1.2
	pane_has 'gamma1.txt' "tab2 keeps its own expansion"
	pane_lacks 'alpha1.txt' "tab1 expansion does not leak into tab2"

	# cd in tab2, then switch away and back.
	send_key 9
	settle 1.2
	header_has "$DIR/away"
	send_key 1
	settle 1.2
	pane_has 'alpha1.txt' "tab1 untouched by tab2's cd"
	send_key 2
	settle 1.2
	header_has "$DIR/away"
	pane_lacks 'gamma1.txt' "the away root has no expansion in tab2"

	snapshot multitab_isolated
	assert_log_clean
	stop_session
}

# Toggle-off/on preserves the active tab/root's saved hierarchy: normal mode
# contains no injected rows, and re-enabling restores the expansions so the
# first h/l press acts on them immediately.
scenario_toggle_roundtrip() {
	new_env toggle_roundtrip
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'
	send_key j
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'gamma'
	send_key l
	settle 1.0
	pane_has 'gamma1.txt'
	capture | tail -n 1 | grep -qF '3/5' || fail "two branches expanded before the toggle"

	# Disable: the injected rows are gone and the Folder holds only real rows.
	send_key T
	settle 1.4
	log_has 'toggle off;.*saved_roots=" 1'
	pane_lacks '└─' "connectors removed after disable"
	pane_lacks 'alpha1.txt' "rows removed after disable"
	pane_lacks 'gamma1.txt' "rows removed after disable"
	header_has "$FIXTURE"

	# Re-enable: both saved branches are restored.
	send_key T
	settle 1.4
	log_has 'toggle on;.*restored=" 2'
	pane_has '└─' "connectors restored after re-enable"
	pane_has 'alpha1.txt' "alpha branch restored after re-enable"
	pane_has 'gamma1.txt' "gamma branch restored after re-enable"

	# First-press h on the visibly expanded gamma collapses only that branch.
	local i=0
	while [ "$i" -lt 6 ]; do
		if [ "$(hovered_name)" = "gamma" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'gamma' "cursor on gamma after re-enable"
	send_key h
	settle 1.0
	log_has 'collapse .*gamma'
	pane_lacks 'gamma1.txt' "h collapses the restored branch"
	pane_has 'alpha1.txt' "collapsing gamma keeps alpha expanded"

	send_key l
	settle 1.0
	pane_has 'gamma1.txt' "l re-expands the collapsed branch"

	snapshot toggle_roundtrip
	assert_log_clean
	stop_session
}

# Toggle state is tab-local: each tab's saved hierarchy survives its own
# normal-mode interlude independently, and toggling one tab never changes
# another tab's mode or rows.
scenario_toggle_multitab() {
	new_env toggle_multitab
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	# Tab 1: expand alpha, then confirm the branch survives its own toggle cycle.
	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'
	send_key T
	settle 1.4
	pane_lacks 'alpha1.txt' "tab1 clean while tree is off"
	pane_lacks '└─'
	send_key T
	settle 1.4
	pane_has 'alpha1.txt' "tab1 restores its saved branch"
	pane_has '└─'

	# Tab 2 inherits tree mode; expand gamma, then disable tree in tab 2 only.
	send_key t
	settle 1.2
	header_has "$FIXTURE"
	local i=0
	while [ "$i" -lt 6 ]; do
		if [ "$(hovered_name)" = "gamma" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'gamma'
	send_key l
	settle 1.0
	pane_has 'gamma1.txt'
	pane_lacks 'alpha1.txt' "tab2 starts from its own state"
	send_key T
	settle 1.4
	pane_lacks 'gamma1.txt' "tab2 clean while tree is off"
	pane_lacks '└─' "tab2 has no connectors while classic"

	# Tab 1 is untouched by tab 2's toggle-off.
	send_key 1
	settle 1.2
	pane_has 'alpha1.txt' "tab1 still tree after tab2 toggled off"
	pane_has '└─' "tab1 keeps its connectors"
	pane_lacks 'gamma1.txt' "tab2 expansion does not leak into tab1"

	# Tab 2 restores its own branch when re-enabled.
	send_key 2
	settle 1.2
	send_key T
	settle 1.4
	pane_has 'gamma1.txt' "tab2 restores its own branch"
	pane_lacks 'alpha1.txt' "tab1 expansion does not leak into tab2"

	# Toggling tab 1 off does not disturb tab 2's tree view.
	send_key 1
	settle 1.2
	pane_has 'alpha1.txt'
	send_key T
	settle 1.4
	pane_lacks 'alpha1.txt' "tab1 clean after its own toggle off"
	send_key 2
	settle 1.2
	pane_has 'gamma1.txt' "tab2 keeps its own tree mode after tab1 toggled off"

	snapshot toggle_multitab
	assert_log_clean
	stop_session
}

# Filter policy across a toggle: adopt hands the tree query to native filtering
# on disable and re-adopts it on enable, with expansions restored either way.
scenario_toggle_filter() {
	new_env toggle_filter
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'gamma'
	send_key l
	settle 1.0

	# Adopt a tree query for the gamma branch.
	send_key f
	settle 0.5
	send_text 'gamma'
	settle 0.8
	header_has '(filter: gamma)'
	pane_has 'gamma1.txt'
	pane_lacks 'alpha1.txt'
	send_key Enter
	settle 0.9

	# Disable: the query is handed back to native filtering.
	send_key T
	settle 1.4
	pane_lacks '└─' "connectors removed while filtered"
	header_has '(filter: gamma)' "adopt hands the query back to native filtering"
	pane_lacks 'alpha1.txt'

	# Re-enable: the native query is re-adopted and both expansions restore.
	send_key T
	settle 1.5
	log_has 'native filter transferred.*adopt'
	header_has '(filter: gamma)' "native query re-adopted on re-enable"
	pane_has 'gamma1.txt'
	pane_lacks 'alpha1.txt'

	# Clearing the query leaves the restored hierarchy intact.
	send_key Escape
	settle 1.0
	header_lacks '(filter:'
	pane_has 'alpha1.txt'
	pane_has 'gamma1.txt'

	# A second toggle with no query restores the same expansions unfiltered.
	send_key T
	settle 1.4
	pane_lacks '└─' "clean while off with no query"
	send_key T
	settle 1.5
	header_lacks '(filter:'
	pane_has 'alpha1.txt' "expansions survive a second toggle"
	pane_has 'gamma1.txt'

	snapshot toggle_filter
	assert_log_clean
	stop_session
}

# The hierarchy-aware tree query is part of a root's saved state: returning
# restores the filtered row subset and the header indicator, and clearing it
# persists as unfiltered.
scenario_filter_roundtrip() {
	new_env filter_roundtrip
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'gamma'
	send_key l
	settle 1.0

	send_key f
	settle 0.5
	filter_popup_is ''
	send_text 'gamma'
	settle 0.8
	filter_popup_is 'gamma'
	header_has '(filter: gamma)'
	pane_has 'gamma1.txt'
	pane_lacks 'alpha1.txt'
	send_key Enter
	settle 0.9

	send_key 9
	settle 1.2
	header_lacks '(filter:' "filter does not leak into the away root"
	send_key 0
	settle 1.4
	header_has '(filter: gamma)' "tree filter restored with the root"
	pane_has 'gamma1.txt'
	pane_lacks 'alpha1.txt' "filtered subset restored"

	send_key Escape
	settle 1.0
	header_lacks '(filter:'
	pane_has 'alpha1.txt'
	pane_has 'gamma1.txt'

	send_key 9
	settle 1.2
	send_key 0
	settle 1.4
	header_lacks '(filter:' "cleared filter stays cleared across a roundtrip"
	pane_has 'alpha1.txt'

	snapshot filter_roundtrip
	assert_log_clean
	stop_session
}

# Renaming a root re-keys the saved per-root state too, so leaving and returning
# still restores the whole subtree under the new name.
scenario_rename_root_roundtrip() {
	new_env rename_root_roundtrip
	write_config true adopt
	make_fixture_rename_dir
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	hovered_is 'beta'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	hovered_is 'gamma'
	send_key l
	settle 1.0
	pane_has 'leaf.txt'
	capture | tail -n 1 | grep -qF '3/6' || fail "gamma should be row 3/6 while expanded"

	local i=0
	while [ "$i" -lt 6 ]; do
		if [ "$(hovered_name)" = "alpha" ]; then
			break
		fi
		send_key k
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'alpha'
	send_key r
	settle 0.6
	pane_has 'Rename:'
	clear_input
	send_text 'alpha2'
	settle 0.3
	send_key Enter
	settle 1.5

	file_exists "$FIXTURE/alpha2/beta/gamma/leaf.txt"
	file_absent "$FIXTURE/alpha"
	pane_has 'alpha2'
	pane_has 'leaf.txt'
	log_has 'rename .*alpha2'

	send_key 9
	settle 1.2
	send_key 0
	settle 1.5
	header_has "$FIXTURE"
	pane_has 'alpha2'
	pane_has 'gamma'
	pane_has 'leaf.txt' "renamed subtree restored from saved state"

	snapshot rename_root_roundtrip
	assert_log_clean
	stop_session
}

# Trashing a saved root while away prunes the saved entry, so recreating the
# path later cannot resurrect the old expansion.
scenario_remove_root_while_away() {
	new_env remove_root_while_away
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'

	send_key H
	settle 1.4
	header_has "$DIR"
	pane_has 'fixture'

	local i=0
	while [ "$i" -lt 12 ]; do
		if [ "$(hovered_name)" = "fixture" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'fixture'
	send_key d
	settle 0.6
	pane_has 'Trash 1 selected file?'
	send_key y
	settle 2.4
	file_absent "$FIXTURE"
	log_has 'saved-state prune only|trash event'

	mkdir -p "$FIXTURE/alpha"
	printf 'A1' >"$FIXTURE/alpha/alpha1.txt"
	send_key 0
	settle 1.5
	header_has "$FIXTURE"
	pane_has 'alpha'
	pane_lacks 'alpha1.txt' "deleted root's saved expansion must not resurrect"
	pane_lacks '└─'

	snapshot remove_root_while_away
	assert_log_clean
	stop_session
}

# Startup's bootstrap cd only records tab/root tracking; it must not schedule a
# rebuild before the first user expansion.
scenario_startup_tracking_clean() {
	new_env startup_tracking_clean
	write_config true adopt
	make_fixture_cd
	launch "$FIXTURE"

	log_lacks 'rebuild gen=' "startup must not rebuild"
	pane_lacks '└─'
	pane_has 'alpha'
	log_has 'cd bootstrap'

	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'
	log_has 'rebuild gen=' "first expansion still rebuilds"

	snapshot startup_tracking_clean
	assert_log_clean
	stop_session
}

# Deletion focus, case 1: a nested file is removed while an unrelated row is
# hovered. The hovered row survives outside every removed subtree and must keep
# the cursor instead of jumping to the removed file's parent.
scenario_remove_hovered_elsewhere_preserved() {
	new_env remove_hovered_elsewhere_preserved
	write_config true adopt
	make_fixture_remove
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'child1.txt'
	send_key j
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'child1.txt'
	# Select child1 (the cursor advances to child2), then hover gamma.
	send_key Space
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'gamma'

	send_key d
	settle 0.6
	pane_has 'Trash 1 selected file?'
	send_key y
	settle 2.4

	file_absent "$FIXTURE/alpha/child1.txt"
	pane_lacks 'child1.txt' "removed row is gone"
	pane_has 'child2.txt' "surviving sibling remains"
	hovered_is 'gamma' "unrelated hovered row is preserved"
	log_has 'trash event urls=1.*focus=.*gamma'

	snapshot remove_hovered_elsewhere_preserved
	assert_log_clean
	stop_session
}

# Deletion focus, case 2: the hovered root-level file is removed. Its parent is
# the tree root (not a row), so the cursor falls back to the nearest prior
# surviving visible row.
scenario_remove_hovered_root_fallback() {
	new_env remove_hovered_root_fallback
	write_config true adopt
	make_fixture_remove
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key j
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'root.txt'

	send_key D
	settle 0.6
	pane_has 'Permanently delete 1 selected file?'
	send_key y
	settle 2.4

	file_absent "$FIXTURE/root.txt"
	pane_lacks 'root.txt' "deleted root row is gone"
	hovered_is 'gamma' "deleted hovered root falls back to the nearest prior survivor"

	snapshot remove_hovered_root_fallback
	assert_log_clean
	stop_session
}

# Deletion focus, case 3: an expanded directory is removed while its own child
# is hovered. The hovered row and its parent both disappear, so the cursor falls
# back to the nearest prior surviving visible row.
scenario_remove_subtree_inside_fallback() {
	new_env remove_subtree_inside_fallback
	write_config true adopt
	make_fixture_remove
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	local i=0
	while [ "$i" -lt 5 ]; do
		if [ "$(hovered_name)" = "gamma" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'gamma'
	send_key l
	settle 1.0
	pane_has 'g1.txt'

	# Select the expanded gamma directory (the cursor advances to g1).
	send_key Space
	settle 0.4
	hovered_is 'g1.txt'

	send_key d
	settle 0.6
	pane_has 'Trash 1 selected file?'
	send_key y
	settle 2.4

	file_absent "$FIXTURE/gamma"
	pane_lacks 'g1.txt' "descendant of the removed subtree is gone"
	pane_has 'child2.txt' "unrelated sibling survives"
	hovered_is 'child2.txt' "subtree removal falls back to the nearest prior survivor"

	snapshot remove_subtree_inside_fallback
	assert_log_clean
	stop_session
}

# Deletion focus under an active tree filter: the visible subset is the
# candidate set, so the surviving hovered row keeps the cursor and the filter
# stays applied.
scenario_remove_filtered_unrelated() {
	new_env remove_filtered_unrelated
	write_config true adopt
	make_fixture_remove
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	send_key f
	settle 0.5
	send_text 'child'
	settle 0.8
	send_key Enter
	settle 0.9
	header_has '(filter: child)'

	# Visible filtered rows: alpha, child1, child2 (sub is opaque, not expanded).
	send_key j
	settle 0.4
	hovered_is 'child1.txt'
	# Select child1 (cursor advances to child2), then delete child1.
	send_key Space
	settle 0.4
	hovered_is 'child2.txt'

	send_key d
	settle 0.6
	pane_has 'Trash 1 selected file?'
	send_key y
	settle 2.4

	file_absent "$FIXTURE/alpha/child1.txt"
	pane_lacks 'child1.txt'
	hovered_is 'child2.txt' "filtered view preserves the surviving hovered row"
	header_has '(filter: child)' "tree filter survives the removal rebuild"

	snapshot remove_filtered_unrelated
	assert_log_clean
	stop_session
}

# Tree mode is fully tab-local: toggling one tab does not change the other, and
# a classic tab must never render injected descendants restored from its cached
# Folder.
scenario_tab_mode_independent() {
	new_env tab_mode_independent
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	# Tab 1: expand alpha.
	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'
	pane_has '└─'

	# Tab 2 inherits tree mode but starts from its own empty root state.
	send_key t
	settle 1.2
	header_has "$FIXTURE"
	pane_lacks 'alpha1.txt' "new tab starts from its own state"

	# Toggling tree off in tab 2 affects only tab 2.
	send_key T
	settle 1.4
	pane_lacks 'alpha1.txt' "tab2 is clean while classic"
	pane_lacks '└─' "tab2 has no connectors while classic"

	# Tab 1 is untouched: still tree, still expanded, never renders flat rows.
	send_key 1
	settle 1.2
	pane_has 'alpha1.txt' "tab1 keeps its own tree mode"
	pane_has '└─' "tab1 keeps connectors"
	pane_lacks 'gamma1.txt'

	# Tab 2 stayed classic.
	send_key 2
	settle 1.2
	pane_lacks 'alpha1.txt' "tab2 stayed classic"
	pane_lacks '└─'

	# Turning tab 1 classic and roundtripping through history must not
	# resurrect injected rows in the classic renderer.
	send_key 1
	settle 1.2
	send_key T
	settle 1.4
	pane_lacks 'alpha1.txt' "tab1 is classic after its own toggle off"
	pane_lacks '└─'
	send_key 9
	settle 1.2
	header_has "$DIR/away"
	send_key 0
	settle 1.4
	header_has "$FIXTURE"
	pane_lacks 'alpha1.txt' "history-restored injected rows are stripped in a classic tab"
	pane_lacks '└─'

	# Re-enabling tree restores tab 1's own hierarchy.
	send_key T
	settle 1.4
	pane_has 'alpha1.txt' "tab1 hierarchy restored"
	pane_has '└─'

	snapshot tab_mode_independent
	assert_log_clean
	stop_session
}

# Preview visibility is tab-local and inherited by new tabs.
scenario_tab_preview_local() {
	new_env tab_preview_local
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	# Tree on + preview off is the single-pane startup layout.
	pane_lacks '│' "startup is single-pane"

	# Enable preview in tab 1.
	send_key V
	settle 1.0
	capture | grep -qF '│' || fail "tab1 shows the preview pane after V"

	# A new tab inherits preview on.
	send_key t
	settle 1.2
	capture | grep -qF '│' || fail "new tab inherits preview"

	# Disable preview in tab 2 only.
	send_key V
	settle 1.0
	pane_lacks '│' "tab2 preview off"

	# Tab 1 keeps preview on; tab 2 stays off.
	send_key 1
	settle 1.2
	capture | grep -qF '│' || fail "tab1 preview survives"
	send_key 2
	settle 1.2
	pane_lacks '│' "tab2 preview stays off"

	snapshot tab_preview_local
	assert_log_clean
	stop_session
}

# New tabs inherit the creating tab's tree/preview modes, so a classic creator
# yields a classic tab while the tree tab stays untouched.
scenario_tab_inherit_new() {
	new_env tab_inherit_new
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	# Tab 1 (tree) expands alpha.
	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'

	# Tab 2 inherits tree mode but not tab 1's expansion.
	send_key t
	settle 1.2
	local i=0
	while [ "$i" -lt 4 ]; do
		if [ "$(hovered_name)" = "gamma" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'gamma'
	send_key l
	settle 1.0
	pane_has 'gamma1.txt'
	pane_lacks 'alpha1.txt' "new tab has its own hierarchy"

	# A classic creator yields a classic new tab.
	send_key T
	settle 1.4
	pane_lacks '└─' "tab2 classic after toggle off"
	send_key t
	settle 1.2
	pane_lacks '└─' "classic creator yields a classic new tab"
	pane_lacks 'alpha1.txt'
	pane_lacks 'gamma1.txt'

	# Tab 1 is still tree and unaffected by the later classic tabs.
	send_key 1
	settle 1.2
	pane_has 'alpha1.txt' "tab1 unaffected by later classic tabs"
	pane_has '└─'

	snapshot tab_inherit_new
	assert_log_clean
	stop_session
}

# Rapid tab switching with in-flight rebuilds: a stale rebuild must never inject
# into another tab.
scenario_tab_rapid_switch() {
	new_env tab_rapid_switch
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'

	send_key t
	settle 1.2
	local i=0
	while [ "$i" -lt 4 ]; do
		if [ "$(hovered_name)" = "gamma" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'gamma'
	send_key l
	settle 1.0
	pane_has 'gamma1.txt'

	# Switch faster than the async reads can finish.
	send_key 1
	send_key 2
	send_key 1
	send_key 2
	settle 1.5

	send_key 1
	settle 1.4
	pane_has 'alpha1.txt' "tab1 renders its own hierarchy"
	pane_lacks 'gamma1.txt' "no cross-tab injection after rapid switching"
	send_key 2
	settle 1.4
	pane_has 'gamma1.txt' "tab2 renders its own hierarchy"
	pane_lacks 'alpha1.txt'

	snapshot tab_rapid_switch
	assert_log_clean
	stop_session
}

# The hierarchy-aware filter is tab-local: each tab keeps its own query and
# clearing one leaves the other intact.
scenario_tab_filter_local() {
	new_env tab_filter_local
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	# Tab 1: expand alpha and filter to its branch.
	hovered_is 'alpha'
	send_key l
	settle 1.0
	send_key f
	settle 0.5
	send_text 'alpha'
	settle 0.8
	send_key Enter
	settle 0.9
	header_has '(filter: alpha)'
	pane_has 'alpha1.txt'

	# Tab 2 inherits tree mode with no filter of its own.
	send_key t
	settle 1.2
	header_lacks '(filter:' "new tab starts unfiltered"
	local i=0
	while [ "$i" -lt 4 ]; do
		if [ "$(hovered_name)" = "gamma" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'gamma'
	send_key l
	settle 1.0
	pane_has 'gamma1.txt'
	pane_lacks 'alpha1.txt'
	send_key f
	settle 0.5
	send_text 'gamma'
	settle 0.8
	send_key Enter
	settle 0.9
	header_has '(filter: gamma)'

	# Each tab restores its own query on activation.
	send_key 1
	settle 1.4
	header_has '(filter: alpha)' "tab1 keeps its own tree filter"
	pane_has 'alpha1.txt'
	pane_lacks 'gamma1.txt'
	send_key 2
	settle 1.4
	header_has '(filter: gamma)' "tab2 keeps its own tree filter"
	pane_has 'gamma1.txt'
	pane_lacks 'alpha1.txt'

	# Clearing tab 2's filter leaves tab 1's intact.
	send_key Escape
	settle 1.0
	header_lacks '(filter:'
	send_key 1
	settle 1.4
	header_has '(filter: alpha)' "tab1 filter survives tab2 clearing"

	snapshot tab_filter_local
	assert_log_clean
	stop_session
}

# Sort requests are captured per tab: leaving tree mode restores each tab's own
# requested sort, never another tab's.
scenario_tab_sort_local() {
	new_env tab_sort_local
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	# Tab 1 requests size sort while pinned.
	send_key s
	settle 0.8
	log_has 'sort request captured; forcing by=none'

	# Tab 2 inherits tree mode; request a different sort.
	send_key t
	settle 1.2
	send_key S
	settle 0.8

	# Leaving tree mode in tab 2 restores its own request.
	send_key T
	settle 1.4
	log_has 'restoring sort_by=.*mtime' "tab2 restores mtime"

	# Tab 1 still restores size, proving the handoff did not bleed.
	send_key 1
	settle 1.2
	send_key T
	settle 1.4
	log_has 'restoring sort_by=.*size' "tab1 restores size"

	snapshot tab_sort_local
	assert_log_clean
	stop_session
}

# Saved-state maintenance is not gated on the active tab's tree mode: a deletion
# performed from a classic tab must still prune a tree tab's saved expansion, or
# a directory recreated at the same URL would resurrect it.
scenario_cross_tab_remove_prunes_saved() {
	new_env cross_tab_remove_prunes_saved
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	# Tab 1 (tree): expand alpha, giving it a saved expansion key.
	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'

	# Tab 2: a classic tab at the same root.
	send_key t
	settle 1.2
	send_key T
	settle 1.4
	pane_lacks 'alpha1.txt' "tab2 is classic"

	# Trash alpha from the classic tab. The active tab is not in tree mode, so
	# only the cross-tab saved-state prune should run.
	hovered_is 'alpha'
	send_key d
	settle 0.6
	pane_has 'Trash 1 selected file?'
	send_key y
	settle 2.4
	file_absent "$FIXTURE/alpha"
	log_has 'trash saved-state prune only'

	# Recreate the path so a stale key would auto-expand it again.
	mkdir -p "$FIXTURE/alpha"
	printf 'A1' >"$FIXTURE/alpha/alpha1.txt"

	# Back to the tree tab: its pruned saved expansion must not resurrect.
	send_key 1
	settle 1.4
	pane_has 'alpha'
	pane_lacks 'alpha1.txt' "pruned expansion must not resurrect"
	pane_lacks '└─' "no injected connector for the recreated path"

	snapshot cross_tab_remove_prunes_saved
	assert_log_clean
	stop_session
}

# A rename performed from a classic tab must re-key every tab's saved roots, so
# the tree tab follows the rename instead of keeping a stale key at the old URL.
scenario_cross_tab_rename_rekeys_saved() {
	new_env cross_tab_rename_rekeys_saved
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	# Tab 1 (tree): expand alpha.
	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'

	# Tab 2: classic; rename alpha -> alpha2 with stock rename.
	send_key t
	settle 1.2
	send_key T
	settle 1.4
	hovered_is 'alpha'
	send_key r
	settle 0.6
	pane_has 'Rename:'
	clear_input
	send_text 'alpha2'
	settle 0.3
	send_key Enter
	settle 1.6
	file_exists "$FIXTURE/alpha2/alpha1.txt"
	file_absent "$FIXTURE/alpha"
	log_has 'rename saved-state re-key'

	# Recreate the old path so a stale key would auto-expand it.
	mkdir -p "$FIXTURE/alpha"
	printf 'NEW' >"$FIXTURE/alpha/newfile.txt"

	# Back to the tree tab: its saved key followed the rename.
	send_key 1
	settle 1.6
	pane_has 'alpha2'
	pane_has 'alpha1.txt' "renamed branch keeps the tree tab's saved expansion"
	pane_lacks 'newfile.txt' "stale key must not resurrect the recreated old path"

	snapshot cross_tab_rename_rekeys_saved
	assert_log_clean
	stop_session
}

# A move performed from a classic tab removes the source path, so the tree tab's
# saved key under it must be pruned rather than left to resurrect.
scenario_cross_tab_move_prunes_saved() {
	new_env cross_tab_move_prunes_saved
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	# Tab 1 (tree): expand alpha.
	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'

	# Tab 2: classic; cut alpha and paste it into the away root.
	send_key t
	settle 1.2
	send_key T
	settle 1.4
	hovered_is 'alpha'
	send_key x
	settle 0.5
	send_key 9
	settle 1.2
	header_has "$DIR/away"
	send_key p
	settle 2.4
	file_absent "$FIXTURE/alpha"
	file_exists "$DIR/away/alpha/alpha1.txt"
	log_has 'move saved-state prune'

	# Recreate the old path so a stale key would auto-expand it.
	mkdir -p "$FIXTURE/alpha"
	printf 'NEW' >"$FIXTURE/alpha/newfile.txt"

	send_key 1
	settle 1.6
	pane_has 'alpha'
	pane_lacks 'newfile.txt' "moved-away path must not resurrect its expansion"
	pane_lacks '└─'

	snapshot cross_tab_move_prunes_saved
	assert_log_clean
	stop_session
}

# A background-tab cd (only reachable from stock through multi-cwd bootstrap)
# records the tab's own root without disturbing the active tab's live state.
scenario_background_cd_tracking() {
	new_env background_cd_tracking
	write_config true adopt
	mkdir -p "$DIR/rootA" "$DIR/rootB"
	printf 'A' >"$DIR/rootA/a.txt"
	printf 'B' >"$DIR/rootB/b.txt"
	launch_cwds "$DIR/rootA" "$DIR/rootB"

	header_has "$DIR/rootA"
	pane_has 'a.txt'
	log_has 'cd background tab=' "the second boot tab is rerooted as a background tab"
	log_has 'cd bootstrap tab=' "the active boot tab is still adopted"

	# The active tab stays fully functional.
	hovered_is 'a.txt'
	send_key 2
	settle 1.2
	header_has "$DIR/rootB"
	pane_has 'b.txt'

	snapshot background_cd_tracking
	assert_log_clean
	stop_session
}

# Closing a tab (including a background one, whose close publishes an unchanged
# active tab id) must drop that tab's plugin state lazily.
scenario_tab_close_prunes_state() {
	new_env tab_close_prunes_state
	write_config true adopt
	make_fixture_cd
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	# Tab 1 (tree) expands alpha, so it has real state to keep.
	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'

	# Tab 2 is created and then closed from tab 1 as a background tab: the close
	# publishes `tab` with the active id unchanged.
	send_key t
	settle 1.2
	send_key 1
	settle 1.2
	send_key X
	settle 1.4
	log_has 'pruned closed tab=' "closed tab state is pruned"
	pane_has 'alpha1.txt' "the remaining tab keeps its state"

	# The surviving tab still works after the prune.
	send_key h
	settle 1.0
	pane_lacks 'alpha1.txt' "h collapses normally after the prune"

	snapshot tab_close_prunes_state
	assert_log_clean
	stop_session
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

usage() {
	cat <<EOF
Usage: $(basename "$0") [--list] [scenario ...]

Scenarios:
$(printf '  %s\n' "${SCENARIOS[@]}")

TREE_IT_ROOT overrides the temporary root (default /tmp/opencode/tree-it).
TREE_IT_KEEP=1 keeps artifacts even on success.
EOF
}

run_all=1
selected=()
if [ "$#" -gt 0 ]; then
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--list)
		printf '%s\n' "${SCENARIOS[@]}"
		exit 0
		;;
	esac
	run_all=0
	for arg in "$@"; do
		found=0
		for s in "${SCENARIOS[@]}"; do
			if [ "$s" = "$arg" ]; then
				found=1
				break
			fi
		done
		[ "$found" -eq 1 ] || {
			printf 'unknown scenario: %s\n' "$arg" >&2
			usage >&2
			exit 2
		}
		selected+=("$arg")
	done
fi

command -v yazi >/dev/null 2>&1 || fail "yazi is not installed"
command -v tmux >/dev/null 2>&1 || fail "tmux is not installed"
[ -f "$PLUGIN_DIR/main.lua" ] || fail "cannot find main.lua next to tests/"

YAZI_VERSION="$(yazi --version 2>/dev/null | awk '/Version:/ { print $2; exit }')"
case "$YAZI_VERSION" in
26.9.*) ;;
*) fail "yazi ${YAZI_VERSION:-unknown} found; this harness targets 26.9.1" ;;
esac
printf 'yazi %s, tmux %s\n' "$YAZI_VERSION" "$(tmux -V | awk '{print $2}')"

mkdir -p "$ROOT"

ran=0
if [ "$run_all" -eq 1 ]; then
	for s in "${SCENARIOS[@]}"; do
		printf '== %s ==\n' "$s"
		"scenario_$s"
		ran=$((ran + 1))
	done
else
	for s in "${selected[@]}"; do
		printf '== %s ==\n' "$s"
		"scenario_$s"
		ran=$((ran + 1))
	done
fi

printf 'OK: %d scenario(s) passed\n' "$ran"
