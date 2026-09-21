# ---------------------------------------------------------------------------
# External-change suite
#
# Bounded polling of expanded directories: the plugin stats every expanded
# directory of the active tree tab once per interval and coalesces a real
# external change into the existing generation-guarded rebuild. These scenarios
# mutate the fixture from bash while Yazi owns the tree and assert the injected
# rows refresh, that collapsed scope/provider Views are left alone, and that the
# log stays clean.
#
# Directory mtime can be coarse (whole seconds) and the tick interval is one
# second, so each scenario settles past one interval after expanding before it
# mutates the fixture. That puts the poller's baseline and the external change
# in different timestamp ticks instead of the same one.
#
# Sourced by integration.sh after harness.sh and scenarios_search.sh;
# definitions only (never executed).
# ---------------------------------------------------------------------------

# Wait until at least one more `rebuild gen=` line exists than `base`.
wait_rebuild_past() {
	local base="$1" i=0
	while [ "$i" -lt 100 ]; do
		if [ "$(rebuild_count)" -gt "$base" ]; then
			return 0
		fi
		sleep 0.1
		i=$((i + 1))
	done
	fail "no rebuild past $base within 10s"
}

# An external create inside a directory that is expanded two levels deep must
# surface without any user action, keep the hovered parent, and leave the
# connector geometry valid.
scenario_external_create_deep() {
	new_env external_create_deep
	write_config true adopt
	make_fixture_deep
	launch "$FIXTURE"

	hovered_is 'alpha' "initial cursor"
	send_key l
	wait_pane_has 'child.txt' 10 "alpha expands"
	send_key j
	settle 0.3
	hovered_is 'beta'
	send_key l
	wait_pane_has 'beta2.txt' 10 "nested beta expands"
	pane_matches '(├─|└─)' "expanded tree renders connectors"

	# Let the poller record its baseline before the external change.
	settle 2.0
	local n0
	n0="$(rebuild_count)"

	printf 'NEW' >"$FIXTURE/alpha/beta/external.txt"
	wait_pane_has 'external.txt' 15 "external create inside an expanded deep directory"
	wait_rebuild_past "$n0"
	log_has 'poll change'
	hovered_is 'beta' "the cursor stays on the expanded parent"
	pane_matches '(├─|└─)' "connectors stay valid after the external create"

	snapshot external_create_deep
	assert_log_clean
	stop_session
}

# An external removal inside an expanded directory drops the injected row.
scenario_external_delete_deep() {
	new_env external_delete_deep
	write_config true adopt
	make_fixture
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	wait_pane_has 'child.txt' 10 "alpha expands"
	settle 2.0

	rm "$FIXTURE/alpha/child.txt"
	wait_pane_lacks 'child.txt' 15 "external delete inside an expanded directory"
	log_has 'poll change'
	pane_has 'alpha' "the expanded parent survives the external delete"

	snapshot external_delete_deep
	assert_log_clean
	stop_session
}

# External deletion of the hovered injected nested row must keep the cursor's
# slot: the next visible survivor takes the deleted row instead of the poll
# rebuild resetting the cursor to the first root row.
scenario_external_delete_hovered_nested() {
	new_env external_delete_hovered_nested
	write_config true adopt
	make_fixture
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	wait_pane_has 'child.txt' 10 "alpha expands"
	send_key j
	settle 0.4
	hovered_is 'child.txt'
	settle 2.0

	rm "$FIXTURE/alpha/child.txt"
	wait_pane_lacks 'child.txt' 15 "external delete of the hovered nested row"
	log_has 'poll change'
	hovered_is 'aa.txt' "the next visible survivor takes the deleted row's slot"
	pane_has 'alpha' "the expanded parent survives"

	snapshot external_delete_hovered_nested
	assert_log_clean
	stop_session
}

