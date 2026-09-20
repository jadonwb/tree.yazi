# tree.yazi

An experimental Yazi plugin exploring a live, recursive, navigable tree view of
the current directory, plus an independent preview-pane toggle.

**Status: arbitrary-depth lazy expansion.** When tree mode is on, the plugin
renders the current directory's existing rows flush-left and lets you expand any
safe directory in place, one level at a time. Expanded directories inject their
real children directly after them, so every subtree stays grouped beneath its
parent and renders with compact branch connectors that stay correct at any
depth. Collapsing prunes the whole subtree again. Because the injected rows are
real filesystem entries in the active folder, navigation, hover, selection,
mouse, and drag/drop all use Yazi's native `Folder` cursor and
`Entity`/`Linemode` rendering.

What the plugin does today:

- **Tree mode** (`toggle`) collapses the parent column into the current pane and
  enables expand/collapse navigation.
- **Preview mode** (`preview`) toggles the preview pane; turning it off gives the
  preview space to the current pane.

Both toggles are **tab-local**: toggling in one tab never changes another, and
switching back to a tab restores that tab's own modes. A new tab inherits the
creating tab's tree and preview modes (so `tab_create` from a tree tab opens a
tree tab), while its expansion set, root order, and filter start empty. When the
creating tab is a tree tab, its configured (pre-pin) sort is carried over to the
new tab too, because Yazi clones the creator's sort preference (already pinned to
`none` while the tree is expanded); leaving tree mode in the new tab therefore
restores that configured sort rather than the pinned `none`.

The two toggles are independent and compose, so all four combinations restore
predictably:

| tree | preview | effective ratio |
| ---- | ------- | --------------- |
| off  | on      | the configured ratio, unmodified |
| on   | on      | parent collapsed, preview keeps its share |
| off  | off     | preview space in current |
| on   | off     | parent and preview space in current |

The plugin captures one canonical base ratio from `rt.mgr.ratio` while the
active tab is idle (tree off, preview on), recomposes the effective ratio from
that base and the active tab's own modes whenever a tab is activated or toggled,
and applies it with `rt.mgr.ratio = ...` plus `ya.emit("app:resize", {})`. Yazi
keeps a single global ratio, so an inactive tab's layout is only observable once
it becomes active; every activation re-applies the incoming tab's ratio. The
plugin does not patch `Tab.layout` or `Tab._chunks`.

## Tree expansion

While tree mode is enabled, the plugin overrides only `Current.redraw` and
reproduces the stock renderer over the pane's already-loaded folder window.
Each existing item produces exactly one row through `Entity:new(file):redraw()`,
so hover, selection markers, linemode text, and drag/drop rendering are
preserved. Root entries (direct children of the current directory) render
flush-left with no prefix; only injected descendants are prefixed with branch
connectors, so the listing reads as a tree without a synthetic root row. When
tree mode is disabled or the directory is empty, rendering falls back to the
unmodified stock renderer.

Expansion is lazy and recursive: only directories you explicitly expand are
read, and only directories reachable through an expanded ancestor are read, so
an expansion buried under a collapsed parent costs no I/O. Each directory is
read with Yazi's asynchronous `fs.read_dir` and its children are ordered
directories-first, then alphabetically, independently at every level. Reads are
uncapped: there is no per-directory entry limit, so a very large expanded
directory reads all of its entries on every rebuild.

Expansion works on the current directory's real folder entries at any depth:

- `l` expands the hovered directory, at any depth. It is a no-op on files and on
  symlinked or indirect (reparse-point) directories, which are never descended
  into to avoid link cycles. A linked directory is still shown and can be
  entered with `Enter`/`L`.
- `h` collapses the hovered expanded directory, forgetting that whole subtree
  (every expansion keyed below it is pruned). From a nested row that is not
  itself expanded, it collapses and focuses the immediate parent instead. `h`
  never leaves the current directory.
- `H` reroots the tree one directory up, to the current tree root's parent. It
  is a no-op at the filesystem root. Outside tree mode it re-emits stock `back`.
- `L` reroots the tree into the hovered directory. On an injected file it
  reveals the file in its containing directory (one reroot-plus-hover action);
  on a root-level file it opens the file normally. Outside tree mode it re-emits
  stock `forward`.
- `Enter` enters a hovered directory (which becomes the new tree root) and opens
  hovered files normally.

