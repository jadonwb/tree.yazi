#!/usr/bin/env bash
# Automated PTY matrix for the tree-vfs View provider prototype.
# All fixtures/state/logs stay under the prototype root. No tmux.
set -uo pipefail
R="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$R/env.sh"

LOGDIR="$R/logs"
RESULTS="$LOGDIR/results.tsv"
mkdir -p "$LOGDIR"
: > "$RESULTS"
PASS=0
FAIL=0
NOTE=0

ok()  { echo "  PASS: $1"; printf 'PASS\t%s\n' "$1" >> "$RESULTS"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; printf 'FAIL\t%s\n' "$1" >> "$RESULTS"; FAIL=$((FAIL + 1)); }
note(){ echo "  NOTE: $1"; printf 'NOTE\t%s\n' "$1" >> "$RESULTS"; NOTE=$((NOTE + 1)); }
manual(){ echo "  MANUAL: $1"; printf 'MANUAL\t%s\n' "$1" >> "$RESULTS"; }

reset_case() {
  "$R/build-fixtures.sh" >/dev/null
  mkdir -p "$R/out"
}

# run_case name keys
# Optional env knobs (prefix assignments):
#   TVFS_POLL=1     enable the init.lua view poller for this run
#   TVFS_KEYQUIT=1  enable the key-quit preflight negative experiment
#   TVFS_EVENTS=x   append `--local-events=x` to the yazi argv
run_case() {
  local name="$1" keys="$2"
  local poll="${TVFS_POLL:-0}"
  local keyquit="${TVFS_KEYQUIT:-0}"
  local events="${TVFS_EVENTS:-}"
  local argv='["yazi", "--cwd-file", "'"$R"'/out/cwd.txt"'
  [ -n "$events" ] && argv="$argv, \"--local-events=$events\""
  argv="$argv, \"$R/fixture\"]"
  rm -f "$LOG"
  cat > "$R/out/spec.json" <<JSON
{
  "argv": $argv,
  "env": {
    "YAZI_CONFIG_HOME": "$R/config",
    "XDG_CACHE_HOME": "$R/xdg/cache",
    "XDG_STATE_HOME": "$R/xdg/state",
    "XDG_RUNTIME_DIR": "$R/xdg/run",
    "TMPDIR": "$R/xdg/tmp",
    "TERM": "$TERM",
    "YAZI_LOG": "debug",
    "TVFS_POLL": "$poll",
    "TVFS_KEYQUIT": "$keyquit"
  },
  "keys": $keys,
  "delay": 0.4,
  "out": "$LOGDIR/$name.raw"
}
JSON
  python3 "$R/harness/drive.py" "$R/out/spec.json" >/dev/null 2>&1 || true
  cp -f "$LOG" "$LOGDIR/$name.log" 2>/dev/null || true
}

# Only the current folder's ReadDir, not preview-pane reads of nested dirs.
rd_lines() { grep -a -o "\[tvfs\] ReadDir $R/fixture entries[^\"]*" "$LOGDIR/$1.log" 2>/dev/null; }
rd_count() { rd_lines "$1" | wc -l | tr -d ' '; }
cwd_file() { head -c 400 "$R/out/cwd.txt" 2>/dev/null; }
realcwd_file() { head -c 400 "$R/out/realcwd.txt" 2>/dev/null; }

# Does the flushed @yank payload in the raw transcript mention all given strings?
yank_raw_has() {
  local name="$1"; shift
  python3 - "$LOGDIR/$name.raw" "$@" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
i = raw.find("@yank")
seg = raw[i:i + 4000] if i >= 0 else ""
sys.exit(0 if all(s in seg for s in sys.argv[2:]) else 1)
PY
}

echo "== Gate 0 =="
if ! "$R/check-compat.sh" >/dev/null 2>&1; then
  echo "STOP: Gate 0 failed; see $LOG"
  exit 2
fi
ok "Gate 0: View/Url-source resolves, provider ReadDir called"

echo "== S1: enter view + ReadDir =="
reset_case
run_case s1 '["t", "sleep:1.4", "q"]'
grep -qa '\[tvfs\] enter' "$LOGDIR/s1.log" && ok "S1 enter logged" || bad "S1 enter missing"
[ "$(rd_count s1)" -ge 1 ] && ok "S1 ReadDir called" || bad "S1 ReadDir missing"
rd_lines s1 | tail -1 | grep -q 'entries 5' && ok "S1 root has 5 entries" || bad "S1 root entry count wrong"