# External deletion of the last visible nested row: the expanded directory is
# the final root entry, so its only child is the final row and there is no
# forward survivor. The cursor must clamp back to the parent, not reset to the
# first root row.
scenario_external_delete_last_nested_clamp() {
	new_env external_delete_last_nested_clamp
	write_config true adopt
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/alpha" "$FIXTURE/zeta"
	printf 'Z' >"$FIXTURE/zeta/only.txt"
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key j
	settle 0.4
	hovered_is 'zeta'
	send_key l
	wait_pane_has 'only.txt' 10 "zeta expands"
	send_key j
	settle 0.4
	hovered_is 'only.txt'
	settle 2.0

	rm "$FIXTURE/zeta/only.txt"
	wait_pane_lacks 'only.txt' 15 "external delete of the last nested row"
	log_has 'poll change'
	hovered_is 'zeta' "with no forward survivor the cursor clamps to the parent"
	pane_has 'zeta' "the emptied expanded parent stays expanded"

	snapshot external_delete_last_nested_clamp
	assert_log_clean
	stop_session
}

# An external rename inside an expanded directory replaces the old row with the
# new name.
scenario_external_rename_file_deep() {
	new_env external_rename_file_deep
	write_config true adopt
	make_fixture
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	wait_pane_has 'child.txt' 10 "alpha expands"
	settle 2.0

	mv "$FIXTURE/alpha/child.txt" "$FIXTURE/alpha/renamed.txt"
	wait_pane_has 'renamed.txt' 15 "external rename inside an expanded directory"
	wait_pane_lacks 'child.txt' 15 "the old name is gone after the external rename"
	log_has 'poll change'

	snapshot external_rename_file_deep
	assert_log_clean
	stop_session
}

# The poll rebuild must keep the active hierarchy-aware filter: a matching
# external file appears, a non-matching one stays hidden, and the header
# indicator is unchanged.
scenario_external_filter_preserved() {
	new_env external_filter_preserved
	write_config true adopt
	make_fixture_deep
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	wait_pane_has 'child.txt' 10 "alpha expands before filtering"

	send_key f
	wait_pane_has 'Filter:' 10 "filter popup opens"
	send_text child
	send_key Enter
	wait_header_has 'filter: child' 15 "tree filter indicator"
	wait_pane_has 'child.txt' 15 "matching row stays visible"
	wait_pane_lacks 'zz.txt' 15 "non-matching row is hidden by the filter"
	settle 2.0

	# One matching and one non-matching external child in the expanded alpha.
	printf 'M' >"$FIXTURE/alpha/child_external.txt"
	printf 'N' >"$FIXTURE/alpha/other.txt"
	wait_pane_has 'child_external.txt' 15 "matching external file appears under the active filter"
	settle 1.5
	pane_lacks 'other.txt' "non-matching external file stays hidden"
	pane_lacks 'zz.txt' "non-matching rows stay hidden after the poll rebuild"
	header_has 'filter: child' "filter indicator survives the poll rebuild"

	snapshot external_filter_preserved
	assert_log_clean
	stop_session
}

# Signature comparison must keep an idle expanded tree quiet: no rebuilds over
# several intervals when nothing changed.
scenario_external_no_churn() {
	new_env external_no_churn
	write_config true adopt
	make_fixture
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	wait_pane_has 'child.txt' 10 "alpha expands"
	log_has 'poll start'
	settle 2.0

	local n0
	n0="$(rebuild_count)"
	settle 3.5
	[ "$(rebuild_count)" = "$n0" ] ||
		fail "idle poll rebuilt the tree ($n0 -> $(rebuild_count))"
	pane_has 'child.txt'
	pane_matches '(├─|└─)'

	snapshot external_no_churn
	assert_log_clean
	stop_session
}

# A hidden subtree is an unread boundary while hidden files are off: once an
# expanded `.hidden` directory is hidden, the poller must drop its whole subtree
# from the scoped keys, so an external change inside it drives no rebuild. The
# retained expansion is restored on re-show, when the poll resumes and surfaces
# the external child.
scenario_hidden_poll_excluded() {
	new_env hidden_poll_excluded
	write_config true adopt
	add_hidden_keymap
	make_fixture_hidden
	launch "$FIXTURE"

	# Show hidden and expand `.hidden`; let the poller record its baseline.
	send_key C-h
	settle 0.9
	pane_has '.hidden' "hidden directory appears once shown"
	hovered_is '.hidden' "cursor lands on the shown hidden directory"
	send_key l
	wait_pane_has 'child.txt' 10 "hidden directory expands"
	settle 2.0

	# Hide it: the expanded subtree leaves the visible rows and the poll scope.
	send_key C-h
	settle 2.0
	pane_lacks '.hidden' "hidden directory suppressed on re-hide"
	pane_lacks 'child.txt' "hidden subtree suppressed with its parent"

	local n0
	n0="$(rebuild_count)"

	# Mutate the hidden subtree externally. If it were still polled, the
	# changed directory mtime would drive a rebuild.
	printf 'EXTERNAL' >"$FIXTURE/.hidden/external.txt"
	settle 3.5
	[ "$(rebuild_count)" = "$n0" ] ||
		fail "hidden subtree was polled while hidden ($n0 -> $(rebuild_count))"

	# Show hidden again: the retained expansion resumes the read/poll and the
	# external child appears.
	send_key C-h
	wait_pane_has 'external.txt' 15 "external child surfaces once hidden is shown again"

	snapshot hidden_poll_excluded
	assert_log_clean
	stop_session
}

