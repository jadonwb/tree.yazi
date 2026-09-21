# ---------------------------------------------------------------------------
# Navigation scenario suite
#
# Startup shape, lazy expand/collapse at arbitrary depth, symlink rows, cwd
# re-rooting, hidden-subtree suppression, and rendering styles/glyphs.
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

# Hidden-toggle subtree suppression: while hidden files are off, a hidden
# directory and its entire injected subtree are suppressed (no orphaned child
# left behind by native per-entry filtering), while the saved expansion is
# preserved so re-showing hidden restores both rows.
scenario_hidden_toggle_subtree() {
	new_env hidden_toggle_subtree
	write_config true adopt
	add_hidden_keymap
	make_fixture_hidden
	launch "$FIXTURE"

	# Hidden off at launch: the dotfile directory and its child are absent.
	pane_lacks '.hidden' "hidden directory absent while hidden is off"
	pane_lacks 'child.txt' "hidden subtree absent while hidden is off"
	pane_has 'keep'
	pane_has 'plain.txt'

	# Show hidden, expand `.hidden` (it sorts before `keep`), assert its child.
	send_key C-h
	settle 0.9
	pane_has '.hidden' "hidden directory appears once shown"
	# `.hidden` sorts first, so the toggle leaves the cursor on it.
	hovered_is '.hidden' "cursor lands on the shown hidden directory"
	send_key l
	settle 1.0
	pane_has 'child.txt' "expanded hidden child renders"

	# Hide again: the expanded hidden directory must take its whole subtree with
	# it, and the visible siblings must remain.
	send_key C-h
	settle 0.9
	pane_lacks '.hidden' "hidden directory suppressed on re-hide"
	pane_lacks 'child.txt' "expanded hidden child suppressed with its parent"
	pane_has 'keep'
	pane_has 'plain.txt'

	# Show once more: the preserved expansion restores both rows.
	send_key C-h
	settle 0.9
	pane_has '.hidden' "hidden directory restored on re-show"
	pane_has 'child.txt' "expansion preserved across the hide/show cycle"

	snapshot hidden_toggle_subtree
	assert_log_clean
	stop_session
}

# style = "indent": the injected child is prefixed with plain repeated spaces
# instead of connector glyphs, and the tree still expands, hovers, and collapses.
scenario_render_indent() {
	new_env render_indent
	write_config_render indent ""
	make_fixture
	launch "$FIXTURE"

	hovered_is 'alpha' "initial cursor"
	send_key l
	settle 0.9
	pane_has 'child.txt' "expanded child renders in indent style"
	# Depth-1 prefix is DEFAULT_GLYPHS.space ("   "), so the child row starts
	# with three spaces and no branch/last connector glyph appears at all.
	pane_matches '^   .*child\.txt' "injected child is indented with plain spaces"
	pane_lacks '├─' "no branch connector in indent style"
	pane_lacks '└─' "no last connector in indent style"

	send_key j
	settle 0.4
	hovered_is 'child.txt' "indent rows still take the cursor"
	capture | tail -n 1 | grep -qF '2/4' || fail "status position should be 2/4 on the child"

	send_key h
	settle 0.9
	hovered_is 'alpha' "indent rows still collapse onto the parent"
	pane_lacks 'child.txt'
	log_has 'render style=.*indent'

	snapshot render_indent
	assert_log_clean
	stop_session
}

# glyphs overrides: an equal-width custom set is applied to every connector; a
# set whose widths differ is ignored wholesale so the defaults still render.
scenario_glyphs_override() {
	new_env glyphs_override
	write_config_render lines '{ branch = " > ", last = " > ", vertical = " | ", space = "   " }'
	make_fixture
	launch "$FIXTURE"

	hovered_is 'alpha' "initial cursor"
	send_key l
	settle 0.9
	pane_has 'child.txt' "expanded child renders under custom glyphs"
	pane_has ' > ' "equal-width custom branch glyph renders"
	pane_lacks '└─' "custom glyphs replace the default last connector"

	# Inconsistent widths (branch is 2 cells, the rest 3) are rejected as a
	# set, so the resolver keeps DEFAULT_GLYPHS.
	stop_session
	write_config_render lines '{ branch = " >", last = " > ", vertical = " | ", space = "   " }'
	launch "$FIXTURE"
	hovered_is 'alpha' "initial cursor after relaunch"
	send_key l
	settle 0.9
	pane_has 'child.txt' "expanded child renders under fallback glyphs"
	pane_has '└─' "inconsistent custom glyph widths fall back to the defaults"
	pane_lacks ' > ' "invalid custom glyphs are not applied"
	log_has 'ignoring glyph overrides'

	snapshot glyphs_override
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
	pane_lacks '└─' "revealed nested file must be depth-0 (flush-left)"

	snapshot reroot
	assert_log_clean
	stop_session
}
