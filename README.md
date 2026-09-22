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
- **Preview mode** (`preview`) toggles the preview pane; turning it off gives
  the preview space to the current pane.

Both toggles are tab-local, creating a new tab in tree mode carries it over.

The plugin provides (`plugin tree tab_create`): in a tree tab it emits the tree
cwd as an explicit `tab_create` target, so a new tab opens at the same tree root
even when a nested injected descendant is hovered; outside tree mode the action
re-emits stock `tab_create --current` unchanged.

The two toggles are independent and compose, so all four combinations restore
predictably:

| tree | preview | effective ratio                           |
| ---- | ------- | ----------------------------------------- |
| off  | on      | the configured ratio, unmodified          |
| on   | on      | parent collapsed, preview keeps its share |
| off  | off     | preview space in current                  |
| on   | off     | parent and preview space in current       |

The plugin captures one canonical base ratio from `rt.mgr.ratio` while the
active tab is idle (tree off, preview on), recomposes each tab's effective ratio
from that base and its own modes, and applies it with `rt.mgr.ratio = ...` plus
`ya.emit("app:resize", {})`. Yazi keeps a single global ratio, so an inactive
tab's layout is only observable once it becomes active; the plugin does not
patch `Tab.layout` or `Tab._chunks`.

## Limitations

- **Symlinked directories are never expanded.** A symlink to a directory is
  shown as a directory and can be entered with `Enter`/`L`, but `l` refuses to
  descend into it (logged at debug level) so a self-referential link cannot
  recurse forever. There is no follow mode and no inode-based cycle detection.
- **Unlimited, uncached reads.** Each rebuild asynchronously re-reads the root
  and every reachable expanded directory without passing `fs.read_dir`'s
  `options.limit` and with no children cache, so a rebuild's I/O is proportional
  to the total entries of the expanded directories, not just the visible window.
- **External changes below the root are polled, not watched.** Yazi's watcher
  covers only the current, parent, and hovered folders, non-recursively, and
  never adds or removes the injected descendants; a watched hovered nested
  directory's own row metadata can still be refreshed by a watcher op. The
  plugin polls once per second instead: it reads unfollowed metadata for the
  active tab's expanded directories outside any hidden subtree while hidden is
  off, coalescing a real change into one guarded rebuild, and detection is
  delayed by up to roughly one interval plus a rebuild. An expanded directory
  renamed within the reachable set is remapped by its `(dev, btime)` identity
  and keeps its expansion; an unmatched, ambiguous, or out-of-tree move is
  pruned. The poll also stat-follows the one hovered injected nested file, so a
  content-only write to _that_ file still refreshes the preview; other
  content-only writes may not be seen, in which case collapse (`h`) and
  re-expand (`l`) the directory. A native Full reload is repaired through the
  `load` event rather than polled, and create, rename, copy/move, and
  trash/permanent-delete completed through the plugin or stock remove still
  rebuild explicitly, with `duplicate`/`move` events refreshing affected
  branches.
- **Link/hardlink are not routed.** Stock `link`/`hardlink` always create links
  in the current directory (their forms carry no target), and Lua exposes no
  native task kind or `fs` call for them, so in tree mode they target the tab
  cwd rather than the hovered level. A plugin could shell out to `ln`; tree.yazi
  does not.
- **Filter matching is literal, not regex.** The tree filter matches a
  smart-case basename substring. Yazi's native filter compiles the query as a
  Rust regex after a Unicode `Normalizer` rewrite, but a Lua plugin receives
  only the raw query string (`Files.filter` is an opaque userdata whose sole
  member is `__tostring`, with no `new`/`matches`/`highlighted` binding), so the
  plugin cannot call that engine.
- **Filter case mode is not recoverable.** Yazi exposes only the raw query
  string to Lua, so a restored `adopt` or `suspend` query always uses smart
  case; a native sensitive/insensitive choice is not preserved.
- **The header indicator is added by wrapping `Header:flags`.**
  `(filter: query)` comes from wrapping the preset `Header:flags`, which
  delegates unchanged whenever tree mode is off or no tree query is active, so
  the native indicator still appears outside tree mode and tree mode never shows
  a duplicate.
