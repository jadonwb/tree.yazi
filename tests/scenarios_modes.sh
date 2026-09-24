scenario_modes_toggle_preview() {
  begin_scenario modes_toggle_preview
  enter_view
  wait_log '\[tvfs\] ratio 0,3,4' || fail "tree layout did not hide the parent pane"
  press Z; wait_log '\[tvfs\] ratio 0,3,0' || fail "preview toggle did not hide preview"
  press Z; wait_log '\[tvfs\] ratio 0,3,4' || fail "preview toggle did not restore preview"
  press t; sleep 0.2; press v; wait_log '\[tvfs\] ratio 1,3,4' || fail "tree toggle did not restore parent pane"
  finish
}
