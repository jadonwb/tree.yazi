scenario_rename_nested() {
  begin_scenario rename_nested
  enter_view; press l; sleep 0.3
  press L; sleep 0.4
  press r; sleep 0.3; press C-a C-k; type_text renamed; press Enter
  for _ in {1..40}; do [[ -e "$FIXTURE/alpha/renamed" ]] && break; sleep 0.1; done
  [[ -e "$FIXTURE/alpha/renamed" && ! -e "$FIXTURE/alpha/shared" ]] || fail "rename did not mutate the nested physical path"
  wait_log '\[tvfs\] reenter' || fail "rename did not reenter the View"
  finish
}
