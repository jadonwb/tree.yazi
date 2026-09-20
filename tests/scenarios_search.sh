# ---------------------------------------------------------------------------
# Search-view scenario suite
#
# Yazi 014426f native fd/rg search Views: `s`/`S` open an input and cd the tab
# to a provider-scheme URL (observed `fd://default/...`, `rg://default/...`)
# whose loc is the physical search root, then stream provider results as FilesOp
# Parts; the header shows `(search: <query>)`. tree.yazi must treat these as
# stock provider Views: no tree connectors, no rebuild/injection, stock `f`
# filtering, and stock EscapeView back to the physical root (where the saved
# tree is restored only when the tab's recorded mode is on). These scenarios
# assert that desired policy, plus record-and-defer tree/preview toggling inside
# a View.
#
# Sourced by integration.sh after harness.sh; definitions only (never executed).
# ---------------------------------------------------------------------------

# Move the cursor until the hovered name is `want` (bounded).
search_hover() {
	local want="$1" i=0
	while [ "$i" -lt 12 ]; do
		if [ "$(hovered_name)" = "$want" ]; then
			return 0
		fi
		send_key j
		settle 0.2
		i=$((i + 1))
	done
	fail "could not hover '$want'"
}

# Shared runner for one provider (fd = name key `s`, rg = content key `S`) in
# one tab mode (tree/classic). Four thin scenarios below call it so each run is
# isolated. `mode=classic` uses write_config_search false so no tree state
# confounds the provider-side behavior.
run_search_view() {
	local via="$1" mode="$2" tree=false key subject
	case "$mode" in
	tree) tree=true ;;
	classic) tree=false ;;
	*) fail "unknown search mode '$mode'" ;;
	esac
	case "$via" in
	fd)
		key=s
		subject=txt
		;;
	rg)
		key=S
		subject=NEEDLE
		;;
	*) fail "unknown search provider '$via'" ;;
	esac

	new_env "search_${via}_${mode}"
	write_config_search "$tree" adopt
	make_fixture_search
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	# Tree only: expand alpha so the physical saved state is observably
	# different from the provider result set (alpha/a.txt exists in both; the
	# provider-only alpha/beta/* rows are not part of the physical expansion).
	if [ "$tree" = true ]; then
		search_hover alpha
		send_key l
		wait_pane_has 'a.txt' 10 "alpha should expand before the search"
		pane_matches '(├─|└─)' "expanded tree should render connectors"
	fi
	local n0
	n0="$(rebuild_count)"

	# Enter the native search view.
	send_key "$key"
	wait_pane_has "Search via $via:" 10 "search input popup should open"
	send_text "$subject"
	send_key Enter

	wait_header_has "(search: $subject)" 15 "search view header marker"
	wait_pane_has 'top.txt' 15 "flat result row"
	wait_pane_has 'alpha/a.txt' 15 "nested result row"
	if [ "$via" = fd ]; then
		wait_pane_has 'plain/p.txt' 15 "flat nested-dir result row"
		wait_pane_has 'alpha/beta/b.txt'
		wait_pane_has 'alpha/beta/gamma/c.txt'
		wait_line 15 '1/6'
	else
		wait_pane_has 'alpha/beta/b.txt'
		wait_line 15 '1/3'
	fi

	# Desired policy: the provider owns the View. Entering it must not rebuild
	# or inject the tree, and the plugin must not draw tree connectors over the
	# streamed provider rows (tree and classic tabs both see stock rendering).
	[ "$(rebuild_count)" = "$n0" ] ||
		fail "entering a search view rebuilt the tree ($n0 -> $(rebuild_count))"
	pane_lacks_re '(├─|└─)' "native search view must not render tree connectors"
	[ "$(capture | grep -cE '(├─|└─)' || true)" -eq 0 ] ||
		fail "native search view rendered tree connectors"

	# Root identity: the search cd is recognized as a provider View, so the
	# plugin records the provider root and leaves the Folder alone. The header's
	# `(search: <query>)` flag is the stock search indicator.
	wait_log_has 15 "cd search view;.*root=.*$via://.*$FIXTURE"
	local root
	root="$(last_search_view_root)"
	case "$root" in
	"$via://"*"$subject"*"$FIXTURE") ;;
	*) fail "search view root is '$root', expected ${via}://...${subject}...$FIXTURE" ;;
	esac

	# Escape follows stock EscapeView back to the physical root; a tree tab then
	# restores its saved hierarchy there.
	send_key Escape
	wait_header_lacks 'search:' 15
	wait_header_has "$FIXTURE" 15

	if [ "$tree" = true ]; then
		wait_pane_has 'a.txt' 15 "restored alpha expansion"
		pane_matches '(├─|└─)' "restored tree should render connectors"
		pane_lacks 'alpha/beta/b.txt' "provider-only nested row is gone after exit"
		log_has 'cd restore;.*saved=.*true'
		[ "$(last_rebuild_root)" = "$FIXTURE" ] ||
			fail "restore rebuilt at '$(last_rebuild_root)', expected '$FIXTURE'"
	else
		pane_lacks '├─'
		pane_lacks '└─'
		pane_lacks 'alpha/a.txt' "classic tab never expanded alpha"
		pane_has 'alpha'
	fi

	# Re-entry: re-running the same query re-enters the view and re-asserts the
	# provider rows, still without connectors or a tree rebuild.
	send_key "$key"
	wait_pane_has "Search via $via:" 10 "reopened search input"
	send_text "$subject"
	send_key Enter
	wait_header_has "(search: $subject)" 15 "re-running re-enters the search view"
	wait_pane_has 'top.txt' 15 "results return on re-entry"
	pane_lacks_re '(├─|└─)' "re-entered view still renders no tree connectors"

	snapshot "search_${via}_${mode}"
	assert_log_clean
	stop_session
}

