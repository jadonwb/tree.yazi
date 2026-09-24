-- Experimental tree-vfs View provider for Yazi 26.9.1 @ 0ea4c5d.
-- Dual role, like the in-tree rg.lua: functional plugin (M:entry) + VFS
-- provider (M:provide). Provider jobs bridge to the main plugin state via
-- top-level ya.sync blocks.
--
-- Provider contract notes:
--   * ReadDir is a CoIter yielding bare File values with stat/lstat metadata.
--   * A View URL built with the table constructor has Loc urn=0, i.e. an
--     empty `key()`; Entries::split_files drops empty-key rows. Entry URLs
--     must therefore be produced by joining a relative path onto the folder
--     URL (the rg.lua shape), which yields a non-empty urn.
--   * Capabilities declares only file/read_dir/revalidate; every other op
--     falls back to the Local engine through Url::physical.
--
-- Increment 2 additions (prototype-only):
--   * `enter` records the view root in per-tab in-memory state.
--   * `paste`/`paste-force` compute a hovered-target-aware destination and
--     delegate the I/O to Yazi's native task scheduler using view URLs.
--   * `quit` is the plugin-contained "cd to physical then quit" workaround.
--   * Rename re-entry / state remap / post-op refresh live in config/init.lua.
local M = {}
local operations = require("tree-vfs.operations")
M.navigation = {}

local DOMAIN = "default"
local REALCWD = rt.path.runtime_dir .. "/tree-vfs-" .. tostring(ya.id("app")) .. ".cwd"
M.tabs, M.root = {}, nil
local configured = false
local options = { style = "lines", filter_mode = "adopt", startup = { tree = false, preview = true } }

local function tab_state(state, tab, root)
  tab = tostring(tab or "")
  state.tabs[tab] = state.tabs[tab] or { roots = {} }
  local t = state.tabs[tab]
  t.roots[root] = t.roots[root] or { expanded = {}, order = {}, filter = nil }
  return t, t.roots[root]
end

