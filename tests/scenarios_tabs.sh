scenario_tabs_view_clone() {
  begin_scenario tabs_view_clone
  enter_view
  press l; sleep 0.3
  press t t; sleep 0.6
  wait_log "ReadDir tab=2 root=$FIXTURE" || fail "tab_create did not retain a provider View portal"
  press h; sleep 0.4
  local two
  two="$(grep "\[tvfs\] ReadDir tab=2 root=$FIXTURE " "$LOG" | tail -1)"
  [[ "$two" != *"alpha/a1.txt"* ]] || fail "tab 2 collapse failed"
  press '['; sleep 0.5
  local one
  one="$(grep "\[tvfs\] ReadDir tab=1 root=$FIXTURE " "$LOG" | tail -1)"
  [[ "$one" == *"alpha/a1.txt"* ]] || fail "tab 2 mutation leaked into tab 1"
  finish
}