scenario_search_fd_tree() {
	run_search_view fd tree
}

scenario_search_fd_classic() {
	run_search_view fd classic
}

scenario_search_rg_tree() {
	run_search_view rg tree
}

scenario_search_rg_classic() {
	run_search_view rg classic
}

# Re-run and cancel the fd query inside the tree tab. An identical re-run must
# be a plugin no-op (Yazi's Cd actor short-circuits an equal target); a
# different subject must cd to a new provider URL; a cancelled input must leave
# everything untouched.
scenario_search_rerun() {
	new_env search_rerun
	write_config_search true adopt
	make_fixture_search
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	search_hover alpha
	send_key l
	wait_pane_has 'a.txt' 10

	send_key s
	wait_pane_has 'Search via fd:' 10
	send_text txt
	send_key Enter
	wait_line 15 '1/6'
	wait_pane_has 'plain/p.txt' 15
	local c0
	c0="$(search_view_count)"

	# Identical re-run: equal target, so no new provider cd and no reset.
	send_key s
	wait_pane_has 'Search via fd:' 10
	send_text txt
	send_key Enter
	wait_line 15 '1/6'
	[ "$(search_view_count)" = "$c0" ] ||
		fail "identical search re-run re-entered the view ($c0 -> $(search_view_count))"
	pane_has 'plain/p.txt'
	header_has '(search: txt)'

	# Different subject: a real cd to the new search URL, old rows replaced.
	send_key s
	wait_pane_has 'Search via fd:' 10
	send_text b
	send_key Enter
	wait_header_has '(search: b)' 15
	wait_log_has 15 "cd search view;.*fd://.*$FIXTURE"
	[ "$(search_view_count)" -gt "$c0" ] || fail "different subject did not re-enter the view"
	wait_pane_has 'b.txt' 15
	pane_lacks 'plain/p.txt' "old provider rows are gone after a new search"

	# Cancel the input: no cd, view and rows unchanged.
	local c1
	c1="$(search_view_count)"
	send_key s
	wait_pane_has 'Search via fd:' 10
	send_key C-c
	wait_pane_lacks 'Search via fd:' 10
	[ "$(search_view_count)" = "$c1" ] || fail "cancelled search re-entered the view"
	header_has '(search: b)'
	pane_has 'b.txt'

	snapshot search_rerun
	assert_log_clean
	stop_session
}