local read_provider_state = ya.sync(function(state, tab, root)
  local _, r = tab_state(state, tab, root)
  local expanded = {}
  for path in pairs(r.expanded) do expanded[#expanded + 1] = path end
  return expanded, r.filter, r.order or {}
end)
local commit_provider_state = ya.sync(function(state, tab, root, expanded, filter, order)
  local t, r = tab_state(state, tab, root)
  if expanded then
    r.expanded = {}
    for _, path in ipairs(expanded) do r.expanded[path] = true end
  end
  if filter ~= nil then r.filter = filter ~= "" and filter or nil end
  if order ~= nil then r.order = order end
  t.root, state.root = root, root
  return true
end)
local remap_provider_state = ya.sync(function(state, from, to)
  local function mapped(path)
    if path == from then return to end
    if path:sub(1, #from + 1) == from .. "/" then return to .. path:sub(#from) end
    return path
  end
  for _, tab in pairs(state.tabs) do
    local roots = {}
    for root, data in pairs(tab.roots) do
      local nr, nd = mapped(root), { expanded = {}, order = data.order, filter = data.filter }
      for path in pairs(data.expanded) do nd.expanded[mapped(path)] = true end
      roots[nr] = nd
    end
    tab.roots = roots
    if tab.root then tab.root = mapped(tab.root) end
  end
  if state.root then state.root = mapped(state.root) end
end)
M.remap_state = remap_provider_state

local function write_file(path, data)
  local f, err = io.open(path, "w")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

-- Build a view portal URL: [1] is the real source URL; data carries state.
local function view_url(real, depth, tab, filter)
  return Url { Url(real), scheme = "tree", domain = DOMAIN, data = { depth = depth or 0, tab = tab, filter = filter } }
end

-- Real metadata for an already-built view URL (entry or portal).
local function file_from_url(url)
  local f, err = fs.file(Url(url.physical)) -- async; real local metadata
  if not f then return nil, err end
  ya.dbg(string.format(
    "[tvfs] file %s len=%s dir=%s",
    tostring(url.physical),
    tostring(f.stat and f.stat.len),
    tostring(f.stat and f.stat.is_dir)
  ))
  return File { url = url, stat = f.stat, lstat = f.lstat, link_to = f.link_to }
end

local function walk(real, depth, expanded, out, hidden, order)
  local files, err = fs.read_dir(Url(real), { resolve = true })
  if not files then return out, err end
  local rank = {}
  if depth == 0 and order then for i, name in ipairs(order) do rank[name] = i end end
  table.sort(files, function(a, b)
    local ad, bd = a.stat and a.stat.is_dir, b.stat and b.stat.is_dir
    if ad ~= bd then return ad == true end
    if depth == 0 and order then
      local ar, br = rank[tostring(a.name)] or math.huge, rank[tostring(b.name)] or math.huge
      if ar ~= br then return ar < br end
    end
    return tostring(a.name) < tostring(b.name)
  end)
  for _, f in ipairs(files) do
    local child = real .. "/" .. tostring(f.name)
    local name = tostring(f.name)
    if hidden or name:sub(1, 1) ~= "." then
      out[#out + 1] = { real = child, depth = depth, name = name }
      local linked = (f.lstat and (f.lstat.is_link or f.lstat.is_indirect)) or (f.stat and (f.stat.is_link or f.stat.is_indirect))
      if f.stat and f.stat.is_dir and not linked and expanded[child] then
        walk(child, depth + 1, expanded, out, hidden, order)
      end
    end
  end
  return out
end

function M:provide(job)
  local op = job.op
  if op == "Capabilities" then
    return { file = 1, read_dir = 1, revalidate = 1 }
  elseif op == "ReadDir" then
    local folder = job.url                        -- view portal
    local root = tostring(folder.physical)        -- real cwd/root
    local data = folder.spec.data or {}
    local paths, query, order = read_provider_state(data.tab, root)
    local expanded = {}; for _, path in ipairs(paths) do expanded[path] = true end
    local flat = walk(root, 0, expanded, {}, rt.mgr.show_hidden, order)
    if query and query ~= "" then
      local lower = query:lower()
      local keep = {}
      for i = #flat, 1, -1 do
        local e = flat[i]
        local match = (query:find("%u") and e.name:find(query, 1, true)) or (not query:find("%u") and e.name:lower():find(lower, 1, true))
        if match then keep[e.real] = true end
        local parent = e.real:match("^(.*)/[^/]+$")
        if keep[e.real] and parent then keep[parent] = true end
        if keep[e.real] or match then e.keep = true end
      end
      local filtered = {}
      for _, e in ipairs(flat) do
        if e.keep or keep[e.real] then filtered[#filtered + 1] = e end
      end
      flat = filtered
    end
    local names = {}
    for i, e in ipairs(flat) do names[i] = e.real end
    ya.dbg("[tvfs] ReadDir tab=" .. tostring(data.tab) .. " root=" .. root .. " entries " .. #flat .. " :: " .. table.concat(names, " "))
    return ya.co(function()
      for _, e in ipairs(flat) do
        local rel = e.real:sub(#root + 2)
        local file, err = file_from_url(folder:join(rel))
        if not file then return nil, err end
        coroutine.yield(file)
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
    cwd_url = tostring(cur.cwd),
    tab = tonumber(cx.active.id.value) or tostring(cx.active.id),
    hovered = h and tostring(h.url.physical) or nil,
    hovered_is_dir = h and h.stat and h.stat.is_dir or false,
    hovered_is_link = h and ((h.stat and h.stat.is_link) or (h.lstat and h.lstat.is_link)) or false,
    hovered_is_indirect = h and ((h.stat and h.stat.is_indirect) or (h.lstat and h.lstat.is_indirect)) or false,
    parent = h and h.url.parent and tostring(h.url.parent.physical) or nil,
    filter = cur.cwd.spec and cur.cwd.spec.data and cur.cwd.spec.data.filter,
    is_tree = cur.cwd.spec and cur.cwd.spec.is_view and cur.cwd.spec.scheme == "tree" and cur.cwd.spec.domain == DOMAIN,
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
    if h.stat and h.stat.is_dir then
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
local reset_tasks = ya.sync(function() cx.tasks.behavior:reset() end)
local layout_update = ya.sync(function(state, tab_id, action, tree_default, preview_default)
  local id = tostring(tab_id or cx.active.id)
  state.tabs[id] = state.tabs[id] or { roots = {} }
  local tab = state.tabs[id]
  if tab.tree_mode == nil then tab.tree_mode = tree_default == true end
  if tab.preview_mode == nil then tab.preview_mode = preview_default ~= false end
  if action == "toggle_tree" then tab.tree_mode = not tab.tree_mode
  elseif action == "toggle_preview" then tab.preview_mode = not tab.preview_mode
  elseif action == "tree" then tab.tree_mode = tree_default == true end
  local base = state.base_ratio or { 1, 3, 4 }
  local ratio = { base[1], base[2], base[3] }
  if tab.tree_mode then ratio[1] = 0 end
  if not tab.preview_mode then ratio[3] = 0 end
  rt.mgr.ratio = ratio
  ya.emit("app:resize", {})
  ya.dbg(string.format("[tvfs] ratio %d,%d,%d", ratio[1], ratio[2], ratio[3]))
  return tab.tree_mode, tab.preview_mode
end)
local begin_navigation = ya.sync(function(state, tab_id)
  state.navigation = state.navigation or {}
  local key = tostring(tab_id)
  state.navigation[key] = (state.navigation[key] or 0) + 1
  return state.navigation[key]
end)
local arm_reveal = ya.sync(function(state, tab_id, sequence, root, origin, focus, filter)
  state.pending_reveal = { tab = tostring(tab_id), sequence = sequence, root = root, origin = origin, focus = focus, filter = filter }
end)

function M:setup(opts)
  if configured then return M end
  opts = opts or {}
  options.style = opts.style == "indent" and "indent" or "lines"
  options.filter_mode = opts.filter_mode or "adopt"
  options.dialogs = opts.dialogs or {}
  options.startup = opts.startup or { tree = false, preview = true }
  M.options = options
  M.base_ratio = { rt.mgr.ratio[1], rt.mgr.ratio[2], rt.mgr.ratio[3] }
  local domains = vf.tree
  if domains then
    domains.default = { kind = "view", run = "tree-vfs" }
  else
    vf.tree = { default = { kind = "view", run = "tree-vfs" } }
  end
  require("tree-vfs.render").configure({ style = options.style, glyphs = opts.glyphs })
  require("tree-vfs.layout").configure(options.startup)
  require("tree-vfs.layout").install_events()
  require("tree-vfs.events")
  require("tree-vfs.poller").install(0.5)
  configured = true
  return M
end

function M:entry(job)
  local args = job.args or {}
  local action = tostring(args[1])
  ya.dbg("[tvfs] action " .. action)
  local entry_snapshot = snapshot()
  local navigation_sequence = begin_navigation(entry_snapshot.tab)
  if action == "left" then action = "collapse" end
  if action == "right" then action = "expand" end
  if action == "create" or action == "bulk_create" then
    local debug_snapshot = snapshot()
    ya.dbg("[tvfs] create is_tree=" .. tostring(debug_snapshot.is_tree) .. " cwd=" .. debug_snapshot.cwd)
  end
  if action == "toggle" then
    local s = snapshot()
    if s.is_tree then ya.emit("cd", { Url(s.cwd), raw = true }) else
      local _, filter = read_provider_state(s.tab, s.cwd)
      commit_provider_state(s.tab, s.cwd, nil, nil)
      ya.emit("cd", { view_url(s.cwd, 0, s.tab, filter), raw = true })
    end
  elseif action == "preview" then
    local s = snapshot()
    layout_update(s.tab, "toggle_preview", options.startup.tree, options.startup.preview)
  elseif action == "tab_create" then
    local s = snapshot()
    if s.is_tree then ya.emit("tab_create", { Url(s.cwd_url) }) else ya.emit("tab_create", { current = true }) end
  elseif action == "open" then
    local s = snapshot()
    if s.is_tree and s.hovered_is_dir then
      ya.emit("plugin", { "tree-vfs", "root_down" })
    else ya.emit("open", {}) end
  elseif action == "create" or action == "bulk_create" then
    operations.create(action, args, snapshot(), options.dialogs)
  elseif action == "rename" then
    local s = snapshot()
    ya.dbg("[tvfs] rename target=" .. tostring(s.hovered) .. " is_tree=" .. tostring(s.is_tree))
    ya.emit("rename", { cursor = "before_ext" })
  elseif action == "escape" then
    local s = snapshot()
    local _, filter = read_provider_state(s.tab, s.cwd)
    if s.is_tree and filter then commit_provider_state(s.tab, s.cwd, nil, ""); ya.emit("refresh", {})
    else ya.emit("escape", {}) end
  end
  if action == "bulk_create" and not snapshot().is_tree then return ya.emit("bulk", {}) end
  if action == "paste" and not snapshot().is_tree then return ya.emit("paste", { force = args.force == true, follow = args.follow == true }) end
  if action == "rename" and not snapshot().is_tree then return ya.emit("rename", { cursor = "before_ext" }) end
  if action == "paste" then
    local s = yank_snapshot()
    local force = args.force == true
    ya.dbg(string.format("[tvfs] paste state items=%d cut=%s dest=%s", #s.items, tostring(s.cut), tostring(s.dest)))
    if #s.items == 0 then return end
    reset_tasks()
    for _, it in ipairs(s.items) do
      local target = s.dest:join(it.name)
      if tostring(target.physical or target) ~= tostring(it.url.physical or it.url) then
        ya.dbg("[tvfs] paste task from=" .. tostring(it.url.physical or it.url) .. " to=" .. tostring(target.physical or target))
        ya.task(s.cut and "move" or "copy", { from = it.url, to = target, force = force, follow = args.follow == true }):spawn()
      end
    end
    if s.cut then ya.emit("unyank", {}); if s.selected > 0 then ya.emit("toggle_all", {}) end end
    return
  end
  if action == "enter" then
    local s = snapshot()
    local cwd = s.cwd
    local _, filter = read_provider_state(s.tab, cwd)
    commit_provider_state(s.tab, cwd, nil, nil)
    write_file(REALCWD, cwd)
    ya.dbg("[tvfs] enter " .. cwd)
    ya.emit("cd", { view_url(cwd, 0, s.tab, filter), raw = true })
  elseif action == "expand" or action == "collapse" then
    local s = snapshot()
    if not s.is_tree then return ya.emit(action == "expand" and "enter" or "leave", {}) end
    if not s.hovered then return end
    local paths = read_provider_state(s.tab, s.cwd)
    local set = {}; for _, path in ipairs(paths) do set[path] = true end
    local focus = s.hovered
    if action == "expand" then
      if not s.hovered_is_dir or s.hovered_is_link or s.hovered_is_indirect then
        ya.dbg("[tvfs] refusing to expand non-directory or linked directory " .. s.hovered)
        return
      end
      set[s.hovered] = true
    else
      local target = set[s.hovered] and s.hovered_is_dir and s.hovered or s.parent
      if not target or not set[target] then return end
      focus = target
      local prefix = target .. "/"
      for path in pairs(set) do
        if path == target or path:sub(1, #prefix) == prefix then set[path] = nil end
      end
    end
     local keys = {}; for path in pairs(set) do keys[#keys + 1] = path end
     commit_provider_state(s.tab, s.cwd, keys, nil)
     ya.dbg("[tvfs] " .. action .. " " .. (action == "collapse" and (s.parent or s.hovered) or s.hovered))
     if focus then arm_reveal(s.tab, navigation_sequence, s.cwd, s.hovered, focus, s.filter) end
     ya.emit("refresh", {})
  elseif action == "filter" or action == "filter_clear" then
    local s = snapshot()
    if not s.is_tree then
      if action == "filter" then ya.emit("filter", { smart = true }) else ya.emit("escape", {}) end
      return
    end
    local paths, _, order = read_provider_state(s.tab, s.cwd)
    local function update(query)
      commit_provider_state(s.tab, s.cwd, paths, query or "", order)
      ya.emit("refresh", {})
    end
    if action == "filter_clear" then return update(nil) end
    local stream = ya.input({ name = "filter", title = "Filter:", history = "shared", value = "", pos = { "top-center", y = 2, w = 80 }, realtime = true, debounce = 0.05 })
    while true do
      local value, event = stream:recv()
      if event == 1 or event == 3 then update(value) end
      if event == 0 or event == 1 or event == 2 then break end
    end
  elseif action == "root_up" then
    local s = snapshot()
    if not s.is_tree then return ya.emit("back", {}) end
    local parent = s.cwd:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then
      commit_provider_state(s.tab, parent, nil, nil)
      ya.emit("cd", { view_url(parent, 0, s.tab), raw = true })
    end
  elseif action == "root_down" then
    local s = snapshot()
    if not s.is_tree then return ya.emit("forward", {}) end
    if s.hovered and s.hovered_is_dir and not s.hovered_is_link and not s.hovered_is_indirect then
      commit_provider_state(s.tab, s.hovered, nil, nil)
      ya.emit("cd", { view_url(s.hovered, 0, s.tab), raw = true })
    elseif s.hovered then
      local rel = s.hovered:sub(#s.cwd + 2)
      if rel:find("/", 1, true) then
        ya.emit("reveal", { target = view_url(s.cwd, 0, s.tab, s.filter):join(rel), raw = true, no_dummy = true })
      elseif rel ~= "" then ya.emit("open", {}) end
    end
  elseif action == "refresh" then
    ya.dbg("[tvfs] refresh")
    ya.emit("refresh", {})
  elseif action == "paste-force" then
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

function M:tab_create(args)
  self:entry({ args = { "tab_create" } })
end

return M
