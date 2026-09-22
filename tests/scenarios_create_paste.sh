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

# Create collisions: an existing directory prompts like stock (declining leaves
# it untouched; confirming surfaces the write failure and still leaves it), and
# an existing symlink is replaced as a link without touching its target.
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

	# Directory collision, declined: stock prompts for any existing path, and
	# declining leaves the directory and its contents untouched.
	send_key a
	settle 0.6
	pane_has 'Create:'
	send_text 'adir'
	settle 0.3
	send_key Enter
	settle 0.8
	pane_has 'Overwrite file?' "directory collision must prompt like stock"
	send_key n
	settle 1.0
	log_has 'create overwrite declined'
	[ -d "$FIXTURE/alpha/adir" ] || fail "declining must leave the directory"
	file_content_is "$FIXTURE/alpha/adir/inside.txt" 'DIRKEEP'
	log_lacks '[Tt]rash'

	# Directory collision, confirmed: the write fails on the directory, which is
	# reported, and the directory and its contents stay intact.
	send_key a
	settle 0.6
	pane_has 'Create:'
	send_text 'adir'
	settle 0.3
	send_key Enter
	settle 0.8
	pane_has 'Overwrite file?' "directory collision must prompt when confirmed"
	send_key y
	settle 1.4
	pane_has 'Create failed' "confirming a directory collision reports the write error"
	log_has 'create write failed'
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

