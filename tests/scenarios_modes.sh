# ---------------------------------------------------------------------------
# Mode scenario suite
#
# Mode toggling, per-tab saved-root isolation, and teardown.
# Sourced by integration.sh after harness.sh; definitions only (never executed).
# ---------------------------------------------------------------------------

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
