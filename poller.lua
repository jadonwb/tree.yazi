local M = {}

function M.install(interval)
  if TVFS_POLL_HANDLE then return end
  TVFS_POLL_INTERVAL = tonumber(interval) or 0.5
  local signatures, hovered_path, hovered_sig = {}, nil, nil
  ps.sub("hover", function()
    local h = cx.active.current.hovered
    hovered_path = h and tostring(h.url.physical) or nil
    hovered_sig = nil
    if hovered_path then ya.dbg("[tvfs] hover path=" .. hovered_path) end
    local tvfs = require("tree-vfs")
    local pending = tvfs.pending_reveal
    local tab = tostring(cx.active.id.value or cx.active.id)
    local cwd = cx.active.current.cwd
    local root = tostring(cwd.physical or cwd)
    if pending and pending.tab == tab and pending.root == root and hovered_path
      and hovered_path ~= pending.origin and hovered_path ~= pending.focus then
      tvfs.navigation[tab] = (tvfs.navigation[tab] or 0) + 1
      tvfs.pending_reveal = nil
      ya.dbg("[tvfs] cancel stale reveal on hover " .. hovered_path)
    end
  end)
  TVFS_POLL_HANDLE = ya.async(function()
    while true do
      ya.sleep(TVFS_POLL_INTERVAL)
      local tvfs = require("tree-vfs")
      local pending = tvfs.pending_reveal
      if pending then
        local tab_id, root, hover = TVFS_TAB, TVFS_ROOT, hovered_path
        local current = TVFS_IN_VIEW and pending.tab == tab_id and pending.root == root
          and tvfs.navigation[tab_id] == pending.sequence
          and (hover == pending.origin or hover == pending.focus)
        tvfs.pending_reveal = nil
        if current then
          local relative = pending.focus:sub(#root + 2)
          local portal = Url { Url(root), scheme = "tree", domain = "default", data = { depth = 0, tab = tonumber(tab_id) or tab_id, filter = pending.filter } }
          ya.dbg("[tvfs] reveal focus " .. pending.focus)
          ya.emit("reveal", { target = portal:join(relative), raw = true, no_dummy = true })
        else
          ya.dbg("[tvfs] skip stale reveal tab=" .. pending.tab .. " root=" .. pending.root)
        end
      end
      if TVFS_IN_VIEW then
        local tab = tvfs.tabs[TVFS_TAB]
        local root = tab and tab.root
        if root and root == TVFS_ROOT then
          local targets = { [root] = true }
          local r = tab.roots[root]
          if r then for p in pairs(r.expanded) do targets[p] = true end end
          local changed = false
          for p in pairs(targets) do
            local st = fs.stat(Url(p), false)
            local sig = st and table.concat({ tostring(st.mtime), tostring(st.is_dir), tostring(st.dev), tostring(st.btime) }, ":") or "missing"
            if signatures[p] and signatures[p] ~= sig then changed = true end
            signatures[p] = sig
          end
          if hovered_path then
            local st = fs.stat(Url(hovered_path), true)
            local sig = st and (tostring(st.mtime) .. ":" .. tostring(st.len)) or "missing"
            if hovered_sig and hovered_sig ~= sig then changed = true end
            hovered_sig = sig
          end
          if changed then ya.dbg("[tvfs] poll change"); ya.emit("refresh", {}) end
        end
      end
    end
  end)
end

return M
