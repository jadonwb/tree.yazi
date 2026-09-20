-- Disposable tree-vfs View provider prototype (b8973fb contract).
-- Dual role, like the in-tree rg.lua: functional plugin (M:entry) + VFS
-- provider (M:provide). Every provider job runs in a fresh Lua state, so
-- expansion state is read from an external file on every ReadDir.
--
-- Contract notes learned from b8973fb source:
--   * ReadDir is a CoIter: return ya.co(fn) yielding { file, cha }.
--   * A View URL built with the table constructor has Loc urn=0, i.e. an
--     empty `key()`; Entries::split_files drops empty-key rows. Entry URLs
--     must therefore be produced by joining a relative path onto the folder
--     URL (the rg.lua shape), which yields a non-empty urn.
--   * Capabilities declares only file/read_dir/revalidate; every other op
--     falls back to the Local engine through Url::physical.
--
-- Increment 2 additions (prototype-only):
--   * `enter` records the view root in state/root and out/realcwd.txt.
--   * `paste`/`paste-force` compute a hovered-target-aware destination and
--     delegate the I/O to Yazi's native task scheduler using view URLs.
--   * `quit` is the plugin-contained "cd to physical then quit" workaround.
--   * Rename re-entry / state remap / post-op refresh live in config/init.lua.
local M = {}

local DOMAIN = "default"
local ROOT = "/home/jadon/.config/yazi/plugins/tree-vfs.yazi"
local STATE = ROOT .. "/state/expanded"
local ROOT_STATE = ROOT .. "/state/root"
local REALCWD = ROOT .. "/out/realcwd.txt"

local function read_state()
  local set, f = {}, io.open(STATE, "r")
  if f then
    for line in f:lines() do
      if line ~= "" then set[line] = true end
    end
    f:close()
  end
  return set
end

local function write_state(set)
  local f, err = io.open(STATE, "w")
  if not f then return nil, err end
  local keys = {}
  for k in pairs(set) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do f:write(k, "\n") end
  f:close()
  return true
end

local function write_file(path, data)
  local f, err = io.open(path, "w")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

-- Build a view portal URL: [1] is the real source URL; data carries state.
local function view_url(real, depth)
  return Url { Url(real), scheme = "tree", domain = DOMAIN, data = { depth = depth or 0 } }
end

-- Real metadata for an already-built view URL (entry or portal).
local function file_from_url(url)
  local f, err = fs.file(Url(url.physical)) -- async; real local metadata
  if not f then return nil, err end
  ya.dbg(string.format(
    "[tvfs] file %s len=%s dir=%s",
    tostring(url.physical),
    tostring(f.cha and f.cha.len),
    tostring(f.cha and f.cha.is_dir)
  ))
  return File { url = url, cha = f.cha, link_to = f.link_to }
end