# A native fd/rg provider View owns its Folder: while it is active the poll loop
# is stopped, an external mutation underneath is ignored (no rebuild, no
# injected tree rows), and the provider rows are untouched.
scenario_external_search_view_ignored() {
	new_env external_search_view_ignored
	write_config_search true adopt
	make_fixture_search
	launch "$FIXTURE"

	search_hover alpha
	send_key l
	wait_pane_has 'a.txt' 10 "alpha expands before the search"
	settle 2.0

	send_key s
	wait_pane_has 'Search via fd:' 10 "search input opens"
	send_text txt
	send_key Enter
	wait_header_has '(search: txt)' 15 "search view header marker"
	wait_line 15 '1/6'
	log_has 'poll stop' "entering the provider view stops the poll loop"

	local n0
	n0="$(rebuild_count)"
	printf 'X' >"$FIXTURE/alpha/beta/external_under_view.txt"
	settle 3.5
	[ "$(rebuild_count)" = "$n0" ] ||
		fail "poll rebuilt while a provider view owned the tab"
	pane_lacks_re '(├─|└─)' "provider view must not gain tree rows"
	header_has '(search: txt)'

	snapshot external_search_view_ignored
	assert_log_clean
	stop_session
}

# An external same-filesystem rename of an expanded directory is preserved: the
# poll matches the directory by its (dev, btime) identity in a reachable parent,
# remaps the whole expansion prefix, and the subtree stays expanded at the new
# URL with the cursor following it. No user re-expansion happens here.
scenario_external_rename_dir_preserved() {
	new_env external_rename_dir_preserved
	write_config true adopt
	make_fixture_rename_dir
	launch "$FIXTURE"
	settle 0.5

	hovered_is 'alpha' "initial cursor"
	send_key l
	wait_pane_has 'top.txt' 10 "alpha expands"
	send_key j
	settle 0.3
	hovered_is 'beta'
	send_key l
	wait_pane_has 'beta.txt' 10 "beta expands"
	send_key j
	settle 0.3
	hovered_is 'gamma'
	send_key l
	wait_pane_has 'leaf.txt' 10 "gamma expands"
	settle 2.0

	mv "$FIXTURE/alpha/beta" "$FIXTURE/alpha/beta2"
	wait_pane_has 'beta2' 15 "the renamed directory appears"
	wait_pane_has 'leaf.txt' 15 "the deep subtree stays expanded at the new URL"
	hovered_is 'gamma' "the cursor follows the moved directory"
	pane_matches '(├─|└─)' "connectors stay valid after the external rename"
	log_has 'poll remap'
	log_has 'moves=1'
	log_has 'poll change'

	snapshot external_rename_dir_preserved
	assert_log_clean
	stop_session
}

# An external delete+recreate at the same path is unmatched by identity, so the
# stale expansion is pruned: the recreated directory stays collapsed and a later
# manual expansion still works.
scenario_external_recreate_prunes() {
	new_env external_recreate_prunes
	write_config true adopt
	make_fixture_deep
	launch "$FIXTURE"
	settle 0.5

	hovered_is 'alpha'
	send_key l
	wait_pane_has 'child.txt' 10 "alpha expands"
	send_key j
	settle 0.3
	hovered_is 'beta'
	send_key l
	wait_pane_has 'beta2.txt' 10 "beta expands"
	settle 2.0

	rm -rf "$FIXTURE/alpha/beta"
	mkdir -p "$FIXTURE/alpha/beta"
	printf 'NEW' >"$FIXTURE/alpha/beta/newfile.txt"
	wait_pane_lacks 'beta2.txt' 15 "the expanded subtree drops after the external replace"
	log_has 'poll remap'
	log_has 'prunes=1'
	settle 1.5
	pane_lacks 'newfile.txt' "a recreated old path must stay collapsed"

	# The key was pruned, not wedged: an explicit expansion still works.
	hovered_is 'beta' "the cursor stays on the recreated directory"
	send_key l
	wait_pane_has 'newfile.txt' 10 "the recreated directory expands on demand"

	snapshot external_recreate_prunes
	assert_log_clean
	stop_session
}

