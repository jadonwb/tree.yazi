scenario_setup_no_tree_scheme() {
  begin_scenario setup_no_tree_scheme
  wait_log '\[tvfs\] ratio 0,3,0' || fail "YAZI_TREE=1 startup layout was not applied"
  pane startup-tree
  grep -Fq "$FIXTURE" "$DIR/pane-startup-tree.txt" || fail "startup View header does not show its physical root"
  finish
}