# Stock filtering inside the View: `f` must remain Yazi's own `filter --smart`
# over the provider rows, shown as `(search: ..., filter: ...)`, not a tree
# rebuild. First Escape clears the filter and stays in the View; a second Escape
# leaves it and restores the saved physical tree.
scenario_search_stock_filter() {
	new_env search_stock_filter
	write_config_search true adopt
	make_fixture_search
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	search_hover alpha
	send_key l
	wait_pane_has 'a.txt' 10

	send_key s
	wait_pane_has 'Search via fd:' 10
	send_text txt
	send_key Enter
	wait_line 15 '1/6'
	wait_pane_has 'alpha/beta/b.txt' 15
	wait_header_has '(search: txt)' 15
	local n1
	n1="$(rebuild_count)"

	# f is stock filter in the View: the popup opens, the indicator shows beside
	# the search indicator, and no tree rebuild/injection happens.
	send_key f
	wait_pane_has 'Filter:' 10
	send_text alpha
	send_key Enter
	wait_header_has 'filter: alpha' 15
	wait_pane_lacks 'Filter:' 10 "filter popup closes on submit"
	header_has 'search: txt'
	[ "$(rebuild_count)" = "$n1" ] ||
		fail "stock filter in the search view triggered a tree rebuild ($n1 -> $(rebuild_count))"
	pane_lacks_re '(├─|└─)' "filtered search view must not render tree connectors"
	wait_pane_has 'alpha/a.txt' 15 "matching provider row survives the stock filter"
	wait_pane_lacks 'top.txt' 15 "non-matching provider row is hidden by the stock filter"

	# First Escape clears the stock filter and stays in the View.
	send_key Escape
	wait_header_lacks 'filter:' 15
	wait_header_has '(search: txt)' 15 "clearing the filter stays in the search view"
	wait_pane_has 'top.txt' 15 "provider rows return after the clear"
	[ "$(rebuild_count)" = "$n1" ] ||
		fail "clearing the stock filter triggered a tree rebuild ($n1 -> $(rebuild_count))"

	# Second Escape leaves the View and restores the physical tree.
	send_key Escape
	wait_header_lacks 'search:' 15
	wait_header_has "$FIXTURE" 15
	wait_pane_has 'a.txt' 15 "tree expansion restored after leaving the search view"
	pane_matches '(├─|└─)' "restored tree renders connectors"
	log_has 'cd restore;.*saved=.*true'

	snapshot search_stock_filter
	assert_log_clean
	stop_session
}

# Toggling tree mode inside the View only records the tab's desired mode and
# reflows the layout; the provider Folder is never mutated. Escape then applies
# the recorded mode at the physical root, and the saved expansion round-trips
# through a physical toggle.
scenario_search_toggle_defer() {
	new_env search_toggle_defer
	write_config_search true adopt
	make_fixture_search
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	search_hover alpha
	send_key l
	wait_pane_has 'a.txt' 10
	pane_matches '(├─|└─)'
	local n0
	n0="$(rebuild_count)"

	send_key s
	wait_pane_has 'Search via fd:' 10
	send_text txt
	send_key Enter
	wait_line 15 '1/6'
	wait_header_has '(search: txt)' 15
	[ "$(rebuild_count)" = "$n0" ] || fail "entering the view rebuilt the tree"

	# Toggle off inside the View: recorded now, no rebuild, no connectors.
	send_key T
	wait_log_has 15 'toggle in search view;.*recorded tree=.*false'
	[ "$(rebuild_count)" = "$n0" ] ||
		fail "toggling in the view triggered a tree rebuild ($n0 -> $(rebuild_count))"
	pane_lacks_re '(├─|└─)' "toggled-off view still renders no tree connectors"
	wait_pane_has 'top.txt' 15 "provider rows stay after the in-view toggle"

	# Toggle back on inside the View: still recorded only.
	send_key T
	wait_log_has 15 'toggle in search view;.*recorded tree=.*true'
	[ "$(rebuild_count)" = "$n0" ] || fail "second in-view toggle rebuilt the tree"

	# Preview toggles independently in the View: layout-only, no Folder mutation,
	# no rebuild. Toggle it back so the physical restore assertions are unchanged.
	send_key V
	wait_log_has 15 'toggle preview='
	[ "$(rebuild_count)" = "$n0" ] ||
		fail "toggling preview in the view triggered a tree rebuild"
	wait_pane_has 'top.txt' 15 "provider rows stay after the in-view preview toggle"
	pane_lacks_re '(├─|└─)' "preview toggle must not add tree connectors"
	send_key V
	settle 0.6

	# Escape applies the recorded (on) mode at the physical root: the saved
	# hierarchy is restored there.
	send_key Escape
	wait_header_lacks 'search:' 15
	wait_pane_has 'a.txt' 15 "recorded tree mode restored the expansion"
	pane_matches '(├─|└─)' "restored tree renders connectors"

	# Toggle off and on at the physical root: the saved state round-trips.
	send_key T
	wait_pane_lacks 'a.txt' 15 "tree off collapses the expansion"
	pane_lacks_re '(├─|└─)' "tree off renders no connectors"
	send_key T
	wait_pane_has 'a.txt' 15 "tree on restores the saved expansion"
	pane_matches '(├─|└─)' "restored tree renders connectors"

	snapshot search_toggle_defer
	assert_log_clean
	stop_session
}
