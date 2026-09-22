-- Cursor/row helpers over the active `cx` folder.

local M = {}

-- ---------------------------------------------------------------------------
-- Depth / connector helpers (pure; safe to call from the async callback).
-- ---------------------------------------------------------------------------

local function relative_depth(f, cwd)
	local rel = f.url:strip_prefix(cwd)
	local rs = rel and tostring(rel) or ""
	local depth = 0
	for _ in rs:gmatch("/") do
		depth = depth + 1
	end
	return depth
end

-- cwd-relative path of an absolute URL string, or nil when it is outside the
-- current tree root. Used for path-boundary-safe subtree comparisons.
local function rel_of(url_str)
	local rel = Url(url_str):strip_prefix(cx.active.current.cwd)
	return rel and tostring(rel) or nil
end

local function relative_of(file)
	local rel = file.url:strip_prefix(cx.active.current.cwd)
	return rel and tostring(rel) or ""
end

-- Safety net: does the active folder currently hold any injected descendant
-- (depth > 0) rows? Used only on teardown, so the extra scan is bounded.
local function has_descendants()
	local cwd = cx.active.current.cwd
	for _, f in ipairs(cx.active.current.files) do
		local rel = f.url:strip_prefix(cwd)
		local rs = rel and tostring(rel) or ""
		if rs:find("/", 1, true) then
			return true
		end
	end
	return false
end

-- Only used to seed M.root_order.
local function capture_root_order()
	local order = {}
	for _, f in ipairs(cx.active.current.files) do
		order[#order + 1] = tostring(f.url)
	end
	return order
end

local function count_keys(t)
	local n = 0
	for _ in pairs(t or {}) do
		n = n + 1
	end
	return n
end

-- Regenerate the per-URL row metadata for the rows already displayed, without a
-- filesystem read. Same math as redraw_tree's fallback, plus the parent URL the
-- left action needs.
local function rehydrate_rows()
	local files, cwd = cx.active.current.files, cx.active.current.cwd
	local depths = {}
	for i = 1, #files do
		depths[i] = relative_depth(files[i], cwd)
	end
	local rows, anc = {}, {}
	for i = 1, #files do
		local d = depths[i]
		local last = true
		for j = i + 1, #files do
			local dj = depths[j]
			if dj < d then
				break
			elseif dj == d then
				last = false
				break
			end
		end
		local cont = {}
		for level = 1, d - 1 do
			cont[level] = not anc[level]
		end
		anc[d] = last
		local rel = files[i].url:strip_prefix(cwd)
		local pr = rel and tostring(rel):match("^(.*)/[^/]*$")
		rows[tostring(files[i].url)] = {
			depth = d,
			last = last,
			cont = cont,
			parent = pr and pr ~= "" and tostring(cwd:join(pr)) or tostring(cwd),
		}
	end
	return rows
end

-- Directories-first alphabetical depth-0 URL order from the folder's real
-- children, or nil when none are loaded yet. main.lua owns the guard checks
-- (root_order/expanded already set, native provider View) and the M writes.
local function seed_root_order()
	local cwd = cx.active.current.cwd
	local files = {}
	for _, f in ipairs(cx.active.current.files) do
		local rel = f.url:strip_prefix(cwd)
		local rs = rel and tostring(rel) or ""
		if rs ~= "" and not rs:find("/", 1, true) then
			files[#files + 1] = f
		end
	end
	if #files == 0 then
		return nil
	end
	table.sort(files, function(a, b)
		local ad = a.stat and a.stat.is_dir and true or false
		local bd = b.stat and b.stat.is_dir and true or false
		if ad ~= bd then
			return ad
		end
		return tostring(a.name) < tostring(b.name)
	end)
	local order = {}
	for i, f in ipairs(files) do
		order[i] = tostring(f.url)
	end
	return order
end

-- Synchronously remove restored descendant rows. Emits the same part/part/done
-- sequence rebuild uses, reusing the current Folder's depth-0 File userdata so
-- no filesystem read is needed. Emits only; the caller owns the ticket
-- allocation and the injected/injecting flags.
local function strip_descendants(ticket)
	local files, cwd = cx.active.current.files, cx.active.current.cwd
	local cwd_str = tostring(cwd)
	local real = {}
	for i = 1, #files do
		local rel = files[i].url:strip_prefix(cwd)
		if rel and not tostring(rel):find("/", 1, true) then
			real[#real + 1] = files[i]
		end
	end
	ya.emit("update_files", { op = fs.op("part", { id = ticket, url = Url(cwd_str), files = {} }) })
	ya.emit("update_files", { op = fs.op("part", { id = ticket, url = Url(cwd_str), files = real }) })
	ya.emit("update_files", {
		op = fs.op("done", { id = ticket, file = cx.active.current.file }),
	})
end

M.relative_depth = relative_depth
M.rel_of = rel_of
M.relative_of = relative_of
M.has_descendants = has_descendants
M.capture_root_order = capture_root_order
M.count_keys = count_keys
M.rehydrate_rows = rehydrate_rows
M.seed_root_order = seed_root_order
M.strip_descendants = strip_descendants

return M
