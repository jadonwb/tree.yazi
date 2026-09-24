local M = { base = { 1, 3, 4 } }

local function id() return tostring(cx.active.id.value or cx.active.id) end
local function state()
  local key = id()
  local tvfs = require("tree-vfs")
  tvfs.tabs[key] = tvfs.tabs[key] or { roots = {} }
  local tab = tvfs.tabs[key]
  if tab.tree_mode == nil then tab.tree_mode = M.defaults and M.defaults.tree or false end
  if tab.preview_mode == nil then tab.preview_mode = not M.defaults or M.defaults.preview ~= false end
  return tab
end

local function set_ratio(emit_resize)
  local s = state()
  local ratio = { M.base[1], M.base[2], M.base[3] }
  if s.tree_mode then ratio[1] = 0 end
  if not s.preview_mode then ratio[3] = 0 end
  rt.mgr.ratio = ratio
  ya.dbg(string.format("[tvfs] ratio %d,%d,%d", ratio[1], ratio[2], ratio[3]))
  if emit_resize then ya.emit("app:resize", {}) end
end

function M.apply()
  set_ratio(true)
end

function M.configure(opts)
  local ratio = rt.mgr.ratio
  if type(ratio) == "table" and #ratio >= 3 then M.base = { ratio[1], ratio[2], ratio[3] } end
  opts = opts or {}
  M.defaults = { tree = opts.tree == true, preview = opts.preview ~= false }
  local tvfs = require("tree-vfs")
  tvfs.base_ratio = M.base
  local ratio = { M.base[1], M.base[2], M.base[3] }
  if M.defaults.tree then ratio[1] = 0 end
  if not M.defaults.preview then ratio[3] = 0 end
  rt.mgr.ratio = ratio
  ya.dbg(string.format("[tvfs] ratio %d,%d,%d", ratio[1], ratio[2], ratio[3]))
  ya.emit("app:resize", {})
end

function M.toggle_tree()
  local s = state(); s.tree_mode = not s.tree_mode; M.apply(); return s.tree_mode
end
function M.toggle_preview()
  local s = state(); s.preview_mode = not s.preview_mode; M.apply(); return s.preview_mode
end
function M.is_tree() return state().tree_mode end
function M.set_tree(value) state().tree_mode = value == true; M.apply() end
function M.install_events()
  if M.subscribed then return end
  M.subscribed = true
  ps.sub("cd", function() M.apply() end)
  ps.sub("tab", function() M.apply() end)
  ps.sub("app:resize", function() set_ratio(false) end)
end

return M
