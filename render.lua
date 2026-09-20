-- Tree-row rendering primitives and connector configuration. Loaded by the
-- plugin's setup(); the private render style and resolved glyph state live here
-- so main.lua only reads them through style()/glyphs().

local M = {}

-- Compact forms lead with the indent cell and drop the trailing gap, so the
-- branch sits directly against the file icon while every connector stays three
-- cells wide. Root rows keep the empty prefix and remain flush-left.
local DEFAULT_GLYPHS = {
	branch = " ├─",
	last = " └─",
	vertical = " │ ",
	space = "   ",
}

local render_style = "lines"
local glyphs = {
	branch = DEFAULT_GLYPHS.branch,
	last = DEFAULT_GLYPHS.last,
	vertical = DEFAULT_GLYPHS.vertical,
	space = DEFAULT_GLYPHS.space,
}

-- Custom glyphs may keep any width, but they must share one width or the
-- indent and branch columns drift apart. Missing keys fall back to the
-- defaults; an inconsistent or non-string set is ignored wholesale.
local function resolve_glyphs(overrides)
	local pick = {}
	local width
	for _, name in ipairs({ "branch", "last", "vertical", "space" }) do
		local value = overrides[name]
		if value == nil then
			value = DEFAULT_GLYPHS[name]
		end
		if type(value) ~= "string" or value == "" then
			ya.dbg("[tree-dbg] ignoring glyph overrides: ", name, " is not a non-empty string")
			return nil
		end
		local w = ui.width(value)
		if width == nil then
			width = w
		elseif w ~= width then
			ya.dbg("[tree-dbg] ignoring glyph overrides: widths differ at ", name)
			return nil
		end
		pick[name] = value
	end
	return pick
end

-- Apply setup options. Repeated calls re-apply the style and replace the glyph
-- set only when the overrides resolve.
function M.configure(opts)
	render_style = opts.style == "indent" and "indent" or "lines"
	if type(opts.glyphs) == "table" then
		local resolved = resolve_glyphs(opts.glyphs)
		if resolved then
			glyphs = resolved
		end
	end
end

function M.style()
	return render_style
end

function M.glyphs()
	return glyphs
end