- **Interactive refresh reloads keep the injected rows and restore the hovered
  row.** A native Full reload (an explicit refresh, or window focus after an
  external save marks the folder stale) replaces the folder's entries, but when
  expansions are recorded and the reloaded folder has no descendants the plugin
  re-emits the previous injected rows through the local `load` event, re-arrows
  to the row hovered before the reload, and rebuilds to refresh metadata. The
  replay usually lands before the next paint, but a render scheduled in the same
  dispatch can still show the flat depth-0 listing for one frame (see the
  Full-reload-flash limitation below), and the cursor then stays put. If the
  reload lands while a rebuild is already in flight the repair is skipped, so
  collapse (`h`) and re-expand (`l`) as a fallback. Changing the working
  directory restores that root's saved expansion set automatically
  (asynchronously when Yazi evicted its cached Folder), and renames, bulk
  renames, removals, and hidden toggles are handled automatically. External
  mutations inside a saved root while it is not active are not observed
  ("external" meaning not performed through this Yazi instance; a
  rename/trash/delete/move performed in this Yazi prunes every tab's saved
  state), so a saved key for a path deleted behind its back can remain until you
  return and collapse it; a directory later recreated at the same URL can then
  resurrect that stale expansion.
- **A native Full reload can flash one frame.** A native full reload — window
  focus after an external save within the tree root, or an explicit `refresh` —
  may paint the flat `sort=none` cwd for one frame before the local `load` event
  replays the recorded rows; expansions and the hovered row are preserved. The
  frame cannot be masked: a Full load has no variant-aware preflight — the
  generic relay preflight sees the op, but Lua cannot identify it as Full — and
  the Lua `FilesOp` exposes no variant, so Lua cannot substitute one.
- **Custom sort has no equivalent.** While tree mode pins the tab's folder sort
  to `none` the plugin emulates the captured sort per directory; `by = "custom"`
  falls back to alphabetical because native ranks key by basename on a single
  folder, so injected descendants from different subdirectories would collide. A
  `size` sort compares the entry's own `stat.len`, not a recursive directory
  size. The `extension` key is also not faithful: the plugin splits on the last
  dot, so a dotfile with no other dot (`.bashrc`) gets extension `bashrc`, while
  Yazi returns no extension.
- **Collisions are handled differently by `a` and `A`.** Target-aware create
  overwrites an existing regular file in place with `fs.write` (and unlinks an
  existing symlink, never its target), while bulk create binds file entries to
  `create_new` (`O_CREAT|O_EXCL`), so an existing _file_ is reported as a
  failure and is never overwritten, while an existing _directory_ entry is
  silently accepted (`create_dir_all` succeeds and is counted as created).

## Architecture

While tree mode is on, the plugin overrides `Current.redraw` and reproduces the
stock row renderer over the pane's already-loaded folder window, one
`Entity:new(file):redraw()` per row, so hover, selection markers, linemode text,
and drag/drop rendering stay native; root rows render flush-left and only
injected descendants carry branch prefixes, and a non-tree or empty directory
falls back to the unmodified stock renderer. Injected children must stay
directly beneath their parent, and Yazi re-sorts a folder on every update, so
tree mode pins the tab's folder sort to `none` and the plugin emulates the
captured sort per directory, restoring the tab's own sort on exit. Expansion is
lazy: only directories reachable through an expanded ancestor are read, each
with asynchronous `fs.read_dir`, so a collapsed subtree costs no I/O.

`main.lua` is the state owner and orchestrator: it holds `M` (the expansion
sets, row metadata, generation counters, per-tab records, and the poller
handle), registers the event subscriptions, and defines the synchronous bridges
that let the async passes touch that state. The sibling modules are stateless
helpers reached through those bridges and never hold `M`: `roots.lua` does URL
remap, prune, and saved-root reconciliation; `layout.lua` owns the canonical
base ratio, the effective-ratio composition, the single write of `rt.mgr.ratio`,
and the per-tab sort pin/restore handoff; `rows.lua` holds the cursor,
cwd-relative, and row-rehydration helpers over the active `cx` folder;
`events.lua` reconciles externally-initiated mutation events (`rename`/
`bulk-rename`, remove/transfer); `operations.lua` performs the plugin-initiated
writes (target-aware create and nested rename); `rebuild.lua` runs the
asynchronous rebuild that reads the expanded subtrees, flattens and filters them
in the captured root order, publishes row metadata, and injects the resulting
rows; `render.lua` holds the row-rendering primitives, connector configuration,
private render style, and resolved glyph state; `flatten.lua` is the pure
directory-first ordering, the smart-case literal matching, the Lua port of
Yazi's natural sort, and a separate deterministic FNV-1a `(seed, url)`
comparator that emulates random order (Yazi's own `SortBy::Random` draws from a
fresh `SmallRng` per sort); `translit.lua` is the lazily loaded port of Yazi's
translit table, used only for natural sort with `translit` true; and
`poller.lua` is the setup-installed external-change loop whose bounded per-tick
metadata scan drives one coalesced, generation-guarded rebuild through the apply
bridge.

