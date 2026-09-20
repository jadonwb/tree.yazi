# tree-vfs prototype results

Experiment: can Yazi b8973fb's experimental Lua **View** VFS provider back a
tree.yazi-style flattened hierarchy over real local files, including nested
mutations, selection identity, refresh, view retention and a usable cwd?

Two increments have been run against the pinned build:

- **Increment 1** (isolated feasibility): provider contract, flat list,
  metadata, previews, duplicate basenames, expand/collapse, explicit refresh,
  stock create/rename/delete, cwd-file baseline.
- **Increment 2** (this result set): nested rename + view re-entry, dir rename
  `state/expanded` remap, target-aware paste/cut-paste over native tasks,
  duplicate-basename selection/yank identity, post-op and external refresh,
  and contained `--cwd-file` workarounds.

## Installed-build gate (Gate 0) — PASS

- `yazi --version`: **26.9.1 (b8973fb 2026-09-12)**, Debug: false,
  x86_64-unknown-linux-gnu. Exactly the pinned target.
- Config-path registration via `config/vfs.toml`
  (`[tree.default] kind="view" run="tree-vfs"`) works.
- `Url { Url(fixture), scheme="tree", domain="default", data={depth=0} }`
  resolves: `url-ok=true physical=/home/jadon/.config/yazi/plugins/tree-vfs.yazi/fixture`.
- Provider `ReadDir` is invoked after `t`
  (`[tvfs] ReadDir ... entries 5` with the increment-2 fixture).

## Automated matrix — 54 PASS / 0 FAIL / 6 NOTE

Final run was executed synchronously in the foreground: `./test.sh`, **EXIT=0**,
`logs/results.tsv` = 54 PASS, 0 FAIL, 6 NOTE, 6 MANUAL. No ERROR/traceback lines
in any `logs/s*.log`. All filesystem assertions target paths below
`/home/jadon/.config/yazi/plugins/tree-vfs.yazi`.

Increment-1 checks (all PASS): enter + ReadDir, pre-expanded flat list (11
entries) and real metadata, duplicate-basename rows rendered, safe open byte
identity, expand/collapse refresh, manual `R` refresh, stock create, stock
rename (now also exercises R1), stock delete, pure-view cwd-file, explicit-`R`
external change.

Increment-2 checks (all PASS): S20 nested file rename + re-entry, S21 nested dir
rename + state remap, S22 target-aware copy paste (hovered dir), S23 cut-paste
(hovered dir) + yank cleared, S24 duplicate-basename selection + `@yank`
identity, S25 beside-file paste, S26 external deep change via poller, S27
cwd workarounds, S28 key-quit negative.

## Increment-2 per-blocker results

| Blocker | Mechanism | Result |
| --- | --- | --- |
| Nested file rename + view retention | R1: `config/init.lua` subscribes to `rename`; `remap_state` then `ya.emit("reveal", { target = portal:join(rel), raw = true, no_dummy = true })` on the renamed entry's **view URL** | **PASS / GO** — `alpha/a1.txt` -> `alpha/a1r.txt` on disk, log `[tvfs] reenter alpha/a1r.txt`, cwd-file stays `tree://...`. R2 (plugin-owned rename) was **not needed** |
| Nested directory rename | same R1 + `state/expanded` old->new prefix remap | **PASS / GO** — `alpha/shared` -> `alpha/shared2` on disk, `state/expanded` remapped, refreshed read still lists `alpha/shared2/dup.txt`, view retained |
| Target-aware copy paste | `plugin tree-vfs -- paste`: hovered dir -> dest; `ya.task("copy", {from=<view url>, to=<view url>, force=false, follow=false}):spawn()` | **PASS / GO** — `root.txt` copied to `fixture/alpha/root.txt`, source kept, view retained |
| Cut-paste (move) | `x` then `p`: `ya.task("move", {from,to,force})`, then `unyank` + `escape --select` | **PASS / GO** — `beta/b1.md` moved to `gamma/b1.md`, source gone, a second `p` logged `[tvfs] paste no yanked items` (yank/selection cleared) |
| Beside-file paste | dest = hovered file's view parent | **PASS / GO** — `beta/root.txt` written, `root.txt` kept |
| Selection/yank identity (duplicate basenames) | URL-keyed selection, relative-path keys | **PASS / GO** — `--local-events=@yank` payload carried 2 distinct view URLs: `.../alpha/shared/dup.txt` and `.../beta/shared/dup.txt` |
| Post-operation refresh | DDS `duplicate`/`move`/`trash`/`delete` -> `refresh` while a view is active | **PASS / GO** — one `[tvfs] refresh after duplicate` and one `[tvfs] refresh after move`; refreshed ReadDir listed the new rows |
| External deep change | `TVFS_POLL=1` poller (`ya.async` + `ya.sleep(2)`, refresh while the cd state is a view) | **PASS / GO-with-caveat** — poller emitted 6 refreshes; `fixture/alpha/new_ext.txt` created externally appeared in a ReadDir without `R` |
| `--cwd-file` | option C aux `out/realcwd.txt`; option D `Q` -> `plugin tree-vfs -- quit`; option A `tools/realcwd.sh` | **PASS / GO** — baseline stock `q` keeps the view URL; `out/realcwd.txt` = real path; `tools/realcwd.sh out/cwd.txt` = real path; `Q` wrote the real path |
| `key-quit` preflight (option B) | `ps.sub("key-quit")` emits a `cd` | **PASS (expected NO-GO)** — handler ran, but `--cwd-file` is still `tree://...`; `app:quit` reads `cx.mgr.cwd()` before the queued `cd` |