local function walk(real, depth, expanded, out)
  local files, err = fs.read_dir(Url(real), { resolve = true })
  if not files then return out, err end
  table.sort(files, function(a, b)
    local ad, bd = a.cha and a.cha.is_dir, b.cha and b.cha.is_dir
    if ad ~= bd then return ad == true end
    return tostring(a.name) < tostring(b.name)
  end)
  for _, f in ipairs(files) do
    local child = real .. "/" .. tostring(f.name)
    out[#out + 1] = { real = child, depth = depth }
    if f.cha and f.cha.is_dir and expanded[child] then
      walk(child, depth + 1, expanded, out)
    end
  end
  return out
end

function M:provide(job)
  local op = job.op
  if op == "Capabilities" then
    return { file = true, read_dir = true, revalidate = true }
  elseif op == "ReadDir" then
    local folder = job.url                        -- view portal
    local root = tostring(folder.physical)        -- real cwd/root
    local flat = walk(root, 0, read_state(), {})
    local names = {}
    for i, e in ipairs(flat) do names[i] = e.real end
    ya.dbg("[tvfs] ReadDir " .. root .. " entries " .. #flat .. " :: " .. table.concat(names, " "))
    return ya.co(function()
      for _, e in ipairs(flat) do
        local rel = e.real:sub(#root + 2)
        local file, err = file_from_url(folder:join(rel))
        if not file then return nil, err end
        coroutine.yield({ file = file, cha = file.cha }) -- b8973fb DirEntry contract
      end
    end)
  elseif op == "File" then
    ya.dbg("[tvfs] File " .. tostring(job.url.physical))
    return file_from_url(job.url)
  elseif op == "Revalidate" then
    ya.dbg("[tvfs] Revalidate " .. tostring(job.file.url.physical))
    return file_from_url(job.file.url)            -- always a File => forces re-read on refresh
  end
  return false, Err("Unsupported tree-vfs operation: %s", op)
end

local snapshot = ya.sync(function()
  local cur = cx.active.current
  local h = cur.hovered
  return {
    cwd = tostring(cur.cwd.physical or cur.cwd),
    hovered = h and tostring(h.url.physical) or nil,
  }
end)

-- Yanked files + a target-aware paste destination. The destination is the
-- hovered directory, else the hovered file's parent, else the view portal.
local yank_snapshot = ya.sync(function()
  local items = {}
  for _, f in pairs(cx.yanked) do
    items[#items + 1] = { url = f.url, name = tostring(f.name) }
  end
  local h = cx.active.current.hovered
  local dest = cx.active.current.cwd
  if h then
    if h.cha and h.cha.is_dir then
      dest = h.url
    elseif h.url.parent then
      dest = h.url.parent
    end
  end
  return {
    cut = cx.yanked.is_cut,
    items = items,
    dest = dest,
    selected = #cx.active.selected,
  }
end)

local quit_snapshot = ya.sync(function()
  return {
    physical = tostring(cx.active.current.cwd.physical or cx.active.current.cwd),
  }
end)

function M:entry(job)
  local action = tostring(job.args[1])
  if action == "enter" then
    local cwd = snapshot().cwd
    write_file(ROOT_STATE, cwd)
    write_file(REALCWD, cwd)
    ya.dbg("[tvfs] enter " .. cwd)
    ya.emit("cd", { view_url(cwd, 0), raw = true })
  elseif action == "expand" or action == "collapse" then
    local s = snapshot()
    if not s.hovered then return end
    local set = read_state()
    if action == "expand" then
      set[s.hovered] = true
    else
      set[s.hovered] = nil
    end
    local ok, err = write_state(set)
    if not ok then return ya.dbg("[tvfs] state write failed " .. tostring(err)) end
    ya.dbg("[tvfs] " .. action .. " " .. s.hovered)
    ya.emit("refresh", {})
  elseif action == "refresh" then
    ya.dbg("[tvfs] refresh")
    ya.emit("refresh", {})
  elseif action == "paste" or action == "paste-force" then
    local s = yank_snapshot()
    local force = action == "paste-force"
    if #s.items == 0 then
      ya.dbg("[tvfs] paste no yanked items")
      return
    end
    ya.dbg(string.format(
      "[tvfs] paste cut=%s force=%s items=%d dest=%s",
      tostring(s.cut), tostring(force), #s.items, tostring(s.dest)
    ))
    for _, it in ipairs(s.items) do
      local to = s.dest:join(it.name)
      if s.cut then
        ya.task("move", { from = it.url, to = to, force = force }):spawn()
      else
        ya.task("copy", { from = it.url, to = to, force = force, follow = false }):spawn()
      end
    end
    if s.cut then
      ya.emit("unyank", {})
      if s.selected > 0 then ya.emit("escape", { select = true }) end
    end
  elseif action == "quit" then
    local s = quit_snapshot()
    ya.dbg("[tvfs] quit physical=" .. s.physical)
    ya.emit("cd", { Url(s.physical), raw = true })
    ya.emit("quit", {})
  end
end

return M
