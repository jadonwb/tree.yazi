scenario_navigation_deep() {
  TREE_TEST_STYLE=lines begin_scenario navigation_deep
  enter_view
  press l; wait_log "root=$FIXTURE entries .*alpha/shared" || fail "right did not expand alpha"
  press j l; wait_log "root=$FIXTURE entries .*alpha/shared/dup.txt" || fail "right did not expand nested shared directory"
  pane nested
  grep -q '├─\|└─' "$DIR/pane-nested.txt" || fail "tree connectors missing"
  press h; sleep 0.4
  local latest
  latest="$(grep "\[tvfs\] ReadDir tab=.*root=$FIXTURE " "$LOG" | tail -1)"
  [[ "$latest" != *"alpha/shared/dup.txt"* ]] || fail "left did not prune nested rows"
  press Home; press j j; sleep 0.2
  press L; sleep 0.4
  if grep -F "root=$FIXTURE/linked-alpha " "$LOG" >/dev/null; then fail "root_down traversed a linked directory"; fi
  press H; wait_log "root=$(dirname "$FIXTURE")" || fail "root_up did not reroot"
  finish
}

scenario_navigation_native_hover() {
  local latest_hover reveal_count
  begin_scenario navigation_native_hover
  enter_view
  press l
  wait_log "\[tvfs\] ReadDir tab=.*root=$FIXTURE entries .*alpha/shared" || fail "expand refresh did not expose shared row"
  press j
  wait_log "\[tvfs\] cancel stale reveal on hover $FIXTURE/alpha/shared" || fail "native hover did not cancel pending reveal"
  sleep 0.3
  latest_hover="$(grep -F '[tvfs] hover path=' "$LOG" | tail -1)"
  [[ "$latest_hover" == *"[tvfs] hover path=$FIXTURE/alpha/shared\""* ]] || fail "delayed reveal overrode native j; final hover was: $latest_hover"
  reveal_count="$(grep -Fc "[tvfs] reveal focus $FIXTURE/alpha" "$LOG" || true)"
  [[ "$reveal_count" == 0 ]] || fail "stale focus reveal ran after native j"
  finish
}

scenario_navigation_view_exit() {
  local reveal_count latest_cwd
  begin_scenario navigation_view_exit
  enter_view
  press l
  wait_log "\[tvfs\] ReadDir tab=.*root=$FIXTURE entries .*alpha/shared" || fail "expand refresh did not complete before physical exit"
  reveal_count="$(grep -Fc "[tvfs] reveal focus $FIXTURE/alpha" "$LOG" || true)"
  press X
  wait_log '\[tvfs\] cancel stale reveal on View exit' || fail "same-root View exit did not cancel the pending reveal"
  sleep 0.6
  [[ "$(grep -Fc "[tvfs] reveal focus $FIXTURE/alpha" "$LOG" || true)" == 0 ]] || fail "stale focus reveal ran after same-root View exit"
  latest_cwd="$(grep -F '[tvfs] realcwd ' "$LOG" | tail -1)"
  [[ "$latest_cwd" == *"[tvfs] realcwd $FIXTURE\""* ]] || fail "View did not remain exited at its physical root"
  [[ "$(grep -Fc "[tvfs] reveal focus $FIXTURE/alpha" "$LOG" || true)" == "$reveal_count" ]] || fail "focus reveal ran after same-root View exit"
  finish
}
