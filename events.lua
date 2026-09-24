local function tree_state() return require("tree-vfs") end
Current.redraw = require("tree-vfs.render").redraw
local REALCWD = rt.path.runtime_dir .. "/tree-vfs-" .. tostring(ya.id("app")) .. ".cwd"

-- Keep the tree view's header location readable like a regular directory.
-- The view URL remains the tab cwd; render its physical source instead.
if not TVFS_HEADER_CWD then
  TVFS_HEADER_CWD = Header.cwd
  Header.cwd = function(self)
    local cwd = self._current.cwd
    local spec = cwd.spec
    if spec.is_view and spec.scheme == "tree" and spec.domain == "default" then
      local s = ya.readable_path(tostring(cwd.physical)) .. self:flags()
      local max = self._area.w - self._right_width
      return ui.Span(ui.truncate(s, { max = max, rtl = true })):style(th.mgr.cwd)
    end
    return TVFS_HEADER_CWD(self)
  end
end

-- Tree view data is depth metadata, not a search query. Suppress only its
-- spurious stock `(search: nil)` label; preserve stock flags everywhere else.
if not TVFS_HEADER_FLAGS then
  TVFS_HEADER_FLAGS = Header.flags
  Header.flags = function(self)
    local spec = self._current.cwd.spec
    if spec.is_view and spec.scheme == "tree" and spec.domain == "default" then
      local data = spec.data or {}
      local module = require("tree-vfs")
      local tab = module.tabs[tostring(data.tab)]
      local root = tostring(self._current.cwd.physical)
      local saved = tab and tab.roots[root]
      return saved and saved.filter and (" (filter: " .. saved.filter .. ")") or ""
    end
    return TVFS_HEADER_FLAGS(self)
  end
end

-- ---------------------------------------------------------------------------
-- Provider lifecycle, mutation reconciliation, physical header, and refresh gate.
--
-- This file is loaded once with `exec_async`, so `ps.sub` callbacks run inside
-- the same Lua state for the whole session. Callbacks are invoked from
-- `app:accept_payload` / `core:preflight`, both wrapped in `Lives::scope`, so
-- the `cx` global is available to them directly (no `ya.sync` needed).
--
-- DDS callbacks stay here because init.lua owns ps/cx. Expansion/filter state is
-- in the provider module's main-runtime table; polling signs physical metadata.
-- ---------------------------------------------------------------------------
local function writefile(p, s)
  local f = io.open(p, "w")
  if not f then return end
  f:write(s)
  f:close()
end
local function emit_later(action, payload)
  ya.async(function() ya.sleep(0); ya.emit(action, payload or {}) end)
end

