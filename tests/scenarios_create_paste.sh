# ---------------------------------------------------------------------------
# Create and paste scenario suite
#
# Target-aware create, overwrite/collision prompts, and yank/paste/cut.
# Sourced by integration.sh after harness.sh; definitions only (never executed).
# ---------------------------------------------------------------------------

# Target-aware create: inside a hovered directory, beside a hovered file, a
# trailing separator makes a directory, and a root-level file delegates stock.
scenario_create() {
	new_env create
	write_config true adopt
	make_fixture_create
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key a
	settle 0.6
	pane_has 'Create:' "create popup"
	send_text 'newfile.txt'
	settle 0.3
	send_key Enter
	settle 1.3
	file_exists "$FIXTURE/alpha/newfile.txt"
	header_has "$FIXTURE"
	header_lacks "$FIXTURE/alpha" "create must not change cwd"

	send_key l
	settle 1.0
	pane_has 'newfile.txt'
	pane_has 'existing.txt'

	send_key j
	settle 0.4
	hovered_is 'existing.txt'
	send_key a
	settle 0.6
	pane_has 'Create:'
	send_text 'beside.txt'
	settle 0.3
	send_key Enter
	settle 1.4
	file_exists "$FIXTURE/alpha/beside.txt"
	hovered_is 'beside.txt' "focus follows the created row"
	pane_has 'beside.txt'

	send_key k
	settle 0.4
	hovered_is 'alpha'
	send_key a
	settle 0.6
	send_text 'newdir/'
	settle 0.3
	send_key Enter
	settle 1.4
	[ -d "$FIXTURE/alpha/newdir" ] || fail "trailing separator should create a directory"
	pane_has 'newdir'

	# A root-level file resolves to cwd and delegates to stock create.
	send_key k
	settle 0.4
	hovered_is 'alpha'
	send_key h
	settle 1.0
	hovered_is 'alpha'
	send_key j
	settle 0.4
	hovered_is 'rootfile.txt'
	send_key a
	settle 0.6
	pane_has 'Create:'
	send_text 'rootnew.txt'
	settle 0.3
	send_key Enter
	settle 1.5
	file_exists "$FIXTURE/rootnew.txt"

	snapshot create
	assert_log_clean
	stop_session
}

# Create over an existing regular file: declining keeps the old bytes, accepting
# truncates in place with no unlink, no trash task, and a consistent row.
scenario_create_overwrite() {
	new_env create_overwrite
	write_config true adopt
	make_fixture_create_overwrite
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	# Rows: 1 alpha, 2 adir, 3 alink, 4 existing.txt (dirs first, then names).
	send_key j
	settle 0.3
	send_key j
	settle 0.3
	send_key j
	settle 0.3
	hovered_is 'existing.txt'

	# Decline: nothing changes.
	send_key a
	settle 0.6
	pane_has 'Create:'
	send_text 'existing.txt'
	settle 0.3
	send_key Enter
	settle 0.8
	pane_has 'Overwrite file?' "overwrite confirm for an existing file"
	send_key n
	settle 1.0
	log_has 'create overwrite declined'
	file_content_is "$FIXTURE/alpha/existing.txt" 'KEEP'
	log_lacks 'create dir collision'
	pane_has 'existing.txt'
	hovered_is 'existing.txt' "cursor stays on the declined file"

	# Accept: truncated in place, row still present, no trash task.
	send_key a
	settle 0.6
	pane_has 'Create:'
	send_text 'existing.txt'
	settle 0.3
	send_key Enter
	settle 0.8
	pane_has 'Overwrite file?'
	send_key y
	settle 1.4
	file_exists "$FIXTURE/alpha/existing.txt"
	file_content_is "$FIXTURE/alpha/existing.txt" ''
	pane_has 'existing.txt'
	hovered_is 'existing.txt' "cursor follows the overwritten file"
	log_lacks '[Tt]rash'
	log_lacks 'create dir collision'
	log_has 'create done'

	snapshot create_overwrite
	assert_log_clean
	stop_session
}

