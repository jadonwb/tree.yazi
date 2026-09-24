scenario_filter_live() {
  begin_scenario filter_live
  enter_view
  press l; sleep 0.3
  press f; sleep 0.3; type_text a1; sleep 0.3; press Enter; sleep 0.3
  wait_log "root=$FIXTURE entries .*alpha/a1.txt" || fail "filter did not retain matching ancestor and row"
  local latest
  latest="$(grep -F "[tvfs] ReadDir tab=1 root=$FIXTURE entries " "$LOG" | tail -1)"
  [[ "$latest" == *"entries 2 ::"* && "$latest" == *"/alpha/a1.txt"* ]] || fail "filter retained nonmatching sibling or omitted match"
  press Escape; sleep 0.5
  latest="$(grep -F "[tvfs] ReadDir tab=1 root=$FIXTURE entries " "$LOG" | tail -1)"
  [[ "$latest" == *"alpha/shared"* ]] || fail "escape did not clear active tree filter"
  finish
}
