-- Layout/ratio and per-tab sort handoff for the live tree. This module owns the
-- canonical base ratio captured from rt.mgr.ratio while the active tab is idle
-- (tree off, preview on), the effective-ratio composition of the active tab's
-- own modes, the single writer of rt.mgr.ratio plus its app:resize reflow, and
-- the capture/pin/restore of a tab's configured sort while injected hierarchy is
-- live. The tab record and tab preferences are reached only through the bound
-- accessor passed to bind() (installed once from main.lua's M:setup), so this
-- module never holds M -- the same no-M contract as roots.lua/events.lua.

local M = {}

-- Bound once by main.lua; every stateful helper below reads the live tab record
-- and preferences through these closures.
--   tab_state(id) -> the live tab record for `id` (or the active tab), or nil
--   native_search() -> true when the active Folder is a native fd/rg View
--   pref() -> the live cx.active.pref (read fresh on every call, never
--             snapshotted: pin_sort_for re-reads it per call)
local L

function M.bind(accessors)
	L = accessors
end

-- Base ratio captured from rt.mgr.ratio while the active tab is idle (tree off,
-- preview on), plus the startup defaults newly observed tabs are seeded from
-- (the latter stays in main.lua).
local base

-- SortForm fields accepted by the `sort` action, captured for restoration.
M.SORT_FIELDS = { "by", "reverse", "dir_first", "sensitive", "translit", "fallback" }
local SORT_FIELDS = M.SORT_FIELDS

local function capture_base()
	local r = rt.mgr.ratio
	base = { r[1], r[2], r[3] }
	ya.dbg("[tree-dbg] captured base ratio=", base[1], base[2], base[3])
end

local function has_base()
	return base ~= nil
end

-- A tab is idle (tree off, preview on) when its live ratio already equals the
-- canonical base, so an external ratio change observed now (manual config,
-- toggle-pane, etc.) is safe to adopt as the new base.
local function is_idle(t)
	return t ~= nil and not t.tree and t.preview
end

local function sync_base()
	if is_idle(L.tab_state()) then
		capture_base()
	end
end

local function effective_ratio(t)
	local p, c, v = base[1], base[2], base[3]
	if not t.preview then
		c, v = c + v, 0 -- preview space moves into current
	end
	if t.tree then
		c, p = c + p, 0 -- parent space moves into current
	end
	return { p, c, v }
end

-- The only writer of rt.mgr.ratio: recompose from the canonical base and the
-- active tab's own modes, then reflow. Inactive tabs are rendered only once
-- activated, when their own ratio is applied.
local function apply_active()
	local t = L.tab_state()
	if not t then
		return
	end

	if not base then
		capture_base()
	end

	local ratio = effective_ratio(t)
	ya.dbg(
		"[tree-dbg] applying ratio=",
		ratio[1],
		ratio[2],
		ratio[3],
		"tree=",
		tostring(t.tree),
		"preview=",
		tostring(t.preview)
	)
	rt.mgr.ratio = ratio
	ya.emit("app:resize", {})
end

local function capture_sort()
	local p = L.pref()
	return {
		by = p.sort_by,
		reverse = p.sort_reverse,
		dir_first = p.sort_dir_first,
		sensitive = p.sort_sensitive,
		translit = p.sort_translit,
		fallback = p.sort_fallback,
	}
end

local function copy_sort(s)
	if not s then
		return nil
	end
	local o = {}
	for _, field in ipairs(SORT_FIELDS) do
		o[field] = s[field]
	end
	return o
end

-- Pin the active tree tab's folder ordering to `none` while injected hierarchy
-- is live, so the built-in sorter cannot interleave children among the root
-- entries. The configured sort is captured on the tab itself. The live
-- preference is re-checked on every call: a tab created with an explicit target
-- starts from the configured sort rather than the creator's pinned `none`, so
-- acting on sort_saved alone would leave that tab's live sorter reordering the
-- injected rows.
local function pin_sort_for(t)
	if not t then
		return
	end
	if L.native_search() then
		return
	end
	local live = capture_sort()
	if not t.sort_saved then
		t.sort_saved = live
	end
	if live.by ~= "none" then
		ya.dbg("[tree-dbg] pinning sort_by=none (was ", tostring(live.by), ")")
		ya.emit("sort", { by = "none" })
	end
end

-- Restore a tab's configured sort preferences when it leaves tree mode.
local function restore_sort_for(t)
	if not t or not t.sort_saved then
		return
	end
	if L.native_search() then
		return
	end
	local s = t.sort_saved
	t.sort_saved = nil
	ya.dbg("[tree-dbg] restoring sort_by=", tostring(s.by))
	ya.emit("sort", {
		by = s.by,
		reverse = s.reverse,
		dir_first = s.dir_first,
		sensitive = s.sensitive,
		translit = s.translit,
		fallback = s.fallback,
	})
end

M.capture_base = capture_base
M.has_base = has_base
M.is_idle = is_idle
M.sync_base = sync_base
M.effective_ratio = effective_ratio
M.apply_active = apply_active
M.capture_sort = capture_sort
M.copy_sort = copy_sort
M.pin_sort_for = pin_sort_for
M.restore_sort_for = restore_sort_for

return M