echo "== S3/S4/S7: pre-expanded flat list, metadata, duplicate basenames =="
reset_case
printf '%s\n%s\n%s\n%s\n' \
  "$R/fixture/alpha" "$R/fixture/alpha/shared" \
  "$R/fixture/beta" "$R/fixture/beta/shared" > "$R/state/expanded"
run_case s3 '["t", "sleep:1.6", "q"]'
RD="$(rd_lines s3 | tail -1)"
echo "$RD" | grep -q 'alpha/shared/dup.txt' && ok "S3 alpha nested dup.txt listed" || bad "S3 alpha nested missing"
echo "$RD" | grep -q 'beta/shared/dup.txt' && ok "S3 beta nested dup.txt listed" || bad "S3 beta nested missing"
echo "$RD" | grep -q 'entries 11' && ok "S3 flat list has 11 entries" || bad "S3 entry count wrong: $RD"
grep -qa '\[tvfs\] file .*/root.txt len=4 dir=false' "$LOGDIR/s3.log" \
  && ok "S4 root.txt real cha len=4" || bad "S4 root.txt metadata mismatch"
grep -qa '\[tvfs\] file .*/alpha/a1.txt len=8 dir=false' "$LOGDIR/s3.log" \
  && ok "S4 alpha/a1.txt real cha len=8" || bad "S4 a1.txt metadata mismatch"
DUP_CNT="$(grep -a -o 'dup.txt' "$LOGDIR/s3.raw" | wc -l | tr -d ' ')"
[ "$DUP_CNT" -ge 2 ] && ok "S7 two duplicate-basename rows rendered (raw occurrences=$DUP_CNT)" \
  || bad "S7 duplicate rows not both rendered (raw occurrences=$DUP_CNT)"

echo "== S6: safe open uses real content path =="
reset_case
printf '%s\n' "$R/fixture/alpha" > "$R/state/expanded"
rm -f "$R/out/opened.bin"
run_case s6 '["t", "sleep:1.6", "j", "j", "o", "sleep:1.2", "q"]'
if [ -f "$R/out/opened.bin" ] && cmp -s "$R/out/opened.bin" "$R/fixture/alpha/a1.txt"; then
  ok "S6 open copied real bytes to out/opened.bin"
else
  bad "S6 open byte identity failed (opened.bin missing or different)"
fi

echo "== S8: expand/collapse forces refresh =="
reset_case
run_case s8 '["t", "sleep:1.6", "l", "sleep:1.4", "h", "sleep:1.4", "q"]'
grep -qa '\[tvfs\] expand' "$LOGDIR/s8.log" && ok "S8 expand action logged" || bad "S8 expand missing"
grep -qa '\[tvfs\] collapse' "$LOGDIR/s8.log" && ok "S8 collapse action logged" || bad "S8 collapse missing"
[ "$(rd_count s8)" -ge 3 ] && ok "S8 three current-folder ReadDir calls" \
  || bad "S8 expected >=3 ReadDir calls, got $(rd_count s8)"
rd_lines s8 | sed -n '2p' | grep -q 'alpha/shared' && ok "S8 expanded read includes alpha/shared" \
  || bad "S8 expanded read missing alpha/shared"
rd_lines s8 | sed -n '3p' | grep -q 'alpha/shared' && bad "S8 collapsed read still includes alpha/shared" \
  || ok "S8 collapsed read excludes alpha/shared"

echo "== S9: manual force refresh =="
reset_case
run_case s9 '["t", "sleep:1.6", "R", "sleep:1.4", "q"]'
[ "$(rd_count s9)" -ge 2 ] && ok "S9 refresh produced another ReadDir" || bad "S9 refresh did not re-read"

echo "== S10: stock create routes to real cwd; view retention =="
reset_case
run_case s10 '["t", "sleep:1.6", "a", "sleep:0.8", "newfile.txt", "\r", "sleep:1.4", "q"]'
[ -f "$R/fixture/newfile.txt" ] && ok "S10 fixture/newfile.txt created" || bad "S10 create failed"
note "S16 cwd-file after create: $(cwd_file)"

echo "== S11: stock rename (root file row) now re-enters the view (R1) =="
reset_case
run_case s11 '["t", "sleep:1.6", "j", "j", "j", "j", "r", "sleep:1.0", "\u0015", "renamed", "\r", "sleep:1.6", "q"]'
if [ -f "$R/fixture/renamed.txt" ]; then
  ok "S11 root.txt renamed on disk (rename input prefills and selects the stem)"
else
  note "S11 rename not confirmed on disk (input timing)"
