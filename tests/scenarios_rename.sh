# ---------------------------------------------------------------------------
# Rename scenario suite
#
# Inline rename of nested, deep, directory, and root rows plus overwrite
# prompts.
# Sourced by integration.sh after harness.sh; definitions only (never executed).
# ---------------------------------------------------------------------------

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
	pane_has 'Overwrite file?' "overwrite confirm should appear"
	pane_has 'Will overwrite the following file:' "stock overwrite body"
	log_has 'nested rename overwrite prompt'

	send_key n
	settle 1.0
	log_has 'nested rename overwrite declined'
	file_exists "$FIXTURE/alpha/aaa.txt"
	file_content_is "$FIXTURE/alpha/bbb.txt" 'BBB'
	pane_has 'aaa.txt' "declined rename leaves the source row"
	hovered_is 'aaa.txt' "cursor stays on the source after declining"

	rename_to 'bbb.txt'
	pane_has 'Overwrite file?'
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

# Visual selection rename: v then r on an injected nested row must delegate to
# stock bulk rename immediately. Yazi only commits the visual range into
# cx.active.selected inside its own Rename actor (escape_visual), so the plugin
# has to detect the active mode itself; otherwise the nested row falls through
# to the plugin-owned single-file prompt.
scenario_rename_visual() {
	new_env rename_visual
	write_config true adopt
	make_fixture
	make_noop_editor
	launch "$FIXTURE" "EDITOR='$DIR/editor.sh'"

	send_key l
	settle 0.9
	send_key j
	settle 0.4
	hovered_is 'child.txt' "nested cursor before the visual rename"

	# Start a visual range on the injected child and extend it over the next
	# DFS row (aa.txt); then r must reach stock bulk rename, not the plugin.
	send_key v
	settle 0.3
	send_key j
	settle 0.3
	send_key r

	# The stock editor runs asynchronously; wait for it to record the list.
	wait_file_exists "$DIR/selected.txt" 15 "stock bulk rename should open the editor"
	pane_lacks 'Rename:' "visual rename must not open the single-file popup"
	log_lacks 'nested rename open' "visual rename must not use the plugin-owned path"
	# Membership only: selection order is an IndexMap, not stable.
	grep -qF 'alpha/child.txt' "$DIR/selected.txt" ||
		fail "bulk list should contain alpha/child.txt"
	grep -qF 'aa.txt' "$DIR/selected.txt" ||
		fail "bulk list should contain aa.txt"

	snapshot rename_visual
	assert_log_clean
	stop_session
}

# Committed (Space) selection on nested rows keeps delegating through the
# pre-existing `#cx.active.selected > 0` branch the fix extends.
scenario_rename_selected_committed() {
	new_env rename_selected_committed
	write_config true adopt
	make_fixture
	make_noop_editor
	launch "$FIXTURE" "EDITOR='$DIR/editor.sh'"

	send_key l
	settle 0.9
	send_key j
	settle 0.4
	hovered_is 'child.txt'
	# Space toggles selection and advances the cursor one row each time, so two
	# presses select the injected child and the following root file.
	send_key Space
	settle 0.4
	send_key Space
	settle 0.4

	send_key r
	wait_file_exists "$DIR/selected.txt" 15 "committed selection should bulk rename"
	pane_lacks 'Rename:' "committed selection must not open the single-file popup"
	log_lacks 'nested rename open' "committed selection must not use the plugin-owned path"
	grep -qF 'alpha/child.txt' "$DIR/selected.txt" ||
		fail "bulk list should contain alpha/child.txt"
	grep -qF 'aa.txt' "$DIR/selected.txt" ||
		fail "bulk list should contain aa.txt"

	snapshot rename_selected_committed
	assert_log_clean
	stop_session
}
