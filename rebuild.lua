-- Asynchronous rebuild + FilesOp injection pass for the tree plugin: reads the
-- expanded subtrees, flattens and filters them in the captured root order,
-- publishes row metadata, and injects the resulting rows. Mutable plugin state
-- stays owned by main.lua; this module reaches it only through the guarded
-- generation/tab bridges passed in ctx.

local M = {}

-- Raw flatten table, resolved lazily on first use so child ordering and name
-- matching stay plain synchronous calls inside the directory/node loops.
local flatten

function M.run(ctx)
	if not flatten then
		require("tree.flatten") -- async context: safe here
		flatten = package.loaded["tree.flatten"]
	end
	local sort_children = flatten.sort_children
	local match_name = flatten.match_name

	local gen = ctx.gen
	local tab = ctx.tab
	local cwd_str = ctx.cwd_str
	local expanded = ctx.expanded
	local root_order = ctx.root_order
	local filter = ctx.filter
	local show_hidden = ctx.show_hidden
	local ticket = ctx.ticket
	local injected = ctx.injected
	local focus_str = ctx.focus_str
	local check_gen = ctx.check_gen
	local set_root_order = ctx.set_root_order
	local set_rows = ctx.set_rows
	local set_expanded = ctx.set_expanded
	local set_hidden_roots = ctx.set_hidden_roots
	local finish_rebuild = ctx.finish_rebuild

	local started = ya.time()
	if not check_gen(gen, tab) then
		return
	end

	local root_files = fs.read_dir(Url(cwd_str), { resolve = true })
	if not root_files then
		ya.dbg("[tree-dbg] async root read failed")
		finish_rebuild(gen, tab, nil)
		return
	end

	local expanded_set = {}
	for _, u in ipairs(expanded) do
		expanded_set[u] = true
	end

	local by_url = {}
	for _, f in ipairs(root_files) do
		by_url[tostring(f.url)] = f
	end

	-- Authoritative root order: keep known roots in place, drop deleted
	-- ones, then append roots created since the order was captured.
	local order, seen_order = {}, {}
	for _, url_str in ipairs(root_order) do
		if by_url[url_str] and not seen_order[url_str] then
			seen_order[url_str] = true
			order[#order + 1] = url_str
		end
	end
	for _, f in ipairs(root_files) do
		local u = tostring(f.url)
		if not seen_order[u] then
			seen_order[u] = true
			order[#order + 1] = u
		end
	end

	-- Lazy, reachability-driven reads: only expanded directories reachable
	-- from a root are read, so an expanded key under a collapsed ancestor
	-- costs no I/O. Symlinked/indirect directories are never descended
	-- (cycle guard); a read failure simply drops that subtree.
	local function expandable(f)
		return f.cha and f.cha.is_dir and not f.cha.is_link and not f.cha.is_indirect
	end

	local kids_by_parent = {}
	local dirs_read = 0

	-- While hidden files are off a hidden directory is an unread boundary: it
	-- is never queued or descended, so its subtree costs no I/O. Each topmost
	-- skipped hidden directory is recorded in `hidden_deferred` so its
	-- expansion keys can be retained (see the retention pass below) and the
	-- poller can exclude the subtree without reading it. Suppression at
	-- emission (is_visible) still keeps the subtree out of the rows.
	local queue, qi = {}, 1
	local hidden_deferred = {}
	for _, f in ipairs(root_files) do
		if expandable(f) and expanded_set[tostring(f.url)] then
			if not show_hidden and f.cha and f.cha.is_hidden then
				hidden_deferred[tostring(f.url)] = true
			else
				queue[#queue + 1] = f
			end
		end
	end

	-- What the BFS actually reached, plus directories whose listing failed. A
	-- reachable expanded key is live; a failed read means that subtree is
	-- unverifiable, so its keys are retained rather than treated as deleted.
	local reached, unreadable = {}, {}
	while qi <= #queue do
		if not check_gen(gen, tab) then
			return
		end
		local f = queue[qi]
		qi = qi + 1
		local dir_str = tostring(f.url)
		reached[dir_str] = true
		local kids = fs.read_dir(Url(dir_str), { resolve = true })
		dirs_read = dirs_read + 1
		if kids then
			sort_children(kids)
			kids_by_parent[dir_str] = kids
			for _, k in ipairs(kids) do
				if expandable(k) and expanded_set[tostring(k.url)] then
					if not show_hidden and k.cha and k.cha.is_hidden then
						hidden_deferred[tostring(k.url)] = true
					else
						queue[#queue + 1] = k
					end
				end
			end
		else
			unreadable[dir_str] = true
			ya.dbg("[tree-dbg] nested read failed; dir=", dir_str)
		end
	end

	if not check_gen(gen, tab) then
		return
	end

	-- Hierarchy-aware visibility: a row is kept when its basename matches
	-- the query or it owns a matching descendant through an expanded
	-- directory. Unexpanded subtrees stay opaque (lazy expansion).
	local visible_memo = {}
	local function is_visible(f)
		-- Hidden suppression must run before the filter test so a hidden
		-- directory drops its whole subtree: `walk` only descends into
		-- children that pass is_visible, so excluding the ancestor excludes
		-- every descendant and no orphaned injected row can outlive its
		-- hidden parent. Matching on `f.cha.is_hidden` reproduces Yazi's own
		-- Entries::split_files rule exactly.
		if not show_hidden and f.cha and f.cha.is_hidden then
			return false
		end
		if not filter then
			return true
		end
		local u = tostring(f.url)
		local v = visible_memo[u]
		if v ~= nil then
			return v
		end
		if match_name(tostring(f.name), filter) then
			visible_memo[u] = true
			return true
		end
		local kids = kids_by_parent[u]
		if kids then
			for _, k in ipairs(kids) do
				if is_visible(k) then
					visible_memo[u] = true
					return true
				end
			end
		end
		visible_memo[u] = false
		return false
	end

	local all, rows, added = {}, {}, {}
	local row_count = 0

	local function emit(f, depth, last, cont, parent_str)
		local u = tostring(f.url)
		if added[u] then
			return
		end
		added[u] = true
		all[#all + 1] = f
		rows[u] = { depth = depth, last = last, cont = cont, parent = parent_str }
		row_count = row_count + 1
	end

	-- Pure depth-first flatten over the captured root order. Child order is
	-- the per-directory dirs-first/alphabetical listing; `cont` carries the
	-- ancestor continuation flags so connectors stay correct at any depth.
	local function walk(f, depth, cont)
		local u = tostring(f.url)
		local kids = kids_by_parent[u]
		if not kids then
			return
		end
		local visible = {}
		for _, k in ipairs(kids) do
			if is_visible(k) then
				visible[#visible + 1] = k
			end
		end
		local parent_last = true
		if rows[u] then
			parent_last = rows[u].last
		end
		for i, k in ipairs(visible) do
			local k_last = (i == #visible)
			local k_cont = {}
			for j = 1, #cont do
				k_cont[j] = cont[j]
			end
			if depth > 0 then
				k_cont[#k_cont + 1] = not parent_last
			end
			emit(k, depth + 1, k_last, k_cont, u)
			walk(k, depth + 1, k_cont)
		end
	end

	for _, url_str in ipairs(order) do
		local f = by_url[url_str]
		if f and is_visible(f) then
			emit(f, 0, true, {}, cwd_str)
			walk(f, 0, {})
		end
	end

	set_root_order(gen, tab, order)
	set_rows(gen, tab, rows)
	-- Publish the topmost hidden directories skipped by this rebuild so the
	-- poller can drop their subtree from its scoped keys while hidden is off.
	set_hidden_roots(gen, tab, hidden_deferred)

	-- Publish the reachable expansion set: keep a key when the BFS read it, or
	-- when it sits under a directory whose listing failed or that was hidden
	-- while hidden files are off (both subtrees cannot be proven gone, so
	-- their keys are retained rather than treated as deleted). Everything else
	-- is stale and is dropped, which is what stops a later recreation of an
	-- old path from auto-expanding.
	local retained = {}
	local function under_any(u, dirs)
		for d in pairs(dirs) do
			if u == d or u:sub(1, #d + 1) == d .. "/" then
				return true
			end
		end
		return false
	end
	for _, u in ipairs(expanded) do
		if reached[u] or under_any(u, unreadable) or under_any(u, hidden_deferred) then
			retained[#retained + 1] = u
		end
	end
	set_expanded(gen, tab, retained)

	-- Final generation+tab check right before the atomic emit sequence, so
	-- a stale rebuild cannot reset a folder owned by a newer generation or
	-- a different tab (update_files is always active-tab-only).
	if not check_gen(gen, tab) then
		return
	end

	ya.emit("update_files", { op = fs.op("part", { id = ticket, url = Url(cwd_str), files = {} }) })
	ya.emit("update_files", { op = fs.op("part", { id = ticket, url = Url(cwd_str), files = all }) })
	ya.emit("update_files", {
		op = fs.op("done", {
			id = ticket,
			-- File constructor contract: followed `stat` plus unfollowed
			-- `lstat` (the old `cha` field is gone).
			file = File({
				url = Url(cwd_str),
				stat = fs.cha(Url(cwd_str), true),
				lstat = fs.cha(Url(cwd_str), false),
			}),
		}),
	})

	if focus_str then
		ya.emit("plugin", { "tree", "focus" })
	end

	ya.dbg(
		"[tree-dbg] rebuild done gen=",
		gen,
		"dirs=",
		dirs_read,
		"rows=",
		row_count,
		"expanded=",
		#expanded,
		"ms=",
		string.format("%.1f", (ya.time() - started) * 1000)
	)

	finish_rebuild(gen, tab, injected)
end

return M
