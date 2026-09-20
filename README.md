# tree-vfs-prototype

Disposable, isolated experiment answering whether Yazi b8973fb's experimental
Lua **View** VFS provider can support a tree.yazi-style flattened hierarchy over
real local files.

It does **not** touch `~/.config/yazi`, the real `tree.yazi` plugin, or any
chezmoi repository. All config, fixtures, state, logs and runtime sockets live
below this directory.

## Isolation

| Var | Value |
| --- | --- |
| `YAZI_CONFIG_HOME` | `<root>/config` |
| `XDG_CACHE_HOME` | `<root>/xdg/cache` |
| `XDG_STATE_HOME` | `<root>/xdg/state` (log: `xdg/state/yazi/yazi.log`) |
| `XDG_RUNTIME_DIR` | `<root>/xdg/run` |
| `TMPDIR` | `<root>/xdg/tmp` |

No tmux, no background daemons. The PTY harness is `harness/drive.py` (Python
stdlib `pty`). Trash (`d`) is deliberately not exercised because it would write
to the real XDG trash; permanent delete (`D`) is used instead.

## Layout

```
config/vfs.toml                      [tree.default] kind="view" run="tree-vfs"
config/init.lua                      View/Url-source compatibility probe
config/keymap.toml                   t/l/h/R -> plugin tree-vfs actions
config/yazi.toml                     sort_by="none", safe `probe` opener
config/plugins/tree-vfs.yazi/main.lua  functional plugin + partial VFS provider
harness/drive.py                     stdlib PTY driver
tools/realcwd.sh                     option A: parse a view-URL cwd-file
build-fixtures.sh                    reset fixture/state/out (prototype root only)
check-compat.sh                      Gate 0
run.sh                               manual isolated launcher
test.sh                              automated PTY matrix
cleanup.sh                           kill leftover prototype yazi, drop sockets
logs/                                per-scenario .log/.raw + results.tsv
RESULTS.md                           findings
manual-checklist.md                  manual / out-of-scope items
```

## Usage

```sh
./build-fixtures.sh      # create fixture + empty state
./check-compat.sh        # Gate 0; exits 2 on unsupported build
./test.sh                # full matrix (gate + scenarios), writes logs/
./run.sh                 # manual interactive pane inspection
./cleanup.sh             # after manual runs
```

## Provider contract (b8973fb)

`provide(job)` receives PascalCase `job.op`; `ReadDir` is a CoIter and must
return `ya.co(function() coroutine.yield({ file = <File>, cha = <Cha> }) end)`.
Every provider job runs in a fresh Lua state, so expansion state is kept in
`state/expanded` (newline-separated absolute real paths) and re-read per job.
Only `file`, `read_dir` and `revalidate` are declared; all other operations fall
back to the Local engine through `Url::physical`.

--cwd-file workaround: out/realcwd.txt is written on every cd (option C); `Q`
runs the plugin quit override (option D); `tools/realcwd.sh` parses a view-URL
cwd-file (option A). The `key-quit` preflight (option B) is a documented NO-GO.

**Non-obvious requirement:** a View URL built with the table constructor
(`Url { Url(real), scheme="tree", domain=..., data=... }`) gets `Loc` `uri=0,
urn=0`, i.e. an **empty `key()`**. `Entries::split_files` drops every row whose
`key()` is empty, so such a folder renders as `No items` even though ReadDir
returns files. Entry URLs must be produced by joining a relative path onto the
folder URL (`folder:join(rel)`, the rg.lua shape), which yields a non-empty
`urn` and therefore a non-empty `key()`.
