# ---------------------------------------------------------------------------
# Persistence scenario suite
#
# Saved-root/expansion state across cd, home, re-root, and back/forward.
# Sourced by integration.sh after harness.sh; definitions only (never executed).
# ---------------------------------------------------------------------------

# Core regression: returning to a cached cwd must restore the saved expansion
# set instead of rendering Yazi's cached injected rows against empty state, so
# the first h on a visibly expanded directory collapses it immediately.
scenario_cd_return_restores() {
	new_env cd_return_restores
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
	capture | tail -n 1 | grep -qF '3/5' || fail "gamma should be row 3/5 before the roundtrip"

	send_key 9
	settle 1.2
	header_has "$DIR/away"
	pane_lacks 'alpha1.txt' "away root has no restored rows"

	send_key 0
	settle 1.4
	header_has "$FIXTURE"
	pane_has 'alpha1.txt' "alpha branch restored after returning"
	pane_has 'gamma1.txt' "gamma branch restored after returning"
	log_has 'cd restore;.*saved=.*true'

	# Put the cursor on gamma regardless of the restored cursor position.
	local i=0
	while [ "$i" -lt 6 ]; do
		if [ "$(hovered_name)" = "gamma" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'gamma' "cursor on gamma after return"

	# First-press h must collapse the visibly expanded row immediately.
	send_key h
	settle 1.0
	log_has 'collapse .*gamma'
	pane_lacks 'gamma1.txt' "h collapses the restored gamma branch"
	pane_has 'alpha1.txt' "collapsing gamma keeps alpha expanded"

	send_key l
	settle 1.0
	pane_has 'gamma1.txt' "l re-expands the collapsed branch"

	snapshot cd_return_restores
	assert_log_clean
	stop_session
}

# A never-visited root has no saved state: it must start collapsed and expand
# normally, with no stale rows from the root we left.
scenario_cd_return_new_root() {
	new_env cd_return_new_root
	write_config true adopt
	make_fixture_cd
	mkdir -p "$DIR/fresh/one" "$DIR/fresh/two"
	printf 'X' >"$DIR/fresh/one/x.txt"
	add_cd_keymaps "$FIXTURE" "$DIR/fresh"
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'

	send_key 9
	settle 1.4
	header_has "$DIR/fresh"
	pane_lacks 'alpha1.txt' "fresh root shows no stale rows"
	pane_lacks '└─' "fresh root starts collapsed"
	local i=0
	while [ "$i" -lt 4 ]; do
		if [ "$(hovered_name)" = "one" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'one'
	send_key l
	settle 1.0
	pane_has 'x.txt'
	send_key h
	settle 1.0
	pane_lacks 'x.txt' "h collapses normally at the fresh root"

	snapshot cd_return_new_root
	assert_log_clean
	stop_session
}

# A go-to keymap roundtrip twice over: save-then-restore must be idempotent with
# no stale or duplicated rows.
scenario_home_roundtrip() {
	new_env home_roundtrip
	write_config true adopt
	make_fixture_cd
	mkdir -p "$DIR/home"
	add_cd_keymaps "$DIR/home" "$FIXTURE"
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
	pane_has 'alpha1.txt'
	pane_has 'gamma1.txt'
	capture | tail -n 1 | grep -qF '3/5' || fail "gamma row before the home trip"

	local trip
	for trip in 1 2; do
		send_key 0
		settle 1.2
		header_has "$DIR/home"
		send_key 9
		settle 1.4
		header_has "$FIXTURE"
		pane_has 'alpha1.txt' "alpha restored on trip $trip"
		pane_has 'gamma1.txt' "gamma restored on trip $trip"
		capture | tail -n 1 | grep -qF '3/5' || fail "row count drifted on trip $trip"
	done

	snapshot home_roundtrip
	assert_log_clean
	stop_session
}

# H/L reroot each keep an independent saved set; a child root's expansions never
# leak into its parent and vice versa.
scenario_reroot_roundtrip() {
	new_env reroot_roundtrip
	write_config true adopt
	make_fixture_reroot_roundtrip
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	# root0: expand alpha, then L into alpha (root1) and expand sub_a there.
	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'sub_a'
	send_key L
	settle 1.4
	header_has "$FIXTURE/alpha"
	local i=0
	while [ "$i" -lt 4 ]; do
		if [ "$(hovered_name)" = "sub_a" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'sub_a'
	send_key l
	settle 1.0
	pane_has 'inner_a.txt'

	# H back to root0: its {alpha} expansion is restored; root1's {sub_a} is not.
	send_key H
	settle 1.4
	header_has "$FIXTURE"
	pane_has 'sub_a' "alpha stays expanded at root0"
	pane_lacks 'inner_a.txt' "child root expansion does not leak into root0"

	# Re-enter root1: its own expansion is restored.
	i=0
	while [ "$i" -lt 6 ]; do
		if [ "$(hovered_name)" = "alpha" ]; then
			break
		fi
		send_key k
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'alpha'
	send_key L
	settle 1.4
	header_has "$FIXTURE/alpha"
	pane_has 'inner_a.txt' "root1 restores its own expansion"

	# H back and into root2; returning keeps root0 and root2 independent.
	send_key H
	settle 1.4
	header_has "$FIXTURE"
	i=0
	while [ "$i" -lt 8 ]; do
		if [ "$(hovered_name)" = "beta" ]; then
			break
		fi
		send_key j
		settle 0.3
		i=$((i + 1))
	done
	hovered_is 'beta'
	send_key L
	settle 1.4
	header_has "$FIXTURE/beta"
	send_key H
	settle 1.4
	header_has "$FIXTURE"
	pane_has 'sub_a' "root0 expansion survives the root2 trip"
	pane_lacks 'inner_b.txt' "root2 rows do not leak into root0"

	snapshot reroot_roundtrip
	assert_log_clean
	stop_session
}

# Stock history back/forward reroot through the same cd actor, so each URL's
# saved expansion set is restored in both directions.
scenario_back_forward() {
	new_env back_forward
	write_config true adopt
	make_fixture_back_forward
	add_cd_keymaps "$FIXTURE" "$DIR/away"
	launch "$FIXTURE"

	hovered_is 'Amore'
	send_key l
	settle 1.0
	pane_has 'a1.txt'
	send_key j
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'Bmore'
	send_key L
	settle 1.4
	header_has "$FIXTURE/Bmore"
	hovered_is 'bdir'
	send_key l
	settle 1.0
	pane_has 'b1.txt'

	send_key '['
	settle 1.4
	header_has "$FIXTURE"
	pane_has 'a1.txt' "back restores Amore's expansion"
	pane_lacks 'b1.txt' "Bmore rows absent at the other root"

	send_key ']'
	settle 1.4
	header_has "$FIXTURE/Bmore"
	pane_has 'b1.txt' "forward restores Bmore's expansion"
	pane_lacks 'a1.txt' "Amore rows absent at the other root"

	snapshot back_forward
	assert_log_clean
	stop_session
}

# Startup's bootstrap cd only records tab/root tracking; it must not schedule a
# rebuild before the first user expansion.
scenario_startup_tracking_clean() {
	new_env startup_tracking_clean
	write_config true adopt
	make_fixture_cd
	launch "$FIXTURE"

	log_lacks 'rebuild gen=' "startup must not rebuild"
	pane_lacks '└─'
	pane_has 'alpha'
	log_has 'cd bootstrap'

	hovered_is 'alpha'
	send_key l
	settle 1.0
	pane_has 'alpha1.txt'
	log_has 'rebuild gen=' "first expansion still rebuilds"

	snapshot startup_tracking_clean
	assert_log_clean
	stop_session
}