### Module contracts and state ownership

`main.lua` owns the live state for the active tab: `M.expanded`, `M.rows`,
`M.root_order`, and `M.filter_query`. Everything that must survive a tab switch
lives on `M.tabs[tab_id]` — the tab's tree/preview modes, its sort and
native-filter handoff, its last-seen root, its frozen `random_seed`, and its
per-root `roots[root] = { expanded, order, filter }` map. Entering a tab loads
its saved state and leaving one saves it; Yazi restores a whole cached Folder on
`cd`, and `update_files` always targets the active tab, so the plugin saves the
outgoing tab itself and reconciles the incoming one against its saved set.

Sibling modules never hold `M`. Each reaches live state through a bound accessor
installed once from `M:setup`: `roots.bind(accessors)`, `layout.bind`,
`events.bind(ctl)`, `poller.start(token, ctx)`, and `render.install(caps)`;
`rows.lua` reads `cx` directly and returns values, and `render.lua`'s private
style and resolved glyphs are read back only through `style()`/`glyphs()`. The
bound accessors expose the live tables (not copies), so the in-place
`prune`/`remap` helpers mutate the live expansion set, and `events.lua` performs
no filesystem writes — the plugin's own writes live in `operations.lua`.

Async passes are resolved lazily: each is `require`d inside its own existing
`ya.async` callback, or bound once in `setup()` from the async `init.lua`
context, so no module is loaded on a synchronous path that cannot require it.

A completed rebuild injects one `FilesOp` sequence — `part` (empty) + `part`
(the rows) + `done` — under a ticket taken from `M.seq`, which starts above the
folder loader's own tickets. Before injection the rebuild stashes a plain-table
replay snapshot (`inject_snapshot`/`inject_cwd`/`inject_tab`/`has_descendants`);
the synchronous `on_load` repair replays it (rebuilding fresh `File` userdata,
since `Stat`/`File` userdata cannot cross the sync bridge — a `Path` could, but
the stash stores strings) only when it recorded `depth > 0` rows. Every `set_*`
bridge and `finish_rebuild` is gated on generation and tab, so a stale or
cross-tab callback cannot reset a folder.

`M.pending_focus` is either a URL string or an ordered candidate list; `M:focus`
resolves it against the rebuilt files, skipping a fallback hidden by the active
tree filter. The plugin owns `M.filter_query` and keeps Yazi's native `Entries`
filter cleared for the whole injected-tree lifetime, with the raw query parked
per tab in `t.suspended_filter`. Poll sessions carry an identity
(`poll_token`/`M.poller_token`): a newer session makes an older loop drop its
tick, and abort/finish clears the snapshot.

### Native fd/rg search views

A native `fd://`/`rg://` provider View is never a tree View: `active_tree()`
returns false for it regardless of the tab's recorded mode, so provider rows,
stock rendering, stock actions, and the stock rebuild all delegate untouched.
The mode is still recorded on the tab, and sort pin/restore is deferred to the
next physical `cd`; stock EscapeView (which cds back to the physical root) is
never intercepted, and the poll loop stops for the provider View and starts
again on a physical tree.

## Interoperability

Yazi has no generic action-interception bus for `paste`, `create`, `rename`,
`link`, or `hardlink`, so a plugin cannot preflight, redirect, or cancel them. A
keybinding or another plugin that emits a stock action therefore bypasses the
plugin's tree routing: paste/create/bulk_create/link/hardlink resolve against
the tab cwd, while stock rename acts on the hovered row and reveals its result
(which can reroot the view) — `ya.emit("paste", ...)`, for example, pastes into
the tab cwd, not into a hovered tree level. Yazi does have a preflight bus, but
only for a fixed, non-generic action set (the plugin itself uses `key-sort`/
`key-hidden`); it has no create/paste/rename/link/hardlink variants.

