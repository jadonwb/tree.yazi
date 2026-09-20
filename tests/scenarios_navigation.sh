# ---------------------------------------------------------------------------
# Navigation scenario suite
#
# Startup shape, lazy expand/collapse at arbitrary depth, symlink rows, and
# cwd re-rooting.
# Sourced by integration.sh after harness.sh; definitions only (never executed).
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