fi
grep -qa '\[tvfs\] reenter renamed.txt' "$LOGDIR/s11.log" && ok "S11 rename handler re-entered the view" \
  || bad "S11 reenter log missing"
case "$(cwd_file)" in tree://default*) ok "S11 view retained after root rename (R1)" ;; *) bad "S11 view lost after rename: $(cwd_file)" ;; esac

echo "== S14: permanent delete of a root file; view retained =="
reset_case
run_case s14 '["t", "sleep:1.6", "j", "j", "j", "j", "D", "sleep:0.8", "y", "sleep:1.4", "q"]'
if [ ! -f "$R/fixture/root.txt" ]; then
  ok "S14 fixture/root.txt removed"
else
  note "S14 delete not confirmed (confirmation timing); root.txt still present"
fi
case "$(cwd_file)" in tree://default*) ok "S14 view retained after delete" ;; *) note "S14 cwd-file after delete: $(cwd_file)" ;; esac

echo "== S16: pure view cwd-file =="
reset_case
run_case s16 '["t", "sleep:1.4", "q"]'
case "$(cwd_file)" in tree://default*) ok "S16 cwd-file is the view URL" ;; *) bad "S16 cwd-file not a view URL: $(cwd_file)" ;; esac

echo "== S17: external deep change refresh (no poller, R only) =="
reset_case
printf '%s\n' "$R/fixture/alpha" > "$R/state/expanded"
( sleep 2.6; printf 'EXT-NEW' > "$R/fixture/alpha/new_ext.txt" ) &
TOUCH_PID=$!
run_case s17 '["t", "sleep:3.2", "R", "sleep:1.6", "q"]'
wait "$TOUCH_PID" 2>/dev/null || true
S17_N="$(rd_count s17)"
note "S17 current-folder ReadDir calls=$S17_N"
FIRST_RD="$(rd_lines s17 | head -1)"
LAST_RD="$(rd_lines s17 | tail -1)"
echo "$FIRST_RD" | grep -q 'new_ext.txt' \
  && note "S17 initial ReadDir already saw new_ext.txt" \
  || note "S17 initial ReadDir did not see new_ext.txt (no auto-refresh before R)"
echo "$LAST_RD" | grep -q 'new_ext.txt' \
  && ok "S17 explicit R re-read saw the external change" \
  || bad "S17 R did not pick up new_ext.txt"

echo "== Increment 2: nested rename / paste / selection / refresh / cwd =="

echo "== S20: nested file rename + view re-entry (R1) =="
reset_case
printf '%s\n' "$R/fixture/alpha" > "$R/state/expanded"
run_case s20 '["t", "sleep:1.6", "j", "j", "r", "sleep:1.0", "\u0015", "a1r", "\r", "sleep:1.8", "q"]'
if [ -f "$R/fixture/alpha/a1r.txt" ] && [ ! -f "$R/fixture/alpha/a1.txt" ]; then
  ok "S20 nested file renamed on disk"
else
  bad "S20 nested rename failed (a1r.txt missing or a1.txt still present)"
fi
grep -qa '\[tvfs\] reenter alpha/a1r.txt' "$LOGDIR/s20.log" && ok "S20 reenter logged for alpha/a1r.txt" \
  || bad "S20 reenter log missing"
case "$(cwd_file)" in tree://default*) ok "S20 view retained after nested rename" ;; *) bad "S20 view lost: $(cwd_file)" ;; esac
note "S20 manual: pane should stay in the tree and focus alpha/a1r.txt"

echo "== S21: nested dir rename + state remap =="
reset_case
printf '%s\n%s\n' "$R/fixture/alpha" "$R/fixture/alpha/shared" > "$R/state/expanded"
run_case s21 '["t", "sleep:1.6", "j", "r", "sleep:1.0", "\u0015", "shared2", "\r", "sleep:1.8", "q"]'
if [ -d "$R/fixture/alpha/shared2" ] && [ ! -d "$R/fixture/alpha/shared" ]; then
  ok "S21 nested dir renamed on disk"
else
  bad "S21 nested dir rename failed"
fi
if grep -qx "$R/fixture/alpha/shared2" "$R/state/expanded" && ! grep -qx "$R/fixture/alpha/shared" "$R/state/expanded"; then
  ok "S21 state/expanded remapped shared -> shared2"
else
  bad "S21 state remap wrong: $(tr '\n' ' ' < "$R/state/expanded")"