# A content-only write to the hovered injected nested file changes neither the
# parent directory's mtime nor any visible row metadata, so the poll must stat
# that one file and drive the existing rebuild, which refreshes the preview.
scenario_external_preview_write_refresh() {
	new_env external_preview_write_refresh
	write_config true adopt
	make_fixture
	launch "$FIXTURE"
	settle 0.5

	send_key V
	wait_pane_has '│' 10 "preview pane visible"
	settle 0.3
	hovered_is 'alpha'
	send_key l
	wait_pane_has 'child.txt' 10 "alpha expands"
	send_key j
	settle 0.3
	hovered_is 'child.txt' "hover the injected nested file"
	wait_pane_has 'child data' 10 "the preview shows the file content"
	settle 2.0

	printf 'PREVIEW_TOKEN_ONE\n' >"$FIXTURE/alpha/child.txt"
	wait_pane_has 'PREVIEW_TOKEN_ONE' 15 "preview must refresh without collapse/re-expand"
	log_has 'poll change'
	hovered_is 'child.txt' "the cursor stays on the written file"

	snapshot external_preview_write_refresh
	assert_log_clean
	stop_session
}

# A native Full folder reload (interactive `refresh`, or window focus after an
# external save marks the folder stale) replaces the cwd Folder's entries
# wholesale. Because the tab's sort is pinned to `none` the reload is a flat
# read_dir listing with the injected descendants gone. Subscribing to the DDS
# `load` event must replay the previous injected rows synchronously, restore the
# row hovered before the reload, and then rebuild once that load lands.
scenario_load_full_reassert() {
	new_env load_full_reassert
	write_config true adopt
	# Stock has no `refresh` binding on this build; add a scenario-local one so
	# the test can emit the same Full reload a FocusIn would. `prepend_keymap`
	# shadows the stock `<C-r>` select-all toggle for this scenario only.
	cat >>"$CFG/keymap.toml" <<'TOML'

[[mgr.prepend_keymap]]
on = "<C-r>"
run = "refresh"
TOML
	make_fixture
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	wait_pane_has 'child.txt' 10 "alpha expands"
	pane_matches '(├─|└─)' "the injected nested row renders a connector"
	settle 0.5
	pane_has 'child.txt' "the nested row stays before the refresh"

	# Hover the injected nested row so the repair can restore it, then wait past
	# one poll interval so the poll loop records it as the last hovered row.
	send_key j
	settle 0.4
	hovered_is 'child.txt' "hover the injected nested row before the refresh"
	settle 1.5

	local n0
	n0="$(rebuild_count)"

	# An external root-level save changes the cwd directory's stat (and the
	# watcher marks the folder stale), so the stock `refresh` below becomes a
	# forced Full reload. Wait for the watcher's Upserting to land first.
	printf 'EXTERNAL' >"$FIXTURE/root_external.txt"
	wait_pane_has 'root_external.txt' 10 "the external root file appears"

	# The Full reload drops the injected rows; the load handler must replay them
	# synchronously and reassert, without any user action.
	send_key C-r
	wait_log_has 5 'full load replay' \
		"the load handler replays the injected rows"
	wait_rebuild_past "$n0"
	wait_pane_has 'child.txt' 15 "the nested row is back after the native Full load"
	settle 0.5
	pane_matches '(├─|└─)' "connectors are restored, not a flat depth-0 listing"
	line_before 'alpha' 'child.txt' "the nested row stays beneath its parent root"
	hovered_is 'child.txt' "the previously hovered nested row is hovered again"

	snapshot load_full_reassert
	assert_log_clean
	stop_session
}
