scenario_create_nested() {
  begin_scenario create_nested
  enter_view; press l; sleep 0.3
  press a; sleep 0.3; type_text created/; press Enter
  for _ in {1..30}; do [[ -d "$FIXTURE/alpha/created" ]] && break; sleep 0.1; done
  [[ -d "$FIXTURE/alpha/created" ]] || fail "create at hovered directory did not target physical nested directory"
  wait_log '\[tvfs\] create target=' || fail "provider create action was not used"
  finish
}

scenario_paste_nested() {
  begin_scenario paste_nested
  enter_view
  # Enter alpha as the provider root; yank its file row, then hover shared and
  # paste there so both endpoints exercise physical-backed View URLs.
  press L; sleep 0.4
  press j; sleep 0.2; press y; sleep 0.2
  press F; sleep 0.2; press p; sleep 0.8
  if [[ -e "$FIXTURE/alpha/shared/a1.txt" ]]; then :; else fail "provider paste did not create a copy under shared"; fi
  wait_log '\[tvfs\] action paste' || fail "provider paste action not logged"
  finish
}
