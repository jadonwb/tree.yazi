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

# Extra values for the optional third argument: "search" omits the `s`/`S` sort
# bindings entirely so Yazi's preset `search --via=fd` / `--via=rg` bindings
# apply (a user prepend of the same action does not open the search input on
# this build). write_config_search is the named wrapper; every existing
# two-argument call keeps the sort bindings.
write_config() {
	local tree="$1" mode="$2" search="${3:-}"
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

TOML
	if [ "$search" != "search" ]; then
		cat >>"$CFG/keymap.toml" <<'TOML'

[[mgr.prepend_keymap]]
on = "s"
run = "sort size --reverse=no"

[[mgr.prepend_keymap]]
on = "S"
run = "sort mtime --reverse=no"
TOML
	fi
	cat >>"$CFG/keymap.toml" <<'TOML'

# Close the second tab by index (0-based) while another tab stays active, so a
# background tab close can be exercised.
[[mgr.prepend_keymap]]
on = "X"
run = "tab_close 1"
TOML
}

# Search-view config: native fd/rg search bindings instead of the sort bindings.
write_config_search() {
	write_config "$1" "$2" search
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

# search fixture: six .txt files (three nested under alpha/) where only three
# contain NEEDLE, so fd (name match `txt`) and rg (content match `NEEDLE`) return
# different result sets. fd txt -> 6 rows (4 carry a path separator); rg NEEDLE
# -> 3 rows (2 carry a path separator).
make_fixture_search() {
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/alpha/beta/gamma" "$FIXTURE/plain"
	printf 'NEEDLE' >"$FIXTURE/top.txt"
	printf 'NEEDLE' >"$FIXTURE/alpha/a.txt"
	printf 'NEEDLE' >"$FIXTURE/alpha/beta/b.txt"
	printf 'NOPE' >"$FIXTURE/alpha/beta/gamma/c.txt"
	printf 'NOPE' >"$FIXTURE/other.txt"
	printf 'NOPE' >"$FIXTURE/plain/p.txt"
}

# Deterministic no-op block editor for stock bulk rename: records the temp list
# it is handed into $DIR/selected.txt and exits 0, so bulk rename sees no name
# changes and returns without prompting. Used to observe that stock bulk rename
# ran without depending on the host's vi.
make_noop_editor() {
	cat >"$DIR/editor.sh" <<SH
#!/bin/sh
cp "\$1" "$DIR/selected.txt"
exit 0
SH
	chmod +x "$DIR/editor.sh"
}

# ---------------------------------------------------------------------------
# tmux driving
# ---------------------------------------------------------------------------

# launch <cwd> [extra env assignments]. The optional extra_env string is
# inserted into the tmux `env ...` command, so callers pass e.g.
# "EDITOR='$DIR/editor.sh'" to inject a deterministic editor.
launch() {
	local cwd="$1" extra_env="${2:-}"
	SESSION="t-${STAMP}-$((RANDOM))"
	tmux -L "$SOCK" -u new-session -d -s "$SESSION" -x "$COLS" -y "$ROWS" \
		"env YAZI_CONFIG_HOME='$CFG' XDG_STATE_HOME='$STATE' XDG_RUNTIME_DIR='$RUN' YAZI_LOG=debug $extra_env yazi --cwd-file='$CWD_FILE' '$cwd'"
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

# Wait until the active pane is interactive AND its folder has finished
# loading. The status line alone reaches `NOR` while the current folder can
# still be in Yazi's native `Loading...` stage (the stock current component
# renders that placeholder whenever `folder.stage()` is not done), so scenarios
# must not proceed on the status line alone. A loaded folder renders its
# entries, or `No items` when empty, hence the absence of the loading
# placeholder is the readiness condition. A pane that never leaves the loading
# state still fails within the same bounded wait, with a folder-specific
# diagnostic instead of a downstream assertion failure.
wait_ready() {
	local i=0 pane frame=0
	while [ "$i" -lt 200 ]; do
		pane="$(tmux -L "$SOCK" capture-pane -p -t "$SESSION" 2>/dev/null || true)"
		if printf '%s\n' "$pane" | grep -q 'NOR'; then
			frame=1
			if ! printf '%s\n' "$pane" | grep -qF 'Loading...'; then
				return 0
			fi
		fi
		sleep 0.05
		i=$((i + 1))
	done
	if [ "$frame" -eq 1 ]; then
		fail "yazi did not finish loading the active folder within 10s"
	fi
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

# ---------------------------------------------------------------------------
# Bounded waits
#
# fd/rg streaming and the plugin's cd/rebuild callbacks are asynchronous, so a
# single capture is racy. Wait helpers poll one condition every 0.1s until a
# timeout (default 15s) and then fail (fail already dumps the pane and log).
# ---------------------------------------------------------------------------

# Poll a predicate until it passes or the try budget runs out.
_wait_for() {
	local tries="$1"; shift
	local i=0
	while [ "$i" -lt "$tries" ]; do
		if "$@"; then
			return 0
		fi
		sleep 0.1
		i=$((i + 1))
	done
	return 1
}

_w_pane_has() { capture | grep -qF -- "$1"; }
_w_pane_lacks() { ! capture | grep -qF -- "$1"; }
_w_header_has() { capture | head -n 1 | grep -qF -- "$1"; }
_w_header_lacks() { ! capture | head -n 1 | grep -qF -- "$1"; }
_w_line_has() { capture | tail -n 1 | grep -qF -- "$1"; }
_w_log_has() { grep -qE -- "$1" "$LOG"; }
_w_file_exists() { [ -e "$1" ]; }

wait_pane_has() {
	_wait_for "$((${2:-15} * 10))" _w_pane_has "$1" ||
		fail "${3:-pane should contain within ${2:-15}s} '$1'"
	return 0
}

wait_pane_lacks() {
	_wait_for "$((${2:-15} * 10))" _w_pane_lacks "$1" ||
		fail "${3:-pane should not contain within ${2:-15}s} '$1'"
	return 0
}

wait_header_has() {
	_wait_for "$((${2:-15} * 10))" _w_header_has "$1" ||
		fail "${3:-header should contain within ${2:-15}s} '$1'"
	return 0
}

wait_header_lacks() {
	_wait_for "$((${2:-15} * 10))" _w_header_lacks "$1" ||
		fail "${3:-header should not contain within ${2:-15}s} '$1'"
	return 0
}

# Wait for the status line (last pane row) to contain a literal like '1/6'.
wait_line() {
	_wait_for "$((${1:-15} * 10))" _w_line_has "$2" ||
		fail "${3:-status line should contain within ${1:-15}s} '$2'"
	return 0
}

wait_log_has() {
	_wait_for "$((${1:-15} * 10))" _w_log_has "$2" ||
		fail "${3:-log should match within ${1:-15}s} /$2/"
	return 0
}

# Bounded wait for a filesystem path (file_exists would fail on first miss).
wait_file_exists() {
	_wait_for "$((${2:-15} * 10))" _w_file_exists "$1" ||
		fail "${3:-file should exist within ${2:-15}s} '$1'"
	return 0
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

# ERE assertion over the whole pane, for cases a literal cannot express (for
# example a connector glyph and a result row on the same line).
pane_matches() {
	if capture | grep -qE -- "$1"; then
		return 0
	fi
	fail "${2:-pane should match} /$1/"
}

# Negative ERE assertion over the whole pane.
pane_lacks_re() {
	if capture | grep -qE -- "$1"; then
		fail "${2:-pane should not match} /$1/"
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

# Count log lines matching an ERE (0 when none, so it is safe under set -e).
log_count() {
	grep -acE -- "$1" "$LOG" || true
}

rebuild_count() {
	log_count 'rebuild gen='
}

# Root recorded by the most recent `cd restore` debug line. ya.dbg renders the
# ` root=` label and the value as separate quoted arguments, so the value sits
# between `root=" "` and the next `"`.
last_cd_root() {
	grep -a 'cd restore' "$LOG" | tail -n 1 | sed -n 's/.*root=" *"\([^"]*\)".*/\1/p'
}

# Count of `cd search view` debug lines: one per real provider-view entry, so an
# identical re-run (which Yazi's Cd actor short-circuits) adds none.
search_view_count() {
	log_count 'cd search view'
}

# Root recorded by the most recent `cd search view` debug line.
last_search_view_root() {
	grep -a 'cd search view' "$LOG" | tail -n 1 | sed -n 's/.*root=" *"\([^"]*\)".*/\1/p'
}

# Root in effect at the most recent rebuild: the last `cd restore` at or before
# the final `rebuild gen=` line (rebuild itself never logs its cwd).
last_rebuild_root() {
	local rline cline
	rline="$(grep -an 'rebuild gen=' "$LOG" | tail -n 1 | cut -d: -f1)"
	[ -n "$rline" ] || return 0
	cline="$(head -n "$rline" "$LOG" | grep -a 'cd restore' | tail -n 1)"
	[ -n "$cline" ] || return 0
	printf '%s' "$cline" | sed -n 's/.*root=" *"\([^"]*\)".*/\1/p'
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
