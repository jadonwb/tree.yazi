# tree.yazi

An early experimental Yazi plugin exploring a tree-style layout and an
independent preview-pane toggle.

**Status: layout spike only.** The plugin currently does not render a file tree,
list entries, or track depth — those behaviors are unimplemented. What it does
today is reshape the three-pane horizontal layout via Yazi's ratio mechanism:

- **Tree mode** (`toggle`) collapses the parent column into the current pane.
- **Preview mode** (`preview`) toggles the preview pane; turning it off gives the
  preview space to the current pane.

The two toggles are independent and compose, so all four combinations restore
predictably:

| tree | preview | effective ratio |
| ---- | ------- | --------------- |
| off  | on      | the configured ratio, unmodified |
| on   | on      | parent collapsed, preview keeps its share |
| off  | off     | preview space in current |
| on   | off     | parent and preview space in current |

The plugin captures the base ratio from `rt.mgr.ratio` while both toggles are
off, recomposes the effective ratio from that base on every toggle, and applies
it with `rt.mgr.ratio = ...` plus `ya.emit("app:resize", {})`. It no longer
patches `Tab.layout` or `Tab._chunks`.

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

Then bind the toggles in `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on = ["t", "v"]
run = "plugin tree toggle"
desc = "Toggle tree view"

[[mgr.prepend_keymap]]
on = ["t", "p"]
run = "plugin tree preview"
desc = "Toggle preview pane"
```

Note that the keybindings above are just examples, please tune them up as needed
to ensure they don't conflict with your other actions/plugins.

## Diagnostics

To see the plugin's debug output, start Yazi with `YAZI_LOG` set to `debug`:

```sh
YAZI_LOG=debug ya
```

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE)
file.