# Create collisions: an existing directory is a clean failure (no prompt, no
# EISDIR error, no trash), and an existing symlink is replaced as a link without
# touching its target.
scenario_create_collisions() {
	new_env create_collisions
	write_config true adopt
	make_fixture_create_overwrite
	launch "$FIXTURE"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	# Rows: 1 alpha, 2 adir, 3 alink, 4 existing.txt. Hovering a file targets
	# its parent directory (alpha), so a typed sibling name collides with the
	# directory/symlink entries already there.
	send_key j
	settle 0.3
	send_key j
	settle 0.3
	send_key j
	settle 0.3
	hovered_is 'existing.txt'

	# Directory collision: no overwrite prompt, a clear error, disk untouched.
	send_key a
	settle 0.6
	pane_has 'Create:'
	send_text 'adir'
	settle 0.3
	send_key Enter
	settle 1.2
	pane_lacks 'Overwrite file?' "directory collision must not prompt"
	pane_has 'already exists as a directory' "clear error notification"
	log_has 'create dir collision'
	[ -d "$FIXTURE/alpha/adir" ] || fail "directory collision must leave the directory"
	file_content_is "$FIXTURE/alpha/adir/inside.txt" 'DIRKEEP'
	log_lacks '[Tt]rash'
	hovered_is 'existing.txt' "cursor stays put after the collision"

	# Symlink collision: the link is replaced, its target keeps its bytes.
	send_key a
	settle 0.6
	pane_has 'Create:'
	send_text 'alink'
	settle 0.3
	send_key Enter
	settle 0.8
	pane_has 'Overwrite file?'
	send_key y
	settle 1.4
	[ -e "$FIXTURE/alpha/alink" ] || fail "symlink collision should leave a file at the link path"
	[ ! -L "$FIXTURE/alpha/alink" ] || fail "symlink should be replaced by a regular file"
	file_content_is "$FIXTURE/alpha/existing.txt" 'KEEP'
	file_content_is "$FIXTURE/alpha/alink" ''
	pane_has 'alink'
	log_lacks '[Tt]rash'
	log_has 'create done'

	snapshot create_collisions
	assert_log_clean
	stop_session
}

# Normal paste into a hovered nested directory copies a file; force paste
# overwrites an existing destination and a later normal paste uniquifies.
scenario_paste() {
	new_env paste
	write_config true adopt
	make_fixture_paste
	launch "$FIXTURE"

	hovered_is 'dst'
	send_key l
	settle 1.0
	hovered_is 'dst' "expand the destination"
	send_key j
	settle 0.4
	hovered_is 'src'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	hovered_is 'a.txt'
	send_key y
	settle 0.4
	send_key k
	settle 0.4
	hovered_is 'src'
	send_key k
	settle 0.4
	hovered_is 'dst'
	send_key p
	settle 2.2
	file_exists "$FIXTURE/dst/a.txt"
	file_content_is "$FIXTURE/dst/a.txt" 'AAA'
	log_has 'transfer complete'

	# Force paste overwrites the destination file content.
	printf 'OLD' >"$FIXTURE/dst/a.txt"
	send_key j
	settle 0.4
	hovered_is 'a.txt'
	send_key j
	settle 0.4
	hovered_is 'src'
	send_key j
	settle 0.4
	hovered_is 'a.txt'
	send_key y
	settle 0.4
	send_key k
	settle 0.4
	hovered_is 'src'
	send_key k
	settle 0.4
	hovered_is 'a.txt'
	send_key k
	settle 0.4
	hovered_is 'dst'
	send_key P
	settle 2.2
	file_content_is "$FIXTURE/dst/a.txt" 'AAA'

	# A later normal paste uniquifies instead of overwriting.
	send_key j
	settle 0.4
	hovered_is 'a.txt'
	send_key j
	settle 0.4
	hovered_is 'src'
	send_key j
	settle 0.4
	hovered_is 'a.txt'
	send_key y
	settle 0.4
	send_key k
	settle 0.4
	hovered_is 'src'
	send_key k
	settle 0.4
	hovered_is 'a.txt'
	send_key k
	settle 0.4
	hovered_is 'dst'
	send_key p
	settle 2.2
	file_exists "$FIXTURE/dst/a_1.txt"

	snapshot paste
	assert_log_clean
	stop_session
}

# Cut paste moves a nested file, unyanks the cut set, and refreshes the
# expanded source hierarchy so the moved row disappears.
scenario_cut_paste() {
	new_env cut_paste
	write_config true adopt
	make_fixture_cut
	launch "$FIXTURE"

	hovered_is 'source'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	hovered_is 'move.txt'
	send_key x
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'target'
	send_key p
	settle 2.2
	file_exists "$FIXTURE/target/move.txt"
	file_absent "$FIXTURE/source/move.txt"
	log_has 'cut paste unyank'
	log_has 'transfer complete'
	pane_lacks 'move.txt' "source child disappears after the move"

	snapshot cut_paste
	assert_log_clean
	stop_session
}