local function remap_state(mappings)
  local tvfs = tree_state()
  table.sort(mappings, function(a, b) return #a[1] > #b[1] end)
  local function mapped(p)
    for _, pair in ipairs(mappings) do
      local from, to = pair[1], pair[2]
      if p == from then return to end
      if p:sub(1, #from + 1) == from .. "/" then return to .. p:sub(#from) end
    end
    return p
  end
  for _, tab in pairs(tvfs.tabs) do
    local roots = {}
    for root, data in pairs(tab.roots) do
      local expanded = {}
      for p in pairs(data.expanded) do expanded[mapped(p)] = true end
      roots[mapped(root)] = { expanded = expanded, order = data.order, filter = data.filter }
    end
    tab.roots = roots
    if tab.root then tab.root = mapped(tab.root) end
  end
  if tvfs.root then tvfs.root = mapped(tvfs.root) end
end

local function prune_state(paths)
  local tvfs = tree_state()
  for _, tab in pairs(tvfs.tabs) do
    for root, saved in pairs(tab.roots) do
      local remove_root = false
      for _, path in ipairs(paths) do
        if path then
          if root == path or root:sub(1, #path + 1) == path .. "/" then remove_root = true end
          local prefix = path .. "/"
          for expanded in pairs(saved.expanded) do
            if expanded == path or expanded:sub(1, #prefix) == prefix then saved.expanded[expanded] = nil end
          end
        end
      end
      if remove_root then
        tab.roots[root] = nil
        if tab.root == root then tab.root = nil end
        if tvfs.root == root then tvfs.root = nil end
      end
    end
  end
end

local function physical(url)
  local ok_, p = pcall(function() return tostring(url.physical or url) end)
  if ok_ then return p end
  return nil
end

local function active_physical()
  local ok_, p = pcall(function()
    return tostring(cx.active.current.cwd.physical or cx.active.current.cwd)
  end)
  if ok_ then return p end
  return nil
end

local function is_view()
  local ok_, s = pcall(function() return tostring(cx.active.current.cwd) end)
  return ok_ and s:sub(1, 7) == "tree://"
end

local function write_realcwd()
  local p = active_physical()
  if p then
    writefile(REALCWD, p)
    ya.dbg("[tvfs] realcwd " .. p)
  end
end

-- R1: after stock rename revealed the physical path, cd back into the view by
-- revealing the renamed entry's view URL. `trail` is the root portal, so the
-- reveal keeps the view; `key` is the root-relative path.
local function reenter(to_physical)
  local id = tostring(cx.active.id.value or cx.active.id)
  local tvfs = tree_state()
  local tab = tvfs.tabs[id]
  local r = tab and tab.root
  if not r then return end
  local phys = tostring(to_physical)
  if #phys <= #r or phys:sub(1, #r) ~= r or phys:sub(#r + 1, #r + 1) ~= "/" then
    return
  end
  local ap = active_physical()
  if ap and ap:sub(1, #r) ~= r then return end
  local rel = phys:sub(#r + 2)
  local portal = Url { Url(r), scheme = "tree", domain = "default", data = { depth = 0, tab = tonumber(id) or id } }
  ya.dbg("[tvfs] reenter " .. rel)
  emit_later("reveal", { target = portal:join(rel), raw = true, no_dummy = true })
end

local function handle_rename(from_url, to_url)
  local from = physical(from_url)
  local to = physical(to_url)
  if not from or not to or from == to then return end
  remap_state({ { from, to } })
  reenter(to)
end

ps.sub("rename", function(body)
  handle_rename(body.from, body.to)
end)

ps.sub("bulk-rename", function(body)
  local mappings = {}
  for from, to in pairs(body) do
    local a, b = physical(from), physical(to)
    if a and b and a ~= b then mappings[#mappings + 1] = { a, b } end
  end
  if #mappings == 0 then return end
  remap_state(mappings)
  table.sort(mappings, function(a, b) return #a[1] < #b[1] end)
  for _, pair in ipairs(mappings) do reenter(pair[2]) end
end)

for _, kind in ipairs({ "move", "duplicate", "trash", "delete" }) do
  local k = kind
  ps.sub(k, function(body)
    if k == "move" and type(body.items) == "table" then
      local paths = {}
      for _, item in ipairs(body.items) do if item.from then paths[#paths + 1] = physical(item.from) end end
      prune_state(paths)
    elseif (k == "trash" or k == "delete") and type(body.urls) == "table" then
      local paths = {}
      for _, url in ipairs(body.urls) do paths[#paths + 1] = physical(url) end
      prune_state(paths)
    end
    if is_view() then
      ya.dbg("[tvfs] refresh after " .. k)
      emit_later("refresh", {})
    end
  end)
end

local function sync_active_view()
  TVFS_IN_VIEW = is_view()
  TVFS_TAB = tostring(cx.active.id.value or cx.active.id)
  local cwd = cx.active.current.cwd
  TVFS_ROOT = TVFS_IN_VIEW and tostring(cwd.physical) or nil
  local state = tree_state()
  local pending = state.pending_reveal
  if not TVFS_IN_VIEW and pending and pending.tab == TVFS_TAB then
    state.navigation[TVFS_TAB] = (state.navigation[TVFS_TAB] or 0) + 1
    state.pending_reveal = nil
    ya.dbg("[tvfs] cancel stale reveal on View exit root=" .. tostring(pending.root))
  end
  if not TVFS_IN_VIEW and not TVFS_STARTUP_APPLIED and state.options and state.options.startup.tree then
    local physical = tostring(cwd.physical or cwd)
    -- Bootstrap's first cwd may still be a `go://boot` portal, which cannot
    -- itself be the source of a View. Wait for the physical path cd event.
    if physical:sub(1, 1) ~= "/" and physical:sub(1, 7) ~= "sftp://" then return end
    TVFS_STARTUP_APPLIED = true
    local tab = tonumber(TVFS_TAB) or TVFS_TAB
    ya.emit("cd", { Url { Url(physical), scheme = "tree", domain = "default", data = { depth = 0, tab = tab } }, raw = true })
    return
  end
  if TVFS_IN_VIEW then
    local tvfs = state
    local data = cwd.spec.data or {}
    local old_id = tostring(data.tab or TVFS_TAB)
    if old_id ~= TVFS_TAB then
      if not tvfs.tabs[TVFS_TAB] then
        local source = tvfs.tabs[old_id]
        local clone = { roots = {}, root = TVFS_ROOT }
        if source then
          for root, saved in pairs(source.roots) do
            local expanded = {}; for p in pairs(saved.expanded) do expanded[p] = true end
            clone.roots[root] = { expanded = expanded, order = saved.order, filter = saved.filter }
          end
        end
        tvfs.tabs[TVFS_TAB] = clone
      end
      local root, tab_id = TVFS_ROOT, TVFS_TAB
      ya.async(function()
        ya.sleep(0.05)
        local url = Url { Url(root), scheme = "tree", domain = "default", data = { depth = 0, tab = tonumber(tab_id) or tab_id } }
        ya.emit("cd", { url, raw = true })
      end)
    end
    local active = tvfs.tabs[TVFS_TAB]
    if not active then active = { roots = {} }; tvfs.tabs[TVFS_TAB] = active end
    active.roots[TVFS_ROOT] = active.roots[TVFS_ROOT] or { expanded = {}, order = {}, filter = nil }
    active.root = TVFS_ROOT
    tvfs.root = TVFS_ROOT
  end
  require("tree-vfs.layout").set_tree(TVFS_IN_VIEW)
  write_realcwd()
end
ps.sub("cd", sync_active_view)
ps.sub("tab", sync_active_view)

return {}
