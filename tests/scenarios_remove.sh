# ---------------------------------------------------------------------------
# Remove scenario suite
#
# Trash/delete of nested and multi rows plus focus retention across removed,
# saved, and filtered subtrees.
# Sourced by integration.sh after harness.sh; definitions only (never executed).
# ---------------------------------------------------------------------------

# Stock d (trash) on an injected nested file: the row disappears immediately,
# the sibling and other branches survive, and focus keeps the deleted row's slot
# by falling to the next visible sibling.
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
	hovered_is 'child2.txt' "next visible sibling takes the deleted row's slot"
	header_has "$FIXTURE"
	log_has 'trash event urls=1 pruned_expanded=0.*focus=.*child2'
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
	hovered_is 'gamma' "the first survivor after the branch takes the deleted slot"
	log_has 'delete event urls=1.*focus=.*gamma'
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
	hovered_is 'child1.txt' "the next survivor after the removed subtree takes the slot"
	log_has 'trash event urls=1 pruned_expanded=1.*focus=.*child1'
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

# Deletion focus, case 2: the hovered root-level file is removed and it is the
# last visible row. Its parent is the tree root (not a row) and there is no next
# survivor, so the cursor clamps back to the nearest prior surviving row,
# matching stock's `.min(len-1)` end-of-list clamp.
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
# forward to the first survivor after the removed subtree.
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
	hovered_is 'root.txt' "the next survivor after the removed subtree takes the slot"

	snapshot remove_subtree_inside_fallback
	assert_log_clean
	stop_session
}

# Deleting the only child of an expanded directory keeps the directory expanded
# (stock has no expansion state and never collapses on delete) and moves focus
# forward to the next visible row after the branch.
scenario_remove_last_child_keeps_expanded() {
	new_env remove_last_child_keeps_expanded
	write_config true adopt
	rm -rf "$FIXTURE"
	mkdir -p "$FIXTURE/alpha" "$FIXTURE/gamma"
	printf 'ONLY' >"$FIXTURE/alpha/only.txt"
	printf 'G1' >"$FIXTURE/gamma/g1.txt"
	printf 'ROOT' >"$FIXTURE/root.txt"
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'only.txt'
	send_key j
	settle 0.4
	hovered_is 'only.txt'

	send_key d
	settle 0.6
	pane_has 'Trash 1 selected file?'
	send_key y
	settle 2.4

	file_absent "$FIXTURE/alpha/only.txt"
	pane_lacks 'only.txt' "the deleted child row is gone"
	pane_has 'alpha' "the emptied expanded parent stays expanded"
	hovered_is 'gamma' "the next visible row takes the deleted child's slot"
	log_has 'trash event urls=1 pruned_expanded=0.*focus=.*gamma'

	snapshot remove_last_child_keeps_expanded
	assert_log_clean
	stop_session
}

# Deleting a root-level file in the middle of the list moves focus to the next
# visible row (stock keeps the cursor's slot), never back to the previous row.
scenario_remove_root_middle_next() {
	new_env remove_root_middle_next
	write_config true adopt
	make_fixture_remove
	printf 'Z' >"$FIXTURE/zeta.txt"
	launch "$FIXTURE"

	# Root order: alpha, gamma, root.txt, zeta.txt.
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
	hovered_is 'zeta.txt' "the next visible row takes the deleted root's slot"
	log_has 'delete event urls=1.*focus=.*zeta'

	snapshot remove_root_middle_next
	assert_log_clean
	stop_session
}

# Deletion focus under an active tree filter when the hovered filtered row is
# removed: the filtered visible sequence is the candidate set, so the next
# visible match takes the slot and the filter stays applied.
scenario_remove_filtered_middle_next() {
	new_env remove_filtered_middle_next
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

	send_key d
	settle 0.6
	pane_has 'Trash 1 selected file?'
	send_key y
	settle 2.4

	file_absent "$FIXTURE/alpha/child1.txt"
	pane_lacks 'child1.txt'
	hovered_is 'child2.txt' "the next visible match takes the deleted row's slot"
	header_has '(filter: child)' "tree filter survives the removal rebuild"
	log_has 'trash event urls=1.*focus=.*child2'

	snapshot remove_filtered_middle_next
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
