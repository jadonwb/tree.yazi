--- @since 26.9.1
--- @sync entry
--- Learning spike: independent tree-view and preview-pane layout toggles.

local M = {}

-- Base ratio captured from rt.mgr.ratio while both toggles are off (idle), plus
-- the two independent states. Effective ratios are always recomposed from the
-- base, never mutated in place.
local base
local tree_enabled = false
local preview_enabled = true

local function capture_base()
	local r = rt.mgr.ratio
	base = { r[1], r[2], r[3] }
	ya.dbg("[tree-dbg] captured base ratio=", base[1], base[2], base[3])
end

-- While idle (tree off, preview on) the live ratio is the base, so pick up any
-- external changes (manual config, toggle-pane, etc.) as the new base.
local function sync_base()
	if not tree_enabled and preview_enabled then
		capture_base()
	end
end

local function effective_ratio()
	local p, c, v = base[1], base[2], base[3]
	if not preview_enabled then
		c, v = c + v, 0 -- preview space moves into current
	end
	if tree_enabled then
		c, p = c + p, 0 -- parent space moves into current
	end
	return { p, c, v }
end

local function apply()
	if not base then
		capture_base()
	end

	local ratio = effective_ratio()
	ya.dbg(
		"[tree-dbg] applying ratio=",
		ratio[1],
		ratio[2],
		ratio[3],
		"tree=",
		tostring(tree_enabled),
		"preview=",
		tostring(preview_enabled)
	)
	rt.mgr.ratio = ratio
	ya.emit("app:resize", {})
end

function M:setup()
	ya.dbg("[tree-dbg] setup; Tab=", tostring(Tab))
end

function M:toggle()
	sync_base()
	tree_enabled = not tree_enabled
	ya.dbg("[tree-dbg] toggle tree=", tostring(tree_enabled))
	apply()
end

function M:preview()
	sync_base()
	preview_enabled = not preview_enabled
	ya.dbg("[tree-dbg] toggle preview=", tostring(preview_enabled))
	apply()
end

function M:entry(job)
	local action = job and job.args and job.args[1]
	ya.dbg(
		"[tree-dbg] entry action=",
		tostring(action),
		"tree=",
		tostring(tree_enabled),
		"preview=",
		tostring(preview_enabled)
	)
	if action == "toggle" then
		M:toggle()
	elseif action == "preview" then
		M:preview()
	end
end

return M
