# tree-vfs

Standalone experimental replacement for the tree workflow, implemented as a
Yazi View provider. It is intentionally installed beside (not over) the
production `tree.yazi` plugin. Target Yazi build: 26.9.1 @ `0ea4c5d`.

## Try it temporarily

Keep the normal `tree.yazi` installation and configuration intact. To switch
manually, comment out the current `require("tree"):setup({...})` call in the
user `init.lua` and use:

```lua
local embedded_tree = os.getenv("YAZI_TREE") == "1"
require("tree-vfs"):setup({
  style = "indent",
  startup = { tree = embedded_tree, preview = not embedded_tree },
  filter_mode = "adopt",
})
```

In the corresponding tree keymap block, preserve each existing key and action
but change the plugin prefix from `plugin tree` to `plugin tree-vfs`. In
particular, retain the `--` separator and flags in
`plugin tree-vfs -- create --dir` and `plugin tree-vfs -- paste --force`.
Switch both init and keymap blocks together; Yazi selects plugins by directory
name, so the `tree` keymap cannot invoke `tree-vfs`. Switching back means
restoring the original tree setup and `plugin tree` block. This project does
not edit the live Yazi configuration or provide an automatic backend switch.

The plugin dynamically registers the `tree.default` View during setup; no
`vfs.toml` edit is needed. It owns provider-specific read/refresh state while
delegating file operations to Yazi's filesystem engine and task scheduler.

## Tests

Run the provider-specific gate from this checkout:

```sh
./tests/integration.sh --list
./tests/integration.sh --jobs 4 modes_toggle_preview navigation_deep filter_live tabs_view_clone create_nested paste_nested rename_nested remove_nested external_hover_preview
```

The harness gives each scenario its own temporary config, fixture, XDG state,
runtime directory and unique tmux server. It requires Yazi 26.9.1 @ `0ea4c5d`.
Use `TREE_IT_ROOT=/path/to/tmp` to choose the external artifact parent and
`TREE_IT_KEEP=1` to retain successful-run artifacts. Failed scenarios always
retain their artifacts for diagnosis.

## Coverage and limitations

The selectable gate covers tree/preview pane ratios, h/l/H/L and linked-folder
guarding, filtering, independent state for a newly created tab entering its own
View, nested create/paste/rename, mutation refresh, and external-change polling
without idle ReadDir churn. `tabs_view_clone` tests explicit entry into a
provider View in the new physical tab; it does **not** claim that
`tab_create --current` clones a View URL. The delete scenario verifies the
provider refresh reconciliation event but does not assert deterministic
physical deletion, because stock delete confirmation/selection was unreliable
in the isolated UI fixture.

This is not full feature parity with the production plugin. Complex filter and
hidden-file combinations, all native tab lifecycle cases, robust bulk-create
dialog parity, broad trash/delete semantics, and the production suite's 91
scenarios remain unported or unverified. Only the provider-specific scenarios
listed above should be considered coverage; no general tree.yazi equivalence is
claimed.
