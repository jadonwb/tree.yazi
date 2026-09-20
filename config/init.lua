-- Compatibility probe only: records whether the View/Url-source mechanism exists.
ya.dbg("[tvfs] vf=" .. type(vf))
local ok, u = pcall(function()
  return Url {
    Url("/home/jadon/.config/yazi/plugins/tree-vfs.yazi/fixture"),
    scheme = "tree",
    domain = "default",
    data = { depth = 0 },
  }
end)
ya.dbg(string.format(
  "[tvfs] url-ok=%s physical=%s",
  tostring(ok),
  tostring(ok and u.physical or u)
))

-- ---------------------------------------------------------------------------
-- Increment 2 event hub (prototype-only, contained under the prototype root).
--
-- This file is loaded once with `exec_async`, so `ps.sub` callbacks run inside
-- the same Lua state for the whole session. Callbacks are invoked from
-- `app:accept_payload` / `core:preflight`, both wrapped in `Lives::scope`, so
-- the `cx` global is available to them directly (no `ya.sync` needed).
--
-- Responsibilities:
--   * rename/bulk-rename  -> remap state/expanded, then re-enter the view by
--     revealing the renamed entry's *view URL* (R1).
--   * move/duplicate/trash/delete -> explicit refresh while a view is active.
--   * cd -> maintain out/realcwd.txt (option C workaround for --cwd-file).
--   * key-quit (TVFS_KEYQUIT=1) -> negative experiment for the preflight route.
--   * TVFS_POLL=1 -> bounded poller that refreshes the active view (mechanism 2).
-- ---------------------------------------------------------------------------
local R = "/home/jadon/.config/yazi/plugins/tree-vfs.yazi"
local EXPANDED = R .. "/state/expanded"
local ROOT_STATE = R .. "/state/root"
local REALCWD = R .. "/out/realcwd.txt"

local function readfile(p)
  local f = io.open(p, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function writefile(p, s)
  local f = io.open(p, "w")
  if not f then return end
  f:write(s)
  f:close()
end

local function read_state()
  local set, f = {}, io.open(EXPANDED, "r")
  if f then
    for line in f:lines() do
      if line ~= "" then set[line] = true end
    end
    f:close()
  end
  return set
end

local function write_state(set)
  local keys = {}
  for k in pairs(set) do keys[#keys + 1] = k end
  table.sort(keys)
  local f = io.open(EXPANDED, "w")
  if not f then return end
  for _, k in ipairs(keys) do f:write(k, "\n") end
  f:close()
end

local function root()
  local r = readfile(ROOT_STATE)
  if not r then return nil end
  r = r:gsub("%s+$", "")
  return r ~= "" and r or nil
end

local function remap_state(from, to)
  local set = read_state()
  local out = {}
  for p in pairs(set) do
    if p == from then
      out[to] = true
    elseif p:sub(1, #from + 1) == from .. "/" then
      out[to .. p:sub(#from)] = true
    else
      out[p] = true
    end
  end
  write_state(out)
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
  local r = root()
  if not r then return end
  local phys = tostring(to_physical)
  if #phys <= #r or phys:sub(1, #r) ~= r or phys:sub(#r + 1, #r + 1) ~= "/" then
    return
  end
  local ap = active_physical()
  if ap and ap:sub(1, #r) ~= r then return end
  local rel = phys:sub(#r + 2)
  local portal = Url { Url(r), scheme = "tree", domain = "default", data = { depth = 0 } }
  ya.dbg("[tvfs] reenter " .. rel)
  ya.emit("reveal", { target = portal:join(rel), raw = true, no_dummy = true })
end

local function handle_rename(from_url, to_url)
  local from = physical(from_url)
  local to = physical(to_url)
  if not from or not to or from == to then return end
  remap_state(from, to)
  reenter(to)
end

ps.sub("rename", function(body)
  handle_rename(body.from, body.to)
end)

ps.sub("bulk-rename", function(body)
  for from, to in pairs(body) do
    handle_rename(from, to)
  end
end)

for _, kind in ipairs({ "move", "duplicate", "trash", "delete" }) do
  local k = kind
  ps.sub(k, function()
    if is_view() then
      ya.dbg("[tvfs] refresh after " .. k)
      ya.emit("refresh", {})
    end
  end)
end

ps.sub("cd", function()
  TVFS_IN_VIEW = is_view()
  write_realcwd()
end)

if os.getenv("TVFS_KEYQUIT") == "1" then
  -- S28 negative experiment: the key-quit preflight can queue a cd, but
  -- app:quit reads cx.mgr.cwd() before that queued cd is processed.
  ps.sub("key-quit", function(body)
    ya.dbg("[tvfs] keyquit preflight")
    if is_view() then
      local p = active_physical()
      if p then ya.emit("cd", { Url(p), raw = true }) end
    end
    return body
  end)
end

if os.getenv("TVFS_POLL") == "1" then
  -- `ya.sync` is not available in init.lua, so the cd handler records view
  -- state in a plain global that the poller reads.
  -- `ya.async` returns a handle whose Drop aborts the task; keep it referenced
  -- for the lifetime of the process or Lua GC kills the poller immediately.
  ya.dbg("[tvfs] poll start")
  TVFS_POLL_HANDLE = ya.async(function()
    while true do
      ya.sleep(2.0)
      if TVFS_IN_VIEW then
        ya.dbg("[tvfs] poll refresh")
        ya.emit("refresh", {})
      end
    end
  end)
end
