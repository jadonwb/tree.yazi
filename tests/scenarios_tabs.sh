# ---------------------------------------------------------------------------
# Tab-local scenario suite
#
# Tab mode/preview inheritance, tab-local filter/sort, cross-tab saved-state
# pruning/re-keying, background-tab cd tracking, and tab-close state pruning.
# Sourced by integration.sh after harness.sh; definitions only (never executed).
# ---------------------------------------------------------------------------

# Whitespace-joined left-to-right pane order of the given names, ordered by each
# name's first rendered line.
pane_order() {
	local f
	for f in "$@"; do
		printf '%s %s\n' "$(line_of "$f")" "$f"
	done | sort -n | awk '{print $2}' | paste -sd' ' -
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

	# Tab 1 (tree) expands alpha, then hovers an injected descendant so the
	# stock `tab_create --current` reveal bug (cd to the descendant's parent)
	# would be observable.
	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'
	send_key j
	settle 0.4
	hovered_is 'alpha1.txt'

	# Tab 2 inherits tree mode but not tab 1's expansion. A nested hover must
	# not reroot the new tab: it opens at the tree cwd with an empty expansion
	# set and a directories-first root order, and the explicit-target create
	# re-pins the live (configured) sort to none despite the inherited
	# sort_saved.
	local pins_before
	pins_before="$(log_count 'pinning sort_by=none')"
	send_key t
	settle 1.2
	header_has "$FIXTURE" "nested-hover tab create stays at the tree cwd"
	header_lacks "$FIXTURE/alpha" "tab create must not reveal the hovered parent"
	pane_lacks 'alpha1.txt' "new tab has an empty expansion set"
	line_before 'alpha' 'zz.txt'
	[ "$(log_count 'pinning sort_by=none')" = "$((pins_before + 1))" ] ||
		fail "explicit-target tab should re-pin sort_by=none"
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

# The captured sort preference drives the emulated per-directory order while
# the native sorter stays pinned to none: a `key-sort` request reorders the live
# tree immediately, nested children and depth-0 roots alike.
#
# Stock `--reverse=no` means ascending, so `S` (mtime) puts the older entry
# first and `s` (size) puts the smaller entry first.
scenario_sort_live_mtime() {
	new_env sort_live_mtime
	write_config true adopt
	make_fixture_sort_live
	launch "$FIXTURE"

	# Expand alpha so its children are injected.
	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'anew.txt'
	pane_has 'zold.txt'

	# Default (alphabetical) order: anew before zold; zbig before zsmall.
	line_before 'anew.txt' 'zold.txt'
	line_before 'zbig.txt' 'zsmall.txt'

	# `S` requests mtime (--reverse=no): the older nested file moves ahead.
	send_key S
	settle 1.0
	log_has 'sort request captured; forcing by=none'
	line_before 'zold.txt' 'anew.txt' "mtime sort reorders injected children live"

	# `s` requests size (--reverse=no): the smaller root file moves ahead.
	send_key s
	settle 1.0
	line_before 'zsmall.txt' 'zbig.txt' "size sort reorders depth-0 roots live"

	snapshot sort_live_mtime
	assert_log_clean
	stop_session
}

# Natural sort is emulated like the other `by` values: three same-parent
# siblings whose bytewise alphabetical order (file1, file10, file2) differs
# from the natural order (file1, file2, file10), so a `sort natural` request
# reorders the live roots. A scenario-local keymap issues the request instead
# of relying on the stock `,n` chord.
scenario_sort_live_natural() {
	new_env sort_live_natural
	write_config true adopt
	printf '1' >"$FIXTURE/file1.txt"
	printf '2' >"$FIXTURE/file2.txt"
	printf '10' >"$FIXTURE/file10.txt"
	cat >>"$CFG/keymap.toml" <<'TOML'

[[mgr.prepend_keymap]]
on = "n"
run = "sort natural --reverse=no"
TOML
	launch "$FIXTURE"

	# Default (alphabetical) order is bytewise: file1, file10, file2.
	line_before 'file1.txt' 'file10.txt' "alphabetical order before natural sort"
	line_before 'file10.txt' 'file2.txt' "alphabetical order before natural sort"

	# `n` requests natural (--reverse=no): file1, file2, file10.
	send_key n
	settle 1.0
	log_has 'sort request captured; forcing by=none'
	line_before 'file1.txt' 'file2.txt' "natural sort reorders depth-0 roots live"
	line_before 'file2.txt' 'file10.txt' "natural sort reorders depth-0 roots live"

	snapshot sort_live_natural
	assert_log_clean
	stop_session
}

# Random sort is emulated with a per-tab seed: a `sort random` request leaves the
# alphabetical baseline, later rebuilds (a hidden-toggle reassert) keep that
# exact order because the seed is frozen, and a second random request advances
# the seed. A scenario-local keymap issues the request instead of the stock `,r`.
scenario_sort_live_random() {
	new_env sort_live_random
	write_config true adopt
	printf 'A' >"$FIXTURE/a.txt"
	printf 'B' >"$FIXTURE/b.txt"
	printf 'C' >"$FIXTURE/c.txt"
	printf 'D' >"$FIXTURE/d.txt"
	printf 'E' >"$FIXTURE/e.txt"
	printf 'F' >"$FIXTURE/f.txt"
	cat >>"$CFG/keymap.toml" <<'TOML'

[[mgr.prepend_keymap]]
on = "R"
run = "sort random --reverse=no"
TOML
	add_hidden_keymap
	launch "$FIXTURE"

	local files="a.txt b.txt c.txt d.txt e.txt f.txt"
	local alphabetical="a.txt b.txt c.txt d.txt e.txt f.txt"
	local order
	order="$(pane_order $files)"
	[ "$order" = "$alphabetical" ] || fail "baseline order is '$order', expected '$alphabetical'"

	# `R` requests random: the sibling order leaves the alphabetical baseline.
	send_key R
	settle 1.0
	log_has 'sort request captured; forcing by=none'
	log_has 'random seed='
	order="$(pane_order $files)"
	[ "$order" != "$alphabetical" ] || fail "random sort still matched the alphabetical baseline"

	# A rebuild must keep the frozen order: a hidden toggle queues a reassert.
	send_key C-h
	settle 1.2
	local frozen
	frozen="$(pane_order $files)"
	[ "$frozen" = "$order" ] || fail "reassert reshuffled the frozen random order: '$frozen' vs '$order'"
	send_key C-h
	settle 1.2
	frozen="$(pane_order $files)"
	[ "$frozen" = "$order" ] || fail "second reassert reshuffled the frozen random order"

	# A second random request bumps the seed.
	send_key R
	settle 1.0
	local seeds
	seeds="$(grep -aoE 'random seed=.*' "$LOG" | grep -oE '[0-9]+$' | paste -sd' ' -)"
	[ "$seeds" = "1 2" ] || fail "random seed sequence is '$seeds', expected '1 2'"

	snapshot sort_live_random
	assert_log_clean
	stop_session
}

# Natural sort honours the captured `translit` preference: the folded name
# (École -> Ecole) sorts between Apple and Zebra, where the raw byte order puts
# the accented name last. A scenario-local keymap issues the translit request.
scenario_sort_live_translit() {
	new_env sort_live_translit
	write_config true adopt
	printf 'A' >"$FIXTURE/Apple.txt"
	printf 'Z' >"$FIXTURE/Zebra.txt"
	printf 'E' >"$FIXTURE/École.txt"
	cat >>"$CFG/keymap.toml" <<'TOML'

[[mgr.prepend_keymap]]
on = "n"
run = "sort natural --translit=yes --reverse=no"
TOML
	launch "$FIXTURE"

	# Without translit the accented name sorts last (raw byte order).
	line_before 'Apple.txt' 'Zebra.txt'
	line_before 'Zebra.txt' 'École.txt' "byte order puts the accented name last"

	# `n` requests natural with translit: the folded name moves between A and Z.
	send_key n
	settle 1.0
	log_has 'sort request captured; forcing by=none'
	line_before 'Apple.txt' 'École.txt' "transliterated natural order"
	line_before 'École.txt' 'Zebra.txt' "transliterated natural order"

	snapshot sort_live_translit
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