Tree.yazi does not attempt such interception. It reconciles mutations started
elsewhere only through the post-hoc `rename`, `bulk-rename`, `trash`, `delete`,
`duplicate`, and `move` DDS events, which remap (rename/bulk-rename), prune
(trash/delete/move), or merely refresh affected branches (duplicate); actions
with no corresponding event are simply not routed into the tree. Cross-plugin
calls can require the plugin module, use a DDS custom kind, or emit the `plugin`
action.

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
on = "A"
run = "plugin tree bulk_create"
desc = "Tree: bulk create at hovered level or stock bulk create"

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

[[mgr.prepend_keymap]]
on = ["t", "t"]
run = "plugin tree tab_create"
desc = "Tree: new tab in tree cwd or stock smart tab"
```

Outside a tree-mode tab the `h`, `l`, `H`, `L`, `<Enter>`, `a`, `A`, `p`, and
`P` bindings re-emit Yazi's stock `leave`, `enter`, `back`, `forward`, `open`,
`create`, `bulk_create`, and `paste`/`paste --force` actions, and `f`/`<Esc>`
re-emit the stock `filter` and `escape` actions, so normal navigation, creation,
bulk creation, paste, and filtering are unchanged. The `r` binding re-emits
stock rename with `cursor = "before_ext"` outside tree mode, on root-level rows,
and with an active multi-selection, so ordinary renames and bulk renames keep
stock caret placement and behavior. When tree mode is on but no tree filter is
active, `<Esc>` also falls through to the stock escape cascade. The `t t`
binding opens a new tab at the tree cwd in tree mode (ignoring the hover) and
otherwise re-emits stock `tab_create --current`, so ordinary smart-tab behavior
is unchanged. Mode routing is per-tab, so these fallbacks apply based on the
active tab's own tree flag.

The force-paste binding uses the `plugin <name> -- <args>` form because Yazi's
`--` separator is what keeps `--force` inside the plugin's own argument list. A
plain `plugin tree paste --force` would parse `--force` as an argument of the
outer `plugin` action and drop it before the plugin sees it.

Note that the keybindings above are just examples, please tune them up as needed
to ensure they don't conflict with your other actions/plugins.

## Configuration

Call `setup()` once in your `~/.config/yazi/init.lua`. It accepts a single table
with four optional keys; every key is independent, and omitting the table (or a
key) keeps the documented default. This block is the single source of truth for
every `setup()` option.

```lua
require("tree"):setup({
	-- Prefix rendering for injected rows.
	--   "lines"  (default) compact ancestor/branch connectors (` ├─`, ` └─`, `│`)
	--   "indent" equal-width spaces with no visible lines
	style = "lines",

	-- Connector glyphs. Each may be any non-empty string, but all four must
	-- share one display width or the whole set is ignored and the defaults are
	-- used. Missing keys fall back to the defaults below.
	glyphs = {
		branch = " ├─",
		last = " └─",
		vertical = " │ ",
		space = "   ",
	},

	-- What to do with a native filter that is active when tree mode starts.
	--   "adopt"   (default) re-apply it as the hierarchy-aware tree query
	--   "suspend" save it and restore it on leaving tree mode
	--   "clear"   discard it permanently
	filter_mode = "adopt",

	-- State seeded into tabs the plugin first observes without a creating tab
	-- (boot tabs and tabs first seen via `cd`); tabs created by
	-- `plugin tree tab_create` inherit the creator tab's tree/preview modes.
	--   tree    false (default) tree mode off
	--   preview true  (default) preview pane on
	startup = { tree = false, preview = true },
})
```

## Diagnostics

To see the plugin's debug output, start Yazi with `YAZI_LOG` set to `debug`:

```sh
YAZI_LOG=debug ya
```

Rebuilds log a bounded pair of lines:
`rebuild gen=... expanded=... filter=... focus=...` when a rebuild starts, and
`rebuild done gen=... dirs=... rows=... expanded=... ms=...` when it finishes,
where `dirs` is the number of directories actually read and `rows` is the number
of injected rows. A rebuild that is discarded as stale returns before emitting
and does not log the completion line.

## Testing

The integration harness in `tests/` drives the plugin through a private tmux
server and an isolated Yazi config, so it never touches your real config,
fixtures, or tmux sessions. It requires Bash, Yazi `26.9.1` at revision
`0ea4c5d`, and `tmux`.

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
