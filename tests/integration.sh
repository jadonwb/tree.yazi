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
#   tests/integration.sh --jobs 4        # run scenarios 4 at a time (Bash 5.1+)
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
# Absolute path to this script, used to re-execute one child per scenario in
# parallel mode (children are executed, never sourced).
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
ROOT_BASE="${TREE_IT_ROOT:-/tmp/opencode/tree-it}"
STAMP="$(date +%s)-$$-${RANDOM}"
ROOT="$ROOT_BASE/$STAMP"
SOCK="tree-it-$STAMP"
KEEP="${TREE_IT_KEEP:-0}"

COLS=110
ROWS=32

# Build this harness targets. Both the earlier b8973fb-era build and 0ea4c5d
# report 26.9.1, so the revision is what distinguishes the lstat/File contract.
EXPECTED_VERSION="26.9.1"
EXPECTED_REVISION="0ea4c5d"

SCENARIOS=(
	startup
	expand_collapse
	hidden_toggle_subtree
	render_indent
	glyphs_override
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
	rename_visual
	rename_selected_committed
	create
	create_overwrite
	create_collisions
	bulk_create
	bulk_create_collision
	paste
	cut_paste
	cut_paste_keeps_selection
	remove_trash
	remove_delete
	remove_dir_trash
	remove_multi
	remove_hovered_elsewhere_preserved
	remove_hovered_root_fallback
	remove_subtree_inside_fallback
	remove_last_child_keeps_expanded
	remove_root_middle_next
	remove_filtered_middle_next
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
	sort_live_mtime
	sort_live_natural
	sort_live_random
	sort_live_translit
	sort_live_reverse
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
	search_fd_tree
	search_fd_classic
	search_rg_tree
	search_rg_classic
	search_rerun
	search_stock_filter
	search_toggle_defer
	external_create_deep
	external_delete_deep
	external_delete_hovered_nested
	external_delete_last_nested_clamp
	external_rename_file_deep
	external_filter_preserved
	external_no_churn
	hidden_poll_excluded
	external_search_view_ignored
	external_rename_dir_preserved
	external_recreate_prunes
	external_preview_write_refresh
	load_full_reassert
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

# Harness support library (reporting/lifecycle, environment/fixtures, tmux, assertions).
. "$HERE/harness.sh"

# Navigation suite: startup shape, expand/collapse, symlinks, re-rooting,
# hidden-subtree suppression, rendering styles/glyphs.
. "$HERE/scenarios_navigation.sh"

# Filter suite: native/tree hand-off and filter toggle/roundtrip.
. "$HERE/scenarios_filter.sh"

# Rename suite: nested/deep/dir/root renames and overwrite prompts.
. "$HERE/scenarios_rename.sh"

# Create/paste suite: target-aware create, collisions, yank/paste/cut.
. "$HERE/scenarios_create_paste.sh"

# Remove suite: trash/delete and focus retention.
. "$HERE/scenarios_remove.sh"

# Persistence suite: saved-root/expansion restore.
. "$HERE/scenarios_persistence.sh"

# Mode suite: mode toggling and per-tab saved-root isolation.
. "$HERE/scenarios_modes.sh"

# Tab-local scenario suite (tab mode/preview/state, cross-tab saved-state, tab close).
. "$HERE/scenarios_tabs.sh"

# Search-view suite: native fd/rg Views in tree and classic tabs (cd/rebuild/render).
. "$HERE/scenarios_search.sh"

# External-change suite: bounded polling of expanded directories (create/delete/
# rename visibility, filter/hover retention, provider-view scope, no idle churn).
. "$HERE/scenarios_external.sh"

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

usage() {
	cat <<EOF
Usage: $(basename "$0") [--list] [--jobs N] [scenario ...]

Targets Yazi ${EXPECTED_VERSION} (${EXPECTED_REVISION}).

Scenarios:
$(printf '  %s\n' "${SCENARIOS[@]}")

--jobs N runs each selected scenario in its own child process, at most N at a
time. Each child gets its own STAMP-derived root and tmux server; per-job logs
and exit codes are collected under the parent's TREE_IT_ROOT as indexed
NNNN-<scenario>.log/.rc files and failures are replayed in scenario order. N
must be a positive integer and --jobs must come first.

TREE_IT_ROOT overrides the temporary root (default /tmp/opencode/tree-it).
TREE_IT_KEEP=1 keeps artifacts even on success.
EOF
}

# Terminate every tracked in-flight job. Each job is launched with setsid, so
# its recorded PID is both the real integration.sh child and its own
# process-group leader; send TERM to that group only when ps proves pid == pgid,
# otherwise fall back to the direct PID. No wildcard process cleanup is used:
# the child's own EXIT cleanup (harness.sh) tears down its private tmux
# server/yazi and applies TREE_IT_KEEP.
parallel_terminate() {
	trap - INT TERM
	local p pg
	for p in "${parallel_pids[@]}"; do
		[ -n "$p" ] || continue
		# Every step is guarded so a stale PID cannot abort the handler via
		# errexit before the live jobs are signalled.
		pg="$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')" || pg=""
		if [ -n "$pg" ]; then
			if [ "$pg" = "$p" ]; then
				kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
			else
				kill -TERM "$p" 2>/dev/null || true
			fi
		fi
	done
	exit 130
}

# INT/TERM trap for --jobs runs. A job is launched and its PID recorded in a
# short critical section; a signal delivered in that window would otherwise be
# applied before the newest child could be tracked and would leak it. While the
# critical section is active, record a pending interrupt and return; the launch
# code calls parallel_terminate as soon as the PID is safely recorded.
parallel_interrupt() {
	if [ "${parallel_launching:-0}" -ne 0 ]; then
		parallel_pending=1
		return 0
	fi
	parallel_terminate
}

# Run each scenario in its own integration.sh child (no --jobs), at most
# $jobs at a time. Each job gets a zero-padded index used as its identity, so
# duplicate scenario names execute and report independently; per-job
# stdout/stderr and exit status go to $ROOT/jobs/NNNN-<scenario>.log and .rc,
# and failures are replayed in scenario order. Children inherit
# TREE_IT_ROOT/TREE_IT_KEEP and each derives its own STAMP-derived ROOT and
# tmux SOCK.
run_parallel() {
	local jobs="$1"
	shift
	local -a queue=("$@")
	local outdir="$ROOT/jobs"
	local i=0 running=0 total=0 failed=0 done_pid done_idx rc id s

	mkdir -p "$outdir"
	printf 'parallel: %d scenario(s), --jobs %d\n' "${#queue[@]}" "$jobs"

	# Globals, visible to parallel_interrupt (do not mark local).
	parallel_pids=()
	parallel_log=()
	parallel_rc=()
	parallel_name=()
	parallel_launching=0
	parallel_pending=0
	declare -A parallel_index=()

	trap 'parallel_interrupt' INT TERM

	for s in "${queue[@]}"; do
		id="$(printf '%04d' "$i")"
		parallel_name[$i]="$s"
		parallel_log[$i]="$outdir/$id-$s.log"
		parallel_rc[$i]="$outdir/$id-$s.rc"
		# Critical section: a signal here must not miss the child whose PID
		# has not been recorded yet.
		parallel_launching=1
		setsid "$SELF" "$s" >"${parallel_log[$i]}" 2>&1 &
		parallel_pids[$i]=$!
		parallel_index[$!]=$i
		parallel_launching=0
		[ "$parallel_pending" -eq 0 ] || parallel_terminate
		i=$((i + 1))
		running=$((running + 1))
		while [ "$running" -ge "$jobs" ]; do
			if wait -n -p done_pid; then rc=0; else rc=$?; fi
			done_idx="${parallel_index[$done_pid]:-}"
			if [ -n "$done_idx" ]; then
				echo "$rc" >"${parallel_rc[$done_idx]}"
				# Prune the reaped PID immediately so a later interrupt can
				# never signal a reused PID or process group.
				unset "parallel_pids[$done_idx]"
			fi
			unset "parallel_index[$done_pid]"
			running=$((running - 1))
		done
	done
	while [ "$running" -gt 0 ]; do
		if wait -n -p done_pid; then rc=0; else rc=$?; fi
		done_idx="${parallel_index[$done_pid]:-}"
		if [ -n "$done_idx" ]; then
			echo "$rc" >"${parallel_rc[$done_idx]}"
			unset "parallel_pids[$done_idx]"
		fi
		unset "parallel_index[$done_pid]"
		running=$((running - 1))
	done
	trap - INT TERM

	total=${#queue[@]}
	for ((i = 0; i < total; i++)); do
		rc=1
		[ -f "${parallel_rc[$i]}" ] && rc="$(cat "${parallel_rc[$i]}")"
		if [ "$rc" -ne 0 ] 2>/dev/null; then
			failed=$((failed + 1))
			printf '\n== FAIL %s (job %04d, exit %s) ==\n' "${parallel_name[$i]}" "$i" "$rc" >&2
			[ -f "${parallel_log[$i]}" ] && cat "${parallel_log[$i]}" >&2
		fi
	done

	if [ "$failed" -ne 0 ]; then
		printf 'FAILED: %d/%d scenario(s)\n' "$failed" "$total" >&2
		return 1
	fi
	printf 'OK: %d scenario(s) passed\n' "$total"
	return 0
}

run_all=1
selected=()
JOBS=0

# Opt-in parallel mode. Only recognized as the first argument, and never
# forwarded to children, so parallel mode cannot recurse.
if [ "$#" -gt 0 ] && [ "$1" = "--jobs" ]; then
	if [ "$#" -lt 2 ]; then
		printf '%s\n' '--jobs requires a positive integer' >&2
		usage >&2
		exit 2
	fi
	JOBS="$2"
	case "$JOBS" in
	'' | *[!0-9]*)
		printf 'invalid --jobs value: %s\n' "$JOBS" >&2
		usage >&2
		exit 2
		;;
	0)
		printf '%s\n' '--jobs must be at least 1' >&2
		usage >&2
		exit 2
		;;
	esac
	# Parallel mode relies on `wait -n -p`, added in Bash 5.1. Serial and
	# --list runs work on older Bash, so guard only when --jobs is requested.
	if [ "${BASH_VERSINFO[0]}" -lt 5 ] ||
		{ [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -lt 1 ]; }; then
		printf 'parallel --jobs requires Bash 5.1 or newer (found %s)\n' "${BASH_VERSION:-unknown}" >&2
		usage >&2
		exit 2
	fi
	shift 2
