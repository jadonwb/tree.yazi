# Manual / observational checklist

Run `./run.sh` in a real terminal, press `t` to enter the view, and inspect:

1. **S2 flat root render** — pane shows `alpha`, `beta`, `delta`, `gamma`,
   `root.txt` (directories first, provider order preserved by `sort_by = "none"`).
2. **S5 nested preview** — expand `alpha` (`l`), hover `alpha/a1.txt`; the
   preview pane shows `ALPHA-A1`. Nested `.md`/`.bin` likewise.
3. **S7 duplicate basenames** — with `alpha/shared` and `beta/shared` expanded,
   both `alpha/shared/dup.txt` and `beta/shared/dup.txt` rows render and are
   separately hoverable. Rows display the root-relative path, so the two are
   visually distinct.
4. **S20 nested rename + re-entry** — hover a nested file, `r`, rename (e.g.
   `a1` -> `a1r`; the input keeps the extension). The file changes on disk and
   the pane should stay in the tree with the renamed row focused (R1: the
   `rename` DDS handler reveals the renamed entry's view URL). If the pane
   leaves the view, R1 failed and the plugin-owned rename fallback (R2) is
   required.
5. **S21 nested dir rename + remap** — rename `alpha/shared` to `shared2`; the
   real dir is renamed and `state/expanded` is rewritten so the expanded
   descendant `alpha/shared2/dup.txt` is still listed after refresh.
6. **S22/25 paste** — `y` a file, hover a directory (S22) or another file
   (S25), press `p`; the copy lands in the hovered target's real dir (or the
   hovered file's parent) and the view is retained. `P` (`paste-force`)
   overwrites. Task progress should be visible in the progress bar.
7. **S23 cut-paste** — `x` a file, hover a directory, `p`; the file moves into
   the nested real dir, the view is retained, and the yank/selection markers
   clear.
8. **S24 selection/yank identity** — `<Space>` marks the intended rows (it also
   advances the cursor); `y` yanks exactly the selected duplicates. No
   cross-row mis-selection.
9. **S28 key-quit preflight (expected negative)** — with `TVFS_KEYQUIT=1`, the
   `key-quit` preflight can queue a `cd`, but `--cwd-file` still contains the
   view URL because `app:quit` reads `cx.mgr.cwd()` first. Use the auxiliary
   file or the `Q` override instead.
10. **S26 poller** — run `TVFS_POLL=1 ./run.sh`; an externally created file
    under an expanded directory should appear within ~2 s without pressing `R`.
    Observe rendering stability; if it stalls, leave the poller off.
11. **S18 connectors** — not implemented. A `Current.redraw` override would be
    needed to add indentation/connectors; out of scope for this prototype.
12. **Trash** — not exercised (would write to the real XDG trash). Use `D`
    (permanent delete) instead, which is covered by S14.

## cwd workarounds

- **Option C (primary):** `out/realcwd.txt` is maintained from the prototype's
  cd state; a wrapper should read it instead of `--cwd-file`.
- **Option D:** `Q` (deliberately not `q`) runs `plugin tree-vfs -- quit`, which
  cds to the physical path before quitting so `--cwd-file` holds the real path.
- **Option A (fallback):** `tools/realcwd.sh out/cwd.txt` parses the view URL.
- **Option B:** the `key-quit` preflight route is a documented NO-GO (S28).

Cleanup after manual runs: `./cleanup.sh`.