## Key implementation facts learned at runtime

- **R1 ordering works.** Stock `rename` reveals the *physical* path first
  (`old.parent()` loses the view spec), and the `rename` DDS event is delivered
  after that reveal. The handler re-enters the view by revealing the renamed
  entry's view URL; for `portal:join(rel)` the loc has `urn=rel`,
  `trail=root portal`, so `reveal` cds to the portal and hovers the relative key.
- **Native tasks accept view URLs.** `ya.task("copy"/"move", ...)` from the
  plugin entry places the job on the normal scheduler; the Local engine performs
  the I/O and the view is retained. No production-style copy engine was needed.
- **Cut cleanup has no per-URL API.** A cut paste must `unyank` (clears all
  yanked) plus `escape --select`; a follow-up `p` logging `no yanked items`
  confirms it.
- **`@yank` local delivery drops File data.** `EmberYank::owned` ignores the
  file set, so a local `ps.sub("@yank")` always sees zero files; identity was
  therefore asserted from the borrowed payload flushed by
  `--local-events=@yank`.
- **Local-backed views are excluded from the 2 s non-local poll** and notify
  reports real paths, so external deep changes need the explicit poller (or
  `R`).
- **`ya.sync` is not available in `init.lua`.** Calling it fails with
  `` `ya.sync()` must be called in a plugin `` and aborts startup. Handlers
  invoked from `accept_payload`/`preflight` run inside `Lives::scope`, so they
  read `cx` directly; the poller only reads a plain Lua global (`TVFS_IN_VIEW`)
  updated by the `cd` handler.
- **`ya.async` handles abort on Drop.** The returned handle must stay referenced
  (e.g. a Lua global) or Lua GC aborts the poller immediately.

## Deviations from the increment-2 evidence spec (documented)

- The option-D quit override is bound to **`Q`**, not the spec's `q`. Binding
  `q` would change every existing scenario that uses stock `q` to quit
  (S14/S16 cwd-file assertions) and would invalidate the S28 stock-`q` negative
  experiment. The plan asks to keep the existing matrix, so `Q` is used and
  documented here and in `manual-checklist.md`.
- `fs.op`/`update_files` injection was **not used**; DDS-event refresh plus the
  contained poller sufficed, matching the plan's "last resort" condition.
- Fixture `delta/` was added; increment-1 counts were updated accordingly
  (root 5 entries, pre-expanded 11 entries) and existing navigation/rename
  assertions were shifted.

## Failures / blockers

None outstanding. The two defects found during the first increment-2 run were
fixed and re-verified:

1. `pairs(cx.yanked)` yields `(index, File)`; iterating with one variable gave
   the index. Fixed to `for _, f in pairs(cx.yanked)`.
2. The poller's `ya.sync` guard is illegal in `init.lua` and prevented startup;
   replaced with a `TVFS_IN_VIEW` global set by the `cd` handler, and the
   `ya.async` handle is kept referenced.

## Process / socket cleanup

Final `test.sh` cleanup section passed: **no leftover prototype yazi
processes** and **`xdg/run` empty**. During iteration a background matrix was
terminated with prototype-scoped kills only (by PID/`/proc` cwd under
`/home/jadon/.config/yazi/plugins/tree-vfs.yazi`); no un-scoped cleanup was used. The user's
unrelated yazi instances were never touched.

## Unresolved / manual observations

- S2/S5/S7/S18 and the pane-state aspects of S20-S25 remain manual
  (`run.sh`); the automated matrix asserts disks, logs and cwd files.
- S26 poller rendering stability was not asserted beyond "no error/stall during
  the 9 s run"; run `TVFS_POLL=1 ./run.sh` to observe. Disable the flag if the
  refresh loop is found to disturb rendering.
- Task progress UI and the exact focus/hover of the renamed row are manual.
- Connectors/indentation need a `Current.redraw` override and were out of scope.
- Trash (`d`) was not exercised to keep the run non-destructive; permanent
  delete (`D`) covers the delete path.

## Go / no-go

**GO — preserve this prototype outside `/tmp`.**

Every increment-2 blocker is answered affirmatively by a contained mechanism
that lives entirely in the plugin/`init.lua`/keymap/prototype scripts:

- nested rename and directory rename re-enter the view cleanly via R1 (no
  plugin-owned rename fallback required);
- target-aware copy/move paste is a thin `ya.task` route with view URLs;
- duplicate basenames are unambiguously selectable/yankable;
- post-op refresh is event-driven, and external deep changes can be covered by
  an opt-in poller (GO-with-caveat on poller rendering cost);
- shell-usable cwd is available via the auxiliary real-cwd file (primary) with
  the `Q` override and the wrapper parser as fallbacks.

No user config, production `tree.yazi`, custom sorting, or shell wrapper was
modified.
