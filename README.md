# tree.yazi

An early experimental Yazi plugin exploring a tree-style layout.

**Status: layout spike only.** The plugin currently does one thing: it toggles
the parent column to free up horizontal space for the current and preview panes.
It does **not** yet render a file tree, list entries, or track depth — those
behaviors are unimplemented.

Compatible with Yazi 26.9.1. As with all Yazi plugins, compatibility is only
guaranteed with the latest Yazi release.

## Installation

```sh
ya pkg add jadonwb/tree
```

## Usage

Set up the plugin in your `~/.config/yazi/init.lua`:

```lua
require("tree"):setup()
```

Then bind the toggle in `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on = ["t", "v"]
run = "plugin tree toggle"
desc = "Toggle tree view"
```

Note that the keybinding above is just an example, please tune it up as needed
to ensure it doesn't conflict with your other actions/plugins.

## Diagnostics

To see the plugin's debug output, start Yazi with `YAZI_LOG` set to `debug`:

```sh
YAZI_LOG=debug ya
```

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE)
file.