fi

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
YAZI_REVISION="$(yazi --version 2>/dev/null | sed -n 's/.*Version: *[^ ]* *(\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' | head -n1)"
case "$YAZI_VERSION" in
"$EXPECTED_VERSION") ;;
*) fail "yazi ${YAZI_VERSION:-unknown} found; this harness targets ${EXPECTED_VERSION} (${EXPECTED_REVISION})" ;;
esac
case "$YAZI_REVISION" in
"$EXPECTED_REVISION") ;;
*) fail "yazi ${YAZI_VERSION} (${YAZI_REVISION:-unknown revision}) found; this harness targets ${EXPECTED_VERSION} (${EXPECTED_REVISION})" ;;
esac
printf 'yazi %s (%s), tmux %s\n' "$YAZI_VERSION" "$YAZI_REVISION" "$(tmux -V | awk '{print $2}')"

scenarios_run=()
if [ "$run_all" -eq 1 ]; then
	scenarios_run=("${SCENARIOS[@]}")
else
	scenarios_run=("${selected[@]}")
fi

mkdir -p "$ROOT"

if [ "$JOBS" -gt 0 ]; then
	if run_parallel "$JOBS" "${scenarios_run[@]}"; then
		exit 0
	fi
	exit 1
fi

ran=0
for s in "${scenarios_run[@]}"; do
	printf '== %s ==\n' "$s"
	"scenario_$s"
	ran=$((ran + 1))
done

printf 'OK: %d scenario(s) passed\n' "$ran"