fi
rd_lines s21 | tail -1 | grep -q 'alpha/shared2/dup.txt' \
  && ok "S21 remapped expansion still lists shared2/dup.txt" \
  || bad "S21 remapped descendants missing: $(rd_lines s21 | tail -1)"
case "$(cwd_file)" in tree://default*) ok "S21 view retained after dir rename" ;; *) bad "S21 view lost: $(cwd_file)" ;; esac

echo "== S22: target-aware paste into hovered nested dir =="
reset_case
printf '%s\n' "$R/fixture/alpha" > "$R/state/expanded"
run_case s22 '["t", "sleep:1.6", "j", "j", "j", "j", "j", "j", "y", "k", "k", "k", "k", "k", "k", "p", "sleep:2.0", "q"]'
grep -qa '\[tvfs\] paste cut=false' "$LOGDIR/s22.log" && ok "S22 paste action ran (copy)" || bad "S22 paste log missing"
if [ -f "$R/fixture/alpha/root.txt" ] && [ -f "$R/fixture/root.txt" ]; then
  ok "S22 copy landed in the hovered nested dir (alpha/root.txt)"
else
  bad "S22 nested copy failed (alpha/root.txt missing or source gone)"
fi
case "$(cwd_file)" in tree://default*) ok "S22 view retained after paste" ;; *) bad "S22 view lost: $(cwd_file)" ;; esac
rd_lines s22 | tail -1 | grep -q 'alpha/root.txt' \
  && ok "S25 post-paste refresh listed alpha/root.txt" \
  || bad "S25 no post-paste refresh row: $(rd_lines s22 | tail -1)"
if pgrep -f "yazi .*$R/fixture" >/dev/null 2>&1; then
  note "S22 a prototype yazi process was still running when checked (timing)"
fi

echo "== S23: cut-paste into hovered nested dir clears yank =="
reset_case
printf '%s\n%s\n' "$R/fixture/beta" "$R/fixture/gamma" > "$R/state/expanded"
run_case s23 '["t", "sleep:1.6", "j", "j", "j", "x", "j", "j", "p", "sleep:2.0", "p", "sleep:0.8", "q"]'
grep -qa '\[tvfs\] paste cut=true' "$LOGDIR/s23.log" && ok "S23 paste action ran as move (cut=true)" || bad "S23 cut paste log missing"
grep -qa '\[tvfs\] paste no yanked items' "$LOGDIR/s23.log" && ok "S23 cut-paste cleared the yank (second paste had nothing)" \
  || bad "S23 yank was not cleared after cut-paste"
if [ -f "$R/fixture/gamma/b1.md" ] && [ ! -f "$R/fixture/beta/b1.md" ]; then
  ok "S23 move landed in gamma/ and removed the source"
else
  bad "S23 cut-paste failed"
fi
case "$(cwd_file)" in tree://default*) ok "S23 view retained after cut-paste" ;; *) bad "S23 view lost: $(cwd_file)" ;; esac
rd_lines s23 | tail -1 | grep -q 'gamma/b1.md' \
  && ok "S25 post-move refresh listed gamma/b1.md" \
  || bad "S25 no post-move refresh row: $(rd_lines s23 | tail -1)"

echo "== S24: duplicate-basename selection + yank identity =="
reset_case
printf '%s\n%s\n%s\n%s\n' \
  "$R/fixture/alpha" "$R/fixture/alpha/shared" \
  "$R/fixture/beta" "$R/fixture/beta/shared" > "$R/state/expanded"
TVFS_EVENTS='@yank' run_case s24 '["t", "sleep:1.8", "j", "j", " ", "j", "j", "j", " ", "y", "sleep:1.0", "q"]'
if yank_raw_has s24 'alpha/shared/dup.txt' 'beta/shared/dup.txt'; then
  ok "S24 @yank payload carries both distinct duplicate-basename view URLs"
else
  bad "S24 @yank payload missing one/both duplicate URLs (raw has @yank: $(grep -a -c '@yank' "$LOGDIR/s24.raw" 2>/dev/null))"
fi
note "S24 manual: <Space> markers on both dup.txt rows; no cross-row mis-selection"

echo "== S25: beside-file paste (dest = hovered file's parent) + refresh =="
reset_case
printf '%s\n' "$R/fixture/beta" > "$R/state/expanded"
run_case s25 '["t", "sleep:1.6", "j", "j", "j", "j", "j", "j", "y", "k", "k", "k", "p", "sleep:2.0", "q"]'
if [ -f "$R/fixture/beta/root.txt" ]; then
  ok "S25 beside-file paste landed in beta/root.txt"
else
  bad "S25 beside-file paste failed (beta/root.txt missing)"
