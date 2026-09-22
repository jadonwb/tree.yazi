# ---------------------------------------------------------------------------
# Filter scenario suite
#
# Native/tree filter parity, filter-mode hand-off wrappers, and the filter
# toggle/roundtrip policy.
# Sourced by integration.sh after harness.sh; definitions only (never executed).
# ---------------------------------------------------------------------------

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
	# The stock-width (80) top-center popup overlaps the right edge of deeper
	# rows, so the child row's tail is clipped while the popup is open.
	pane_has 'child' "filtered child row visible"
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
	# The stock-width (80) popup overlaps the right edge of deeper rows, so
	# the child row's tail is clipped while the popup is open.
	pane_has 'gamma1'
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
	# The stock-width (80) popup overlaps the right edge of deeper rows, so
	# the child row's tail is clipped while the popup is open.
	pane_has 'gamma1'
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