# Paste ordering regression: a uniquified paste must sort below its original.
# The emulated comparator and the seeded root order compare encoded bytes, not
# the process collation, so the session is launched under a non-C LC_COLLATE
# (en_US.UTF-8 down-weights punctuation in strcoll, which used to place
# a_1.txt above a.txt).
scenario_paste_order() {
	new_env paste_order
	write_config true adopt
	make_fixture_paste
	launch "$FIXTURE" "LC_ALL=en_US.UTF-8"

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

	# The next normal paste collides and uniquifies to dst/a_1.txt, which must
	# render after the original a.txt.
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
	line_before 'a.txt' 'a_1.txt' "a uniquified paste must sort after its original"

	# A third unique paste makes a_2.txt, which must sort after a_1.txt.
	send_key j
	settle 0.4
	hovered_is 'a.txt'
	send_key j
	settle 0.4
	hovered_is 'a_1.txt'
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
	hovered_is 'a_1.txt'
	send_key k
	settle 0.4
	hovered_is 'a.txt'
	send_key k
	settle 0.4
	hovered_is 'dst'
	send_key p
	settle 2.2
	file_exists "$FIXTURE/dst/a_2.txt"
	line_before 'a_1.txt' 'a_2.txt' "the second unique paste must sort after the first"

	snapshot paste_order
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

# Cut paste with an unrelated committed selection: only the moved URL must be
# dropped from the selection, so the survivor still routes `r` to stock bulk
# rename and the bulk list excludes the moved source.
scenario_cut_paste_keeps_selection() {
	new_env cut_paste_keeps_selection
	write_config true adopt
	make_fixture_cut_paste_selection
	make_noop_editor
	launch "$FIXTURE" "EDITOR='$DIR/editor.sh'"

	hovered_is 'dst'
	send_key j
	settle 0.4
	hovered_is 'src'
	send_key l
	settle 1.0
	send_key j
	settle 0.4
	hovered_is 'a.txt'
	send_key x
	settle 0.4
	send_key j
	settle 0.4
	hovered_is 'b.txt'
	# Space selects b.txt and advances the cursor to the next row.
	send_key Space
	settle 0.4

	# Back up to the destination directory (root-level dst) and cut-paste.
	send_key k
	settle 0.3
	send_key k
	settle 0.3
	send_key k
	settle 0.3
	hovered_is 'dst'
	send_key p
	settle 2.2
	file_exists "$FIXTURE/dst/a.txt"
	file_content_is "$FIXTURE/dst/a.txt" 'AAA'
	file_absent "$FIXTURE/src/a.txt"
	log_has 'cut paste unyank'

	# The surviving src/b.txt selection must still be present: hover a nested row
	# and `r` must reach stock bulk rename, not the plugin-owned path. With a
	# single selected file stock's max_common_root is the file itself, so the
	# editor list carries basenames.
	send_key j
	settle 0.4
	hovered_is 'src'
	send_key l
	settle 0.6
	send_key j
	settle 0.4
	hovered_is 'b.txt'
	send_key r
	wait_file_exists "$DIR/selected.txt" 15 "the surviving selection should bulk rename"
	pane_lacks 'Rename:' "a cut paste must not clear the unrelated selection"
	log_lacks 'nested rename open' "the surviving selection must delegate to stock rename"
	grep -qF 'b.txt' "$DIR/selected.txt" ||
		fail "bulk list should contain the surviving src/b.txt"
	if grep -qF 'a.txt' "$DIR/selected.txt"; then
		fail "bulk list should exclude the moved src/a.txt"
	fi

	snapshot cut_paste_keeps_selection
	assert_log_clean
	stop_session
}

# Bulk create: the editor's multi-path buffer is created under the hovered
# expanded directory (not the cwd), a trailing separator makes a directory, a
# nested path builds intermediates, and the first created row is focused. A
# root-level hover delegates to stock, whose editor marker proves the stock path
# ran and whose decline creates nothing.
scenario_bulk_create() {
	new_env bulk_create
	write_config true adopt
	make_fixture_create
	make_bulk_create_editor
	printf 'newfile.txt\nnewdir/\nsub/nested.txt\n' >"$DIR/bulk_input"
	launch "$FIXTURE" "EDITOR='$DIR/bulk_editor.sh'"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	hovered_is 'alpha' "expand the destination"
	send_key A
	wait_file_exists "$DIR/bulk_editor_ran" 15 "the editor should run for a hovered directory"
	wait_pane_has 'Continue to create?'
	send_key y
	wait_file_exists "$FIXTURE/alpha/newfile.txt" 15
	wait_file_exists "$FIXTURE/alpha/sub/nested.txt" 15
	[ -d "$FIXTURE/alpha/newdir" ] || fail "trailing separator should create a directory under the hovered dir"
	file_absent "$FIXTURE/newfile.txt" "bulk create must not join to the tab cwd"
	file_absent "$FIXTURE/newdir"
	header_has "$FIXTURE"
	header_lacks "$FIXTURE/alpha" "bulk create must not change cwd"
	wait_pane_has 'newfile.txt'
	hovered_is 'newfile.txt' "focus follows the first created row"

	# A root-level hover resolves to cwd and delegates to stock bulk create.
	rm -f "$DIR/bulk_editor_ran"
	send_key h
	settle 1.0
	hovered_is 'alpha' "collapse the destination"
	send_key j
	settle 0.4
	hovered_is 'rootfile.txt'
	send_key A
	wait_file_exists "$DIR/bulk_editor_ran" 15 "a root-level hover must delegate to stock bulk create"
	wait_pane_has 'Continue to create?'
	send_key n
	settle 1.2
	file_absent "$FIXTURE/newfile.txt"
	file_absent "$FIXTURE/newdir"

	snapshot bulk_create
	assert_log_clean
	stop_session
}

# Bulk create collision: an entry matching an existing file must not overwrite
# it (create_new is O_EXCL), the failure is reported, and the other entries are
# still created.
scenario_bulk_create_collision() {
	new_env bulk_create_collision
	write_config true adopt
	make_fixture_create
	make_bulk_create_editor
	printf 'existing.txt\nfresh.txt\n' >"$DIR/bulk_input"
	launch "$FIXTURE" "EDITOR='$DIR/bulk_editor.sh'"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	hovered_is 'alpha'
	send_key A
	wait_file_exists "$DIR/bulk_editor_ran" 15 "the editor should run"
	wait_pane_has 'Continue to create?'
	send_key y
	wait_file_exists "$FIXTURE/alpha/fresh.txt" 15
	file_content_is "$FIXTURE/alpha/existing.txt" 'EXIST'
	wait_pane_has 'Failed to create' 15 "the collision should be reported"
	pane_has 'existing.txt'
	hovered_is 'fresh.txt' "focus follows the first successfully created row"

	snapshot bulk_create_collision
	assert_log_clean
	stop_session
}

# Bulk create honors the configured blocking text opener: with $EDITOR pointing
# at a working marker editor, a custom [opener] edit rule must still be the one
# launched, and the entries it writes must be created.
scenario_bulk_create_opener() {
	new_env bulk_create_opener
	write_config true adopt
	make_fixture_create
	make_bulk_create_editor
	make_text_opener_editor
	printf 'opened.txt\n' >"$DIR/bulk_input"
	launch "$FIXTURE" "EDITOR='$DIR/bulk_editor.sh'"

	hovered_is 'alpha'
	send_key l
	settle 1.0
	hovered_is 'alpha' "expand the destination"
	send_key A
	wait_file_exists "$DIR/opener_editor_ran" 15 "the configured opener should run"
	wait_pane_has 'Continue to create?'
	send_key y
	wait_file_exists "$FIXTURE/alpha/opened.txt" 15
	file_absent "$DIR/bulk_editor_ran" "the configured opener must take precedence over \$EDITOR"

	snapshot bulk_create_opener
	assert_log_clean
	stop_session
}