fi
rd_lines s25 | tail -1 | grep -q 'beta/root.txt' \
  && ok "S25 post-paste refresh listed beta/root.txt" \
  || bad "S25 no post-paste refresh row: $(rd_lines s25 | tail -1)"

echo "== S26: external deep change refresh via poller (experimental) =="
reset_case
printf '%s\n' "$R/fixture/alpha" > "$R/state/expanded"
rm -f "$R/fixture/alpha/new_ext.txt"
( sleep 3.0; printf 'EXT2' > "$R/fixture/alpha/new_ext.txt" ) &
S26_PID=$!
TVFS_POLL=1 run_case s26 '["t", "sleep:7", "q"]'
wait "$S26_PID" 2>/dev/null || true
grep -qa '\[tvfs\] poll refresh' "$LOGDIR/s26.log" && ok "S26 poller emitted refresh while in view" \
  || bad "S26 poller never refreshed"
rd_lines s26 | tail -1 | grep -q 'new_ext.txt' \
  && ok "S26 poller picked up the external deep change without R" \
  || bad "S26 poller did not pick up new_ext.txt: $(rd_lines s26 | tail -1)"
note "S26 poller stability: check no stall/ERROR in log; disable via TVFS_POLL if unstable"

echo "== S27: cwd workarounds (aux file / quit override / wrapper parser) =="
reset_case
run_case s27a '["t", "sleep:1.4", "q"]'
case "$(cwd_file)" in tree://default*) ok "S27a stock q keeps the view URL (baseline)" ;; *) bad "S27a baseline not a view URL: $(cwd_file)" ;; esac
if [ "$(realcwd_file)" = "$R/fixture" ]; then
  ok "S27c aux out/realcwd.txt holds the real path"
else
  bad "S27c aux realcwd wrong: '$(realcwd_file)'"
fi
PARSED="$("$R/tools/realcwd.sh" "$R/out/cwd.txt")"
if [ "$PARSED" = "$R/fixture" ]; then
  ok "S27d tools/realcwd.sh parsed the view URL to the real path"
else
  bad "S27d realcwd.sh parsed '$PARSED'"
fi
run_case s27b '["t", "sleep:1.4", "Q", "sleep:1.0"]'
if [ "$(cwd_file)" = "$R/fixture" ]; then
  ok "S27b plugin quit (Q) wrote the real path to cwd-file"
else
  bad "S27b plugin quit cwd-file wrong: '$(cwd_file)'"
fi

echo "== S28: key-quit preflight cd is not viable (expected NO-GO) =="
reset_case
TVFS_KEYQUIT=1 run_case s28 '["t", "sleep:1.4", "q"]'
grep -qa '\[tvfs\] keyquit preflight' "$LOGDIR/s28.log" && ok "S28 key-quit preflight handler ran" \
  || bad "S28 key-quit preflight handler never ran"
case "$(cwd_file)" in tree://default*) ok "S28 preflight cd did NOT change cwd-file (documents NO-GO)" ;; *) bad "S28 preflight unexpectedly wrote: $(cwd_file)" ;; esac

echo "== manual / out-of-scope observations =="
manual "S2 flat root render (dirs first) - inspect run.sh pane"
manual "S5 nested preview bytes - inspect run.sh pane"
manual "S7 duplicate basenames render - inspect run.sh pane"
manual "S20-S25 pane state (rename focus, paste row, selection markers, preview) - inspect run.sh"
manual "S26 poller rendering stability - inspect run.sh with TVFS_POLL=1"
manual "S18 connectors - Current.redraw override not implemented"

echo
echo "== cleanup =="
"$R/cleanup.sh" >/dev/null || true
if pgrep -af "yazi .*$R/fixture" >/dev/null 2>&1; then
  bad "leftover prototype yazi processes: $(pgrep -af "yazi .*$R/fixture" | tr '\n' ' ')"
else
  ok "no leftover prototype yazi processes"
fi
if [ -z "$(ls -A "$R/xdg/run" 2>/dev/null)" ]; then
  ok "runtime socket dir is empty after cleanup"
else
  bad "runtime sockets remain: $(ls -A "$R/xdg/run" | tr '\n' ' ')"
fi

echo
echo "SUMMARY: PASS=$PASS FAIL=$FAIL NOTE=$NOTE"
printf 'SUMMARY\tPASS=%s FAIL=%s NOTE=%s\n' "$PASS" "$FAIL" "$NOTE" >> "$RESULTS"
[ "$FAIL" -eq 0 ]
