-- Setup-installed external-change poll loop: the bounded per-tick metadata
-- scan and the one coalesced, generation-guarded rebuild that it drives through
-- the apply bridge. This
-- module owns the poll interval, the (dev, btime) directory-identity helper
-- `dir_identity`, the bounded identity scan `poll_scan`, the per-tick
-- stat/compare `poll_tick`, and the async loop itself. Every read and write of
-- the plugin's mutable state goes through the bounded controller passed to
-- start() (scope/apply/finish are main.lua's ya.sync bridges), so this module
-- never holds M. Compare events.lua's bind() and rebuild.lua's run(): the same
-- no-M contract.

local M = {}

-- Worst-case detection latency for one metadata tick. Directory mtime normally
-- changes on a direct child create/remove/rename, so a real change lands within
-- roughly one interval plus the rebuild.
local POLL_INTERVAL = 1.0

-- Stable directory identity available to Lua on this Yazi: (dev, btime). A
-- same-filesystem rename/move preserves both while ctime changes, so this pair
-- distinguishes a moved directory from a same-path delete+recreate. Returns nil
-- when either half is unavailable (some overlay/FUSE/FAT filesystems), which
-- makes the caller prune safely instead of guessing.
local function dir_identity(dev, btime)
	if dev == nil or btime == nil then
		return nil
	end
	-- %.17g round-trips an f64 exactly; the default tostring precision would
	-- round two directories created within 0.1ms to the same key.
	return string.format("%.17g:%.17g", dev, btime)
end

-- One-shot bounded scan after a tick observed expanded directories disappear or
-- be replaced. Candidate parents are the root and every surviving expanded
-- directory (the reachability invariant guarantees a lost key's parent is in
-- that set); their real child directories are indexed by identity. Each topmost
-- lost key resolves to its unique identity match as a move, or is pruned when
-- there is no match, more than one match, or no usable identity. A descendant of
-- a lost key is covered by its ancestor's prefix remap, so only the shallowest
-- loss of each chain is searched. Returns `moves` (old -> new) and `prunes`.
local function poll_scan(scope, lost)
	local order = {}
	for u in pairs(lost) do
		order[#order + 1] = u
	end
	table.sort(order, function(a, b)
		if #a ~= #b then
			return #a < #b
		end
		return a < b
	end)

	-- Topmost losses only: ancestors sort first by path length.
	local topmost, wanted = {}, {}
	for _, u in ipairs(order) do
		local covered = false
		for _, t in ipairs(topmost) do
			if u == t or u:sub(1, #t + 1) == t .. "/" then
				covered = true
				break
			end
		end
		if not covered then
			topmost[#topmost + 1] = u
			local id = dir_identity(lost[u].dev, lost[u].btime)
			if id then
				wanted[id] = true
			end
		end
	end

	local parents, seen = {}, {}
	local known = { [scope.root] = true }
	local function add_parent(p)
		if p and not seen[p] then
			seen[p] = true
			parents[#parents + 1] = p
		end
	end
	add_parent(scope.root)
	for _, u in ipairs(scope.urls) do
		known[u] = true
		if not lost[u] then
			add_parent(u)
		end
	end

	-- Index real child directories by identity, excluding every URL the plugin
	-- already knows (an expanded key or the root): those cannot be the
	-- destination of a move. All candidate parents are read so a coincidental
	-- second match is seen and turns into a safe prune; symlinked/indirect
	-- directories are excluded for the same cycle-safety reason the rebuild
	-- refuses to descend them.
	local matches = {}
	for _, p in ipairs(parents) do
		local kids = fs.read_dir(Url(p), { resolve = true })
		if kids then
			for _, k in ipairs(kids) do
				local u = tostring(k.url)
				local cha = k.cha
				if
					not known[u]
					and cha
					and cha.is_dir
					and not cha.is_link
					and not cha.is_indirect
				then
					local id = dir_identity(cha.dev, cha.btime)
					if id and wanted[id] then
						local list = matches[id]
						if not list then
							list = {}
							matches[id] = list
						end
						list[#list + 1] = u
					end
				end
			end
		end
	end

	local moves, prunes = {}, {}
	for _, u in ipairs(topmost) do
		local id = dir_identity(lost[u].dev, lost[u].btime)
		local dest
		if id then
			local list = matches[id]
			if list and #list == 1 then
				dest = list[1]
			end
		end
		if dest and dest ~= u then
			moves[u] = dest
		else
			prunes[#prunes + 1] = u
		end
	end
	return next(moves) and moves or nil, #prunes > 0 and prunes or nil
end

-- One tick in the async context: read unfollowed metadata for every in-scope
-- expanded directory and compare it to the last successful snapshot. A missing
-- stat, a non-directory, a changed mtime/is_dir, or a changed (dev, btime) is a
-- real change; a directory seen for the first time only establishes its
-- baseline, so a fresh expansion never schedules a redundant rebuild. A lost or
-- replaced directory additionally enters the bounded identity scan above, and
-- the one hovered injected nested file is stat-followed so a content-only write
-- (which does not change the directory mtime) still refreshes the preview.
local function poll_tick(token, ctx)
	local scope = ctx.scope(token)
	if not scope then
		return false
	end
	-- A rebuild already re-reads disk; do not stack another one behind it.
	if scope.injecting then
		return true
	end
	local sig, dirty, lost = {}, false, {}
	for _, url_str in ipairs(scope.urls) do
		local stat = fs.cha(Url(url_str), false)
		local prev = scope.sig[url_str]
		if stat and stat.is_dir then
			if
				prev
				and prev.btime ~= nil
				and stat.btime ~= nil
				and (prev.dev ~= stat.dev or prev.btime ~= stat.btime)
			then
				-- Same path, different directory: a delete+recreate or overwrite.
				lost[url_str] = prev
			else
				sig[url_str] = { mtime = stat.mtime, is_dir = true, dev = stat.dev, btime = stat.btime }
				if prev and (prev.is_dir ~= true or prev.mtime ~= stat.mtime) then
					dirty = true
				end
			end
		elseif prev then
			-- Disappeared, replaced by a non-directory, or unreadable.
			lost[url_str] = prev
		end
	end
	local moves, prunes
	if next(lost) then
		moves, prunes = poll_scan(scope, lost)
		dirty = true
	end
	if scope.hover_file and scope.hover_file.mtime ~= nil then
		local stat = fs.cha(Url(scope.hover_file.url), true)
		if not stat or stat.is_dir then
			dirty = true
		elseif stat.mtime ~= scope.hover_file.mtime or stat.len ~= scope.hover_file.len then
			dirty = true
		end
	end
	local rebuilt, empty_expansion =
		ctx.apply(token, scope.gen, scope.tab, scope.root, sig, scope.visible, scope.hover_idx, dirty, moves, prunes)
	-- The last live expansion key was pruned: end the loop instead of waking once
	-- per interval for an empty scope. ctx.finish clears the handle afterwards.
	if rebuilt and empty_expansion then
		return false
	end
	return true
end

-- Start the single poll loop for the active tree session and return its
-- ya.async handle. `token` identifies the session; `ctx` carries the three
-- ya.sync bridges (scope, apply, finish) main.lua binds, so all plugin-state
-- access stays there. Runs in the async context.
function M.start(token, ctx)
	return ya.async(function()
		while true do
			ya.sleep(POLL_INTERVAL)
			if not poll_tick(token, ctx) then
				break
			end
		end
		ctx.finish(token)
	end)
end

return M
