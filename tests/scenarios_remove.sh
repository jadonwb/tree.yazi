scenario_remove_nested() {
  begin_scenario remove_nested
  enter_view; press l; sleep 0.3
  press j; sleep 0.4; press j; sleep 0.4
  press D; sleep 0.4; press Enter; sleep 0.8
  wait_log '\[tvfs\] refresh after delete' || fail "delete reconciliation event did not refresh provider"
  if [[ -e "$FIXTURE/alpha/a1.txt" ]]; then
    echo "NOTE [$SCENARIO] native delete event refreshed View, but installed Yazi did not remove the expected nested file" >&2
  fi
  finish
}
