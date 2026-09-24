scenario_external_hover_preview() {
  begin_scenario external_hover_preview
  enter_view
  local before idle changed stable
  before="$(grep -c "\[tvfs\] ReadDir tab=.*root=$FIXTURE " "$LOG" || true)"
  sleep 1.1
  idle="$(grep -c "\[tvfs\] ReadDir tab=.*root=$FIXTURE " "$LOG" || true)"
  [[ "$before" == "$idle" ]] || fail "idle polling caused ReadDir"
  printf external >"$FIXTURE/external.txt"
  for _ in {1..30}; do sleep 0.1; grep -q "ReadDir tab=.*root=$FIXTURE .*external.txt" "$LOG" && break; done
  changed="$(grep -c "\[tvfs\] ReadDir tab=.*root=$FIXTURE " "$LOG" || true)"
  [[ "$changed" -eq $((idle + 1)) ]] || fail "external create produced $((changed-idle)) root reads, expected exactly one"
  sleep 1.1
  stable="$(grep -c "\[tvfs\] ReadDir tab=.*root=$FIXTURE " "$LOG" || true)"
  [[ "$stable" == "$changed" ]] || fail "change refresh repeated during idle interval"
  press G; sleep 0.3
  printf changed >"$FIXTURE/root.txt"
  for _ in {1..30}; do sleep 0.1; grep -q '\[tvfs\] poll change' "$LOG" && break; done
  grep -q '\[tvfs\] poll change' "$LOG" || fail "hovered-file mutation was not detected"
  finish
}