Multiple directories can be expanded at once at any depth, and collapsing one
leaves unrelated expansions intact. Expansion state is kept per tab and per
tree root: leaving a directory saves its expanded set, root order, and
tree-filter query, and returning to it (through `H`, `L`, `Enter`, a mouse
click that reveals a nested row, a `cd` keymap, or history back/forward)
restores that same hierarchy instead of showing Yazi's cached rows against an
empty expansion set. Each tab keeps its own saved roots and its own tree/preview
modes, so switching or creating tabs never leaks one tab's expansions, filters,
or layout into another, and toggling tree in one tab leaves every other tab
untouched. A root whose Yazi folder-cache entry was evicted is re-injected
asynchronously, so its expanded children can be briefly missing right after the
return until the read completes. Renames and removals re-key or prune the saved
roots for every tab, so a renamed or deleted path can never resurrect its old
expansion later. Toggling tree view off and back on preserves that tab's state:
disabling removes the injected rows and leaves normal mode with only the
folder's real entries, while re-enabling restores the tab/root's saved
expansions and root order (with any native filter transferred according to
`filter_mode`).

Because Yazi caches a whole Folder (including the plugin's injected rows) per
tab, a tree tab's injected Folder stays valid while the tab is inactive, but can
never render as flat classic rows: becoming active reconciles the incoming tab
unconditionally, and a classic tab has its cached descendants stripped
synchronously before the first frame. Each asynchronous rebuild also records the
tab and generation it belongs to, so a stale or superseded read can never inject
into a tab that has since become active or into a tab that has become classic.

### Renames and folder mutations

The injected rows and the expansion state are keyed by URL, so a rename would
otherwise strand descendants under an old path. The plugin subscribes to the
`rename` and `bulk-rename` DDS events, remaps the expanded directory URLs and the
captured root order, and coalesces the result through the same
generation-checked async rebuild pipeline. Renaming a root keeps that
root's slot instead of letting Yazi's incremental upsert append it to the end,
and renaming a child under an expanded directory refreshes the child rows.
Renaming a directory rewrites every expansion key beneath it from the old
cwd-relative prefix to the new one (with path-boundary comparison, so renaming
`alpha/b` never touches `alpha/bc`), so an expanded descendant stays expanded
under the new name instead of silently collapsing and leaving a stale key that
could later resurrect expansion at the old URL. A directory moved outside the
tree root has its subtree keys pruned instead. The same re-keying is applied to
the saved per-root state of every tab regardless of which tab the rename came
from, so a rename performed in a classic tab cannot leave a tree tab's stale
expansion keys behind, and a root that was expanded, left, and then renamed
underneath can still not resurrect its old path when revisited. Live-state
remap and the follow-up rebuild apply only to the active tree tab.
Bulk rename resolves each key
against the untouched old-to-new map, so swaps and chains stay
order-independent. Toggling hidden files schedules a rebuild after the actor, so
hidden entries are re-split without flattening the injected hierarchy.

`r` is routed through the plugin. Outside tree mode, when the hovered row is a
depth-0 entry, or when there is an active native multi-selection, it re-emits
stock rename with the preset binding's `cursor = "before_ext"`, so root renames
and stock bulk rename (which the plugin already remaps through the
`bulk-rename` subscription) keep stock caret placement and behave as before.
Because the prepended `r` binding replaces the user's original action args, any
customized `r` arguments (for example `--empty`) are not forwarded. For a single
injected descendant at any depth it opens a positioned input prefilled with the
complete current name, resolves the new path beside that descendant's parent,
asks for confirmation before overwriting an existing sibling, and performs the
rename with `fs.rename` followed by a prefix re-key of the expansion set and a
generation-checked rebuild of the controlled hierarchy (so renaming an expanded
nested directory keeps its expanded descendants). The current root and working
directory are never changed, and cancelling the input is a no-op.

The plugin-owned input reproduces stock `rename --cursor=before_ext`
placement: for a regular file it opens a realtime input and then emits the
input layer's own `move` offset, so the caret starts at the last `.` in the name.
Directories, symlinks, special files, dotfiles, and extensionless names keep the
default end-of-value caret, matching stock. Because the caret starts before the
extension, clearing a prefilled name with a plain backspace run would leave the
suffix behind; use kill-to-BOL plus kill-to-EOL (or select all) when scripting
renames.

Bulk rename remapping is order-independent: the plugin snapshots the root order
and expanded keys, applies the complete old-to-new URL map to those snapshots
simultaneously, and then performs one generation bump and one coalesced rebuild.
Chained (`A->B`, `B->C`) and swapped (`A->B`, `B->A`) renames therefore resolve
correctly, with a deterministic focus.

Because plugin-owned nested rename cannot use Yazi's internal rename engine, it
has parity limits: it does not emit the protected system `rename` DDS event or
acquire the watcher permit, and it does not run the casefold engine (an exact
same-path rename is the only implicit no-op; every other existing destination
prompts). The explicit hierarchy rebuild supplies tree consistency after the
successful rename. Delegated paths (outside tree mode, depth-0 rows, and
multi-selections) keep stock behavior, including the preset `before_ext` caret
placement.

### External changes (bounded polling)

Yazi's watcher is non-recursive and stock registers only the active tab's
current, parent, and hovered folders, so a mutation inside an expanded directory
at depth 1 or deeper never reaches the injected rows. While the active tab is a
physical tree, the plugin therefore runs one bounded poll loop: once per second
it reads unfollowed metadata (`fs.cha`) for every currently expanded directory
and compares a compact `{ mtime, is_dir, dev, btime }` signature against its last
successful snapshot. A changed mtime, a disappeared directory, a directory
replaced by a different `(dev, btime)` identity or by a non-directory, or an
unreadable one coalesces into a single existing generation-checked rebuild with
the usual focus, filter, and root-order behavior, so external creates, deletes,
and renames refresh visible descendants without touching the injected rows
directly.

Polling scope is intentionally narrow. Only the active tab's expanded
directories are polled: collapsed subtrees are not descended, saved roots that
belong to inactive tabs are never touched, and a native `fd://`/`rg://` provider
View stops the loop entirely so the provider Folder is never reset. The plugin
does not register any watch of its own and deliberately avoids Yazi's
undocumented `watch`/`load` internals, which are unversioned and would replace
Yazi's own watch set; if a stable upstream watcher API appears, this loop is the
replacement point.

An external rename of an expanded directory is preserved on a best-effort basis.
When an expanded path disappears or its `(dev, btime)` changes, the plugin runs
one bounded scan of the current root and the currently expanded directories
(looking no further than that reachable set) for a unique child directory with
the lost identity. On a unique match it remaps the moved directory's complete
expansion prefix to the new URL — descendants, each tab's saved roots, and the
depth-0 root order included — so the subtree stays expanded where it moved. With
no match, more than one match, an unavailable identity, a cross-filesystem
copy/delete, or a destination outside the reachable set, the obsolete prefix is
pruned instead, becoming a tombstone: a directory later recreated at the old path
cannot silently re-expand. Because only `dev` and `btime` are exposed to Lua (no
inode), identity is not a universal guarantee — filesystems with unavailable or
coarse birth times, ambiguous duplicate identities, and case-only renames on
case-insensitive filesystems may collapse to the prune path, and a rename is
detected within roughly one polling interval plus a rebuild.

The rebuild also reconciles reachability: after re-reading the tree it keeps only
the expansion keys it actually reached, plus keys under a directory whose listing
failed (that subtree is unverifiable, not proven gone). A key whose expanded
ancestor chain no longer leads to it is dropped, so a stale key removed from the
live set cannot be resurrected by a later unrelated recreation of its path.

Content-only writes are also covered for one file: the poll additionally
stat-follows the currently hovered visible injected regular file (depth > 0) and
compares its displayed `mtime`/`len`. On a difference, disappearance, or type
change it schedules the same guarded rebuild, whose fresh `File` metadata makes
Yazi's own preview logic rerun the previewer — no forced peek and no cwd change.
This costs at most one extra stat per interval, and only while such a file is
hovered. Writing the file's *contents* still does not change the parent
directory's mtime, so an unexpanded or unhovered file relies on the usual
collapse (`h`) and re-expand (`l`), and filesystems with coarse or unavailable
directory timestamps (or where `mtime` is not exposed) may not observe directory
changes at all.

### Removal (trash and permanent delete)

Stock remove works on injected rows at every depth without plugin routing: `d`
trashes and `D` permanently deletes the selected-or-hovered entries, whether
they are root rows or injected descendants. Yazi's own trash/delete
confirmation popup, task list, progress and error reporting, and
ancestor/descendant selection safety are unchanged and remain authoritative;
the plugin does not intercept the keys or redirect the targets.

On successful completion Yazi emits a batched local `trash`/`delete` DDS event.
The plugin subscribes once and prunes every removed URL and subtree from the
saved per-root state of every tab regardless of which tab is active or in tree
mode, so a removal performed from a classic tab cannot leave a tree tab's stale
expansion keys behind. While the active tab is in tree mode it additionally
prunes those URLs from the live expansion state and row metadata, then runs one
generation-checked rebuild. The cursor anchor follows the pre-removal view:
if the hovered row survives outside every removed subtree it keeps the cursor;
if it was removed, the nearest surviving parent row is focused; if that parent
is not a row (a root-level entry, or a parent removed in the same batch), the
nearest prior surviving visible row is focused, else the nearest next one. The
candidate rows come from the visible set at event time, so an active tree filter
is respected and a fallback that the filter still hides is skipped. Removed rows
therefore disappear immediately, trashing or deleting an expanded directory
takes its injected descendants with it, unrelated expanded branches and an
unrelated hover survive untouched, and the working directory never changes.
Because the saved-state pruning covers every tab, a removed directory cannot
resurrect its old expansion if a new directory is later created at the same
path.

### Target-aware create

`a` is routed through the plugin. Outside tree mode, with no hovered row, or
when the hovered row resolves to the tree root itself (a root-level file), the
plugin re-emits stock `create`, so the ordinary prompt, overwrite confirm,
upsert, and reveal behavior are byte-for-byte stock. Otherwise the destination
is derived from the hovered row: a hovered directory (at any depth) receives the
new entry inside it, and a hovered file receives it beside that file, in the
file's own directory. The plugin opens a stock-like positioned async prompt,
treats a trailing `/` (or `\`) as "create a directory", confirms before
replacing an existing regular file (unless a `--force` argument is bound), and
creates the entry with Yazi's `fs` APIs. The working directory never changes. On
success the cursor is focused on the new URL and, when the destination is part
of the injected hierarchy (or injected rows exist), a generation-checked rebuild
re-injects it in place. Mirroring stock, intermediate components in a typed name
are created.

Collision handling differs by type, and create never uses the trash:

- An existing **regular file** is overwritten by `fs.write` (create+truncate) in
  place: no unlink, no missing-path window, and the inode is preserved.
  Declining the confirm leaves the file untouched; `--force` skips the confirm.
- An existing **directory** can never be replaced by an empty file, so it is a
  clean failure with an error notification (`... already exists as a
  directory`) instead of a confirm followed by an `EISDIR` error. The directory
  and its contents are untouched.
- An existing **symlink** is unlinked at the link path only (a hard unlink,
  never the trash) and then replaced by the new empty file, so the link target's
  bytes are never truncated. This also requires the overwrite confirm unless
  `--force` is bound.

### Target-aware paste, copy, and move

Native `y`/`x`/`unyank` already operate on injected rows at any depth, because
the injected children are real `fs::File` entries in the active folder. The
plugin does not override them. `p` and `P` are routed through the plugin:

- Whenever the resolved destination is the tree root (a root-level file, or no
  hover), or tree mode is off, the plugin re-emits stock `paste` so behavior is
  exactly stock. Outside tree mode `P` re-emits `paste --force`.
- Otherwise the destination is the hovered directory (any depth), or the
  containing directory of a hovered file. The plugin schedules one native
  `ya.task("copy")` / `ya.task("move")` per yanked source with the destination
  path, so the task manager, progress, hooks, watcher reports, and
  `duplicate`/`move` DDS events are identical to stock. Unique-name behavior
  (`name_1`, `name_2`, ...) is left entirely to the scheduler for a normal
  paste; `P` (`plugin tree -- paste --force`) overwrites the destination name
  instead. Note that forcing a directory copy onto an existing directory merges
  the trees rather than deleting entries that are absent from the source.
- A cut paste clears the yank set with `unyank` after the moves are scheduled
  and clears the active selection (`escape --select`) when one exists, since
  Lua has no API to drop only the moved URLs from the selection. A copy paste
  preserves the yank set, like stock.
- Successful `duplicate` and `move` events trigger one generation-checked
  rebuild when either endpoint is the tree root or an expanded directory, so
  moved-away rows disappear and new children are injected under their parent.

Target-aware `link`/`hardlink` remain unsupported: Yazi 26.9.1 exposes no Lua
task kind or `fs` call that reproduces them, so those actions stay stock and
still paste into the current directory.

### Ordering

Injected children must stay immediately beneath their parent, but Yazi re-sorts
a folder's entries on every update. While a tab is in tree mode the plugin
therefore pins that tab's folder sort mode to `none` and restores the tab's own
configured sort (`sort_by`, `reverse`, `dir_first`, `sensitive`, `translit`,
`fallback`) when tree mode is turned off. Because Yazi keeps sort preferences
per tab, the captured handoff is stored on the tab too: a sort request in one
tab never overwrites another tab's saved sort, and each tab restores its own
when it leaves tree mode. The captured root order is preserved during tree mode,
and injected children are ordered alphabetically with directories first.

This is a temporary workaround: while tree mode is on, Yazi's normal root sort
is suspended, so newly created root files may not appear in their usual sorted
position. Sort requests are captured through the `key-sort` preflight and forced
to `by = none` in place, rather than relying on the one-shot pin, so the
controlled ordering survives repeated sort attempts until tree mode exits.

Custom sorting support (sxyazi/yazi#3382) has no implemented API yet.

### Filtering

Yazi's native filter has no DDS event or preflight hook, and it matches the full
urn of every entry. On the flattened tree that hides a parent but keeps
`parent/child` visible, producing orphaned rows disconnected from their
ancestor. Yazi also re-applies the native Entries filter to every injected row,
so leaving it live while descendants are injected double-filters the view.
Native filtering is therefore handed off to the plugin:

- `f` opens a realtime input positioned top-center with the same width as
  Yazi's stock filter popup, and rebuilds the real Entries subset as you type
  (debounced). The popup follows stock behavior: it always opens blank, uses the
  shared filter input name/history, keeps any active tree query applied until
  the first realtime typed value replaces it, and applies each typed value live.
  Yazi's own `entries.filter` is deliberately left unset, so the rendered rows,
  `Folder` cursor, hover, selection, `Entity`/`Linemode`, and stock file
  operations all remain aligned and native.
- Matching is a smart-case literal basename substring: a query containing an
  uppercase character is case-sensitive, otherwise it is case-folded. It is not
  Yazi's regex `Normalizer`.
- A row is shown when its basename matches. An expanded directory is also shown
  when at least one of its children matches, so every matching child keeps its
  ancestor directly above it. Visible rows stay in stable depth-first order
  (each root followed by its visible children).
- Submitting (`<Enter>`) applies the typed query and closes the popup; submitting
  a blank value clears it, matching stock. Cancelling (`<Esc>`) also just closes
  the popup and keeps the latest live-applied query — like stock's Filter actor,
  which ignores Cancel and never reverts or clears. Press `<Esc>` again with the
  popup closed to clear the tree query.
- `<Esc>` after the popup has closed clears an active tree filter and restores
  the full injected hierarchy. When no tree filter is active (and outside tree
  mode) it falls through to Yazi's stock `escape` cascade, and `f` falls through
  to the stock `filter --smart` action.

Native selection still rejects ancestor/descendant pairs by design; filtering
changes which rows are visible but does not add plugin-owned selection.

#### Native filter hand-off

A native filter that is active when tree mode starts is read before the first
injection, cleared from Yazi's Entries, and handled according to `filter_mode`:

| `filter_mode` | on entering tree mode | on leaving tree mode |
| ------------- | --------------------- | -------------------- |
| `adopt` (default) | re-applied as the hierarchy-aware tree query | the current tree query is handed back to native filtering |
| `suspend` | saved and not applied, so the full tree shows | the saved pre-tree query is restored |
| `clear` | discarded permanently | nothing is restored |

Set it in `~/.config/yazi/init.lua`:

```lua
require("tree"):setup({ filter_mode = "suspend" }) -- "adopt" (default) | "suspend" | "clear"
```

`adopt` keeps a single hierarchy-aware filtering pass and is the default.
Yazi exposes only a filter's raw query string to plugins, not its case mode or
regex, so a restored query always uses smart case (matching the stock `f` /
`filter --smart` binding), and `adopt` interprets the query with the plugin's
literal basename matcher rather than Yazi's regex `Normalizer`. `suspend` and
`clear` never re-interpret the query, so the original native semantics survive
the restored case, at the cost of the filter's effect (and indicator) being
absent while the tree is expanded.

The native filter stays cleared for the entire injected-tree lifetime so it can
never filter injected rows or orphan a child from its hidden parent. The
hierarchy-aware tree query is saved per tab and per root alongside the expansion
set and restored when that root is revisited, so a query is never applied to a
different folder. A `cd` or reroot still discards `suspend`'s pre-tree native
query without restoring it, because that query belongs to the folder that owned
it.

#### Header indication

While the tree query is non-empty it is shown beside the cwd as
`(filter: <query>)`, using the stock header text, style, and placement. The
plugin wraps `Header.flags` once during `setup()` and delegates unchanged
whenever tree mode is off or no tree query is active, so Yazi's native indicator
still appears normally outside tree mode and tree mode never shows a duplicate
indicator.

### Rendering styles

Choose the prefix style in `~/.config/yazi/init.lua`:

```lua
require("tree"):setup({ style = "lines" })
```

| `style` | rendering |
| ------- | --------- |
| `lines` (default) | compact ancestor/branch connectors (` ├─`, ` └─`, ` │ `) |
| `indent` | equal-width spaces with no visible lines |

Root rows stay flush-left in both styles; each injected depth adds one
three-cell indent step, so a depth-1 icon sits in the same column whether the
prefix is a connector or a plain indent. `indent` keeps that depth spacing but
draws no lines.

Optional `glyphs` overrides replace individual connectors. Each glyph may be
any width, but all four must share one width or the columns drift apart; an
inconsistent or non-string set is ignored and the defaults are used. Missing
keys fall back to the defaults, and the old wider forms still work as overrides:

```lua
require("tree"):setup({
	style = "lines",
	glyphs = { branch = " ├─", last = " └─", vertical = " │ ", space = "   " },
})
```

The chosen style and glyphs are logged once per enable, next to the other
`[tree-dbg]` diagnostics.

Expanded directories keep the theme's hovered (open-folder) icon even while one
of their descendants is hovered, by asking the icon matcher for the hovered
variant on that parent row only. The row's real hover state and styling are
unchanged; a directory matched by a more specific theme rule (for example a
`dirs` name entry, link, or orphan rule) keeps its own icon.

### Per-launch startup

`setup()` accepts an optional `startup` table to start a mode before the first
frame, with no visible activation flicker:

```lua
require("tree"):setup({
	startup = { tree = true, preview = false },
})
```

`startup.tree` defaults to `false` and `startup.preview` defaults to `true`, so
omitting the `startup` table leaves Yazi's ordinary initial layout untouched.
The startup values also seed every tab the plugin first observes (for example the
boot tab and any tab created before the plugin has seen a `tab` event), while
tabs created afterwards inherit the creating tab's modes.

To launch the embedded tree mode only for specific invocations, gate it on an
environment variable (for example, an embedded Neovim terminal) so ordinary
launches keep their defaults:

```lua
local embedded_tree = os.getenv("YAZI_TREE") == "1"

require("tree"):setup({
	startup = { tree = embedded_tree, preview = not embedded_tree },
})
```

Then launch that terminal with:

```sh
YAZI_TREE=1 yazi
```

A plain `yazi` launch takes the other branch and keeps the normal configured
layout.

Yazi runs `init.lua` before its bootstrap reflow and first paint, so `setup()`
captures the configured base ratio, installs the tree renderer, and assigns
`rt.mgr.ratio` synchronously. The first painted frame is already tree-shaped and
preview-free, which is why the environment-gated setup avoids the flicker of
activating the mode after startup. Sort pinning is deferred until the first
expansion, so a tree-mode launch with nothing expanded does not disturb your
sort configuration. The runtime `toggle` and `preview` actions still work
normally afterwards.

## Limitations

- **Internal API.** Expansion injects real `fs::File` entries through the
  undocumented `fs.op("part"/"done")` plus `update_files` path. This is
  version-sensitive and may break in a future Yazi release.
- **Symlinked directories are never expanded.** A symlink to a directory is
  shown as a directory and can be entered with `Enter`/`L`, but `l` refuses to
  descend into it (logged at debug level) so a self-referential link cannot
  recurse forever. There is no follow mode and no inode-based cycle detection.
- **Uncapped, uncached reads.** Each rebuild asynchronously re-reads the root and
  every reachable expanded directory with no per-directory entry limit and no
  children cache, so a rebuild's I/O is proportional to the total entries of the
  expanded directories, not just the visible window.
- **External changes below the root are polled, not watched.** Yazi's watcher
  only covers the current, parent, and hovered folders, non-recursively, and
  watcher ops for a nested trail never touch the injected rows. Instead the
  plugin runs its own bounded poll (see *External changes (bounded polling)*):
  once per second it reads unfollowed metadata for the active tab's expanded
  directories and coalesces a real change into one guarded rebuild. Scope is
  strictly the active tab's expanded directories, so collapsed subtrees and
  saved roots of inactive tabs are never observed, and detection is delayed by
  up to roughly one interval plus a rebuild. An expanded directory renamed
  within the reachable set is remapped by its `(dev, btime)` identity and keeps
  its expansion; an unmatched, ambiguous, cross-filesystem, or out-of-tree move
  is pruned so an old path cannot auto-expand again. Identity is `(dev, btime)`
  only (Lua has no inode): filesystems with unavailable or coarse birth times and
  case-insensitive case-only renames may fall back to a plain collapse. The poll
  also stat-follows the one hovered injected nested file, so a content-only write
  to *that* file still refreshes the preview; direct child
  create/remove/rename normally changes the directory mtime, but an unexpanded
  or unhovered file-content write and coarse or unavailable directory timestamps
  may not be seen, in which case collapse (`h`) and re-expand (`l`) the
  directory. The plugin deliberately avoids Yazi's undocumented `watch`/`load`
  internals. Create, rename, copy/move, and trash/permanent-delete completed
  through the plugin or stock remove still rebuild explicitly, and
  `duplicate`/`move` events refresh affected branches.
- **Target-aware link/hardlink is stock-only.** Yazi 26.9.1 exposes no Lua task
  kind or `fs` call for symlinks/hardlinks, so target-aware `link`/`hardlink`
  cannot be reproduced and those actions still use the current directory.
- **Cut-paste selection clearing is coarser than stock.** Lua can only clear the
  whole active selection (`escape --select`), not just the moved URLs, so a cut
  paste that had an active selection clears all of it.
- **Filter matching is literal, not regex.** The query is matched as a smart-case
  basename substring, so Yazi's regex `Normalizer` syntax and match highlighting
  do not apply.
- **Filter case mode is not recoverable.** Yazi exposes only the raw query
  string to Lua, so a restored `adopt` or `suspend` query always uses smart case;
  a native sensitive/insensitive choice is not preserved.
- **The header indicator patches an internal method.** `(filter: query)` is
  added by wrapping the preset `Header:flags`, which is version-sensitive and may
  need updating on a future Yazi release.
- **Inactive-tab layout is applied on activation.** Yazi exposes a single global
  `rt.mgr.ratio`, so a tab's tree/preview layout is only observable once it is
  activated; the plugin re-applies the incoming tab's effective ratio on every
  switch. The canonical base ratio is refreshed while the active tab is idle, so
  an external ratio edit made while a non-idle tab is active is picked up on the
  next idle activation rather than immediately.
- **Interactive refresh reloads drop injected rows;** after an explicit refresh,
  collapse (`h`) and re-expand (`l`) the affected directory. Changing the
  working directory restores that root's saved expansion set automatically
  (asynchronously when Yazi evicted its cached Folder), and renames, bulk
  renames, removals, and hidden toggles are handled automatically. External
  mutations inside a saved root while it is not active are not observed by the
  plugin, so a saved key for a path deleted behind its back can remain until you
  return and collapse it; a directory later recreated at the same URL can then
  resurrect that stale expansion, matching the existing stale-key caveat for
  renames.

Compatible with Yazi 26.9.1. As with all Yazi plugins, compatibility is only
guaranteed with the latest Yazi release.

## Installation

```sh
ya pkg add jadonwb/tree
```

## Usage

Set up the plugin in your `~/.config/yazi/init.lua`:

```lua
require("tree"):setup() -- style defaults to "lines", filter_mode to "adopt"
```

Then bind the navigation and toggles in `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on = "h"
run = "plugin tree left"
desc = "Tree: collapse directory or leave"

[[mgr.prepend_keymap]]
on = "l"
run = "plugin tree right"
desc = "Tree: expand directory or enter"

[[mgr.prepend_keymap]]
on = "H"
run = "plugin tree root_up"
desc = "Tree: reroot to parent directory or stock back"

[[mgr.prepend_keymap]]
on = "L"
run = "plugin tree root_down"
desc = "Tree: reroot into directory or reveal file"

[[mgr.prepend_keymap]]
on = "a"
run = "plugin tree create"
desc = "Tree: create at hovered level or stock create"

[[mgr.prepend_keymap]]
on = "p"
run = "plugin tree paste"
desc = "Tree: paste into hovered level or stock paste"

[[mgr.prepend_keymap]]
on = "P"
run = "plugin tree -- paste --force"
desc = "Tree: force paste into hovered level or stock force paste"

[[mgr.prepend_keymap]]
on = "<Enter>"
run = "plugin tree open"
desc = "Tree: open file or enter directory"

[[mgr.prepend_keymap]]
on = "f"
run = "plugin tree filter"
desc = "Tree: filter hierarchy or stock filter"

[[mgr.prepend_keymap]]
on = "<Esc>"
run = "plugin tree escape"
desc = "Tree: clear filter or escape"

[[mgr.prepend_keymap]]
on = "<C-[>"
run = "plugin tree escape"
desc = "Tree: clear filter or escape"

[[mgr.prepend_keymap]]
on = "r"
run = "plugin tree rename"
desc = "Tree: rename nested entry or stock rename"

[[mgr.prepend_keymap]]
on = ["t", "v"]
run = "plugin tree toggle"
desc = "Toggle tree view"

[[mgr.prepend_keymap]]
on = ["t", "p"]
run = "plugin tree preview"
desc = "Toggle preview pane"
```

Outside a tree-mode tab the `h`, `l`, `H`, `L`, `<Enter>`, `a`, `p`, and `P`
bindings re-emit Yazi's stock `leave`, `enter`, `back`, `forward`, `open`,
`create`, and `paste`/`paste --force` actions, and `f`/`<Esc>` re-emit the stock
`filter` and `escape` actions, so normal navigation, creation, paste, and
filtering are unchanged. The `r` binding re-emits stock rename with
`cursor = "before_ext"` outside tree mode, on root-level rows, and with an
active multi-selection, so ordinary renames and bulk renames keep stock caret
placement and behavior. When tree mode is on but no tree filter is active,
`<Esc>` also falls through to the stock escape cascade. Mode routing is
per-tab, so these fallbacks apply based on the active tab's own tree flag.

The force-paste binding uses the `plugin <name> -- <args>` form because Yazi's
`--` separator is what keeps `--force` inside the plugin's own argument list
(the same form the preset `plugin sudo -- paste --force` bindings use). A plain
`plugin tree paste --force` would parse `--force` as an argument of the outer
`plugin` action and drop it before the plugin sees it.

Note that the keybindings above are just examples, please tune them up as needed
to ensure they don't conflict with your other actions/plugins.

## Diagnostics

To see the plugin's debug output, start Yazi with `YAZI_LOG` set to `debug`:

```sh
YAZI_LOG=debug ya
```

Rebuilds log a bounded pair of lines: `rebuild gen=... expanded=... filter=...
focus=...` when a rebuild starts, and `rebuild done gen=... dirs=... rows=...
expanded=... ms=...` when it finishes, where `dirs` is the number of directories
actually read and `rows` is the number of injected rows. A rebuild that is
discarded as stale returns before emitting and does not log the completion
line.

## Testing

The integration harness in `tests/` drives the plugin through a private tmux
server and an isolated Yazi config, so it never touches your real config,
fixtures, or tmux sessions. It requires Bash, `yazi` 26.9.1, and `tmux`.

```sh
./tests/integration.sh                 # run every scenario
./tests/integration.sh startup filter  # run only the named scenarios
./tests/integration.sh --list          # list available scenario names
./tests/integration.sh --jobs 4        # run selected scenarios 4 at a time
```

`--jobs N` runs each selected scenario in its own child process, at most `N` at
a time, collecting per-job logs and exit codes under the temporary root and
replaying failures in scenario order. It requires Bash 5.1 or newer (for
`wait -n -p`); serial runs work on older Bash.

Environment variables:

- `TREE_IT_ROOT` — base directory for temporary state (default
  `/tmp/opencode/tree-it`).
- `TREE_IT_KEEP=1` — keep the temporary root even on success, for debugging.

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE)
file.