-- Prefix columns for a row: `depth-1` ancestor cells (vertical or blank, from
-- the continuation flags) plus the row's own branch/last connector. Root rows
-- (depth 0) stay flush-left. `cont[i]` is true when the ancestor at level i has
-- a later sibling, so its column must keep drawing a vertical.
function M.row_prefix(depth, last, cont)
	if depth <= 0 then
		return ""
	end
	if render_style == "indent" then
		return string.rep(glyphs.space, depth)
	end
	local parts = {}
	for i = 1, depth - 1 do
		parts[#parts + 1] = (cont and cont[i]) and glyphs.vertical or glyphs.space
	end
	parts[#parts + 1] = last and glyphs.last or glyphs.branch
	return table.concat(parts)
end

-- Style-field names as they come back from Style:raw(), mapped to the
-- modifier methods used to invert them.
local MOD_METHODS = {
	bold = "bold",
	dim = "dim",
	italic = "italic",
	underline = "underline",
	blink = "blink",
	blink_rapid = "blink_rapid",
	reversed = "reverse",
	hidden = "hidden",
	crossed = "crossed",
}

-- The outer ui.Line style paints the whole row before spans run (ratatui
-- set_style), so the connector inherits the hover indicator. A span can only
-- set fields, never clear them, so invert exactly the fields the active
-- indicator sets. `style` is th.indicator.current in this pane.
function M.unhighlight(style)
	local cancel = ui.Style()
	local raw = style:raw()
	if raw.fg then
		cancel = cancel:fg("reset")
	end
	if raw.bg then
		cancel = cancel:bg(App.bg())
	end
	for key, method in pairs(MOD_METHODS) do
		local value = raw[key]
		if value ~= nil then
			-- The binding's modifier methods take `remove`: passing true moves
			-- the modifier into sub_modifier (which Cell::set_style removes),
			-- so the raw value is exactly the argument that inverts it.
			cancel = cancel[method](cancel, value)
		end
	end
	return cancel
end

-- Fresh Entity instances are plain tables that can shadow the class method, so
-- an expanded parent can request the theme's hovered-directory icon without
-- touching read-only File.is_hovered or the row's real style.
function M.open_icon(self)
	local icon = th.icon:match(self._file, { hovered = true })
	if not icon then
		return ""
	elseif self._file.is_hovered then
		return icon.text .. " "
	else
		return ui.Line(icon.text .. " "):style(icon.style)
	end
end

-- ---------------------------------------------------------------------------
-- Current.redraw pass. Only setup() installs this (there is no sync entry path
-- to it), so main.lua keeps the stock renderer until install() runs. Mutable
-- plugin state (M.rows/M.expanded) stays owned by main.lua and is read through
-- the accessors bound here; nothing in this module writes plugin state.
-- ---------------------------------------------------------------------------

-- Bound capabilities: the stock Current.redraw fallback, the active-tree
-- predicate, per-row relative depth, and accessors for the live rows/expanded
-- tables (both are reassigned during rebuilds, so only accessors are safe to
-- hold). M is never passed in.
local bind

-- Bounded diagnostics: log at most the first custom redraw/open-icon per enable.
local logged_redraw = false
local logged_open_icon = false

-- One-time binding; later calls are ignored so setup() stays idempotent and the
-- stored capabilities are never replaced.
function M.install(caps)
	if bind then
		return false
	end
	bind = caps
	return true
end

-- Reset the per-enable log-once diagnostics so the next tree frame logs again.
function M.reset_logs()
	logged_redraw = false
	logged_open_icon = false
end

-- Reproduce preset Current:redraw() from the already-loaded folder window,
-- prefixing every injected descendant (depth > 0) with connectors that stay
-- correct at any depth. Root rows stay flush-left. One ui.Line per item keeps
-- row i aligned with the folder cursor. The connector span cancels the hover
-- indicator; the outer line style still fills the entity region through the
-- right edge exactly like stock.
local function redraw_tree(self)
	local folder = self._folder
	local files = folder.window
	local cwd = folder.cwd
	local left, right = {}, {}
	local open_icon = M.open_icon

	local rows = bind.rows()
	local expanded = bind.expanded()

	local depths = {}
	for i = 1, #files do
		depths[i] = bind.relative_depth(files[i], cwd)
	end

	-- Fallback metadata for rows absent from the last rebuild snapshot (for
	-- example a root file that appeared without a rebuild): a forward scan for
	-- the final sibling plus an ancestor stack reproducing the flatten's
	-- continuation recurrence.
	local lasts, conts = {}, {}
	local anc_last = {}
	for i = 1, #files do
		local d = depths[i] or 0
		local last = true
		for j = i + 1, #files do
			local dj = depths[j] or 0
			if dj < d then
				break
			elseif dj == d then
				last = false
				break
			end
		end
		lasts[i] = last
		local cont = {}
		for level = 1, d - 1 do
			cont[level] = not anc_last[level]
		end
		conts[i] = cont
		anc_last[d] = last
	end

	local cancel = M.unhighlight(th.indicator.current)
	local open_dirs = {}

	for i, f in ipairs(files) do
		local meta = rows[tostring(f.url)]
		local depth, last, cont
		if meta then
			depth, last, cont = meta.depth, meta.last, meta.cont
		else
			depth, last, cont = depths[i] or 0, lasts[i], conts[i]
		end

		local prefix = M.row_prefix(depth, last, cont)
		local pw = ui.width(prefix)

		local entity = Entity:new(f)
		if f.cha and f.cha.is_dir and expanded[tostring(f.url)] then
			entity.icon = open_icon
			open_dirs[#open_dirs + 1] = tostring(f.name)
		end

		local line = ui.Line({ ui.Span(prefix):style(cancel), entity:redraw() }):style(entity:style())
		left[#left + 1] = line
		right[#right + 1] = Linemode:new(f):redraw()
		local max = math.max(0, self._area.w - right[#right]:width())
		line:truncate({ max = max, ellipsis = entity:ellipsis(math.max(0, max - pw)) })
	end

	if #open_dirs > 0 and not logged_open_icon then
		logged_open_icon = true
		ya.dbg("[tree-dbg] open-folder icon on expanded dirs: ", table.concat(open_dirs, ", "))
	end

	return {
		ui.List(left):area(self._area),
		ui.Text(right):area(self._area):align(ui.Align.RIGHT),
		table.unpack(Dnd:new(self._area):redraw()),
	}
end

-- Only Current.redraw is replaced, so every stock Current interaction method
-- (click, scroll, touch, drag, drop, empty) stays intact.
function M.redraw(self)
	if not bind.active_tree() then
		return bind.saved(self)
	end
	local files = self._folder and self._folder.window
	if not files or #files == 0 then
		return bind.saved(self)
	end
	if not logged_redraw then
		logged_redraw = true
		local style, gl = M.style(), M.glyphs()
		ya.dbg(
			"[tree-dbg] render style=",
			style,
			"branch=",
			gl.branch,
			"last=",
			gl.last,
			"vertical=",
			gl.vertical,
			"space=",
			gl.space,
			"rows=",
			#files
		)
	end
	return redraw_tree(self)
end

return M
