-- Setup-installed reconciliation policy for externally-initiated filesystem
-- mutation events: rename/bulk-rename and remove/transfer. The handlers are
-- plain synchronous functions subscribed by main.lua with ps.sub; every read
-- and write of the plugin's mutable state stays behind the bounded controller
-- passed to bind(), so this module never performs filesystem writes and never
-- holds M. Compare operations.lua, which performs the plugin's own writes.

local M = {}

-- Absolute-URL, path-boundary-safe subtree tests come from the controller
-- (ctl.in_any_subtree, backed by roots.lua).

-- `rename` carries the originating tab id; nil means the event has no tab scope.
local function same_tab(tab)
	if tab == nil then
		return true
	end
	local id = cx.active.id
	if type(id) == "userdata" then
		id = id.value
	end
	return tonumber(tab) == id
end

-- Apply one (from, to) pair. Returns whether the injected hierarchy changes and
-- the remapped depth-0 order (nil when the plugin has no controlled order yet).
local function rename_one(ctl, from_str, to_str)
	local affected = false
	local order = ctl.root_order()
	if order then
		for _, u in ipairs(order) do
			if u == from_str then
				affected = true
				break
			end
		end
	end

	-- A renamed directory moves every expansion keyed below it, not just its
	-- own key; without this the orphaned descendant keys silently collapse the
	-- subtree and can resurrect stale expansion if the old URL returns.
	if ctl.remap_expanded_prefix(from_str, to_str) then
		affected = true
	end

	-- A rename inside an expanded subtree changes visible child rows even when
	-- no controlled key itself moved.
	for _, root in ipairs(ctl.expanded_keys()) do
		if ctl.in_any_subtree(from_str, { root }) or ctl.in_any_subtree(to_str, { root }) then
			affected = true
			break
		end
	end

	-- Preserve the renamed root's slot instead of re-deriving order from the
	-- already-mutated flat folder (which appends the upserted entry).
	local new_order
	if order then
		new_order = {}
		for i, u in ipairs(order) do
			new_order[i] = u == from_str and to_str or u
		end
	end

	return affected, new_order
end

-- Rename/bulk-rename: the injected rows and M.expanded are keyed by URL, so a
-- rename must remap metadata and rebuild before the hierarchy goes stale.
local function on_rename(ctl, payload)
	if not payload then
		return
	end
	local from_str = payload.from and tostring(payload.from)
	local to_str = payload.to and tostring(payload.to)
	if not from_str or not to_str then
		return
	end

	-- Saved per-root state of every tab is re-keyed regardless of which tab is
	-- active or whether it is in tree mode, so a rename performed from a classic
	-- tab cannot leave a tree tab's stale expansion keys pointing at the old URL.
	ya.dbg(
		"[tree-dbg] rename event from=",
		from_str,
		" to=",
		to_str,
		" tab=",
		tostring(payload.tab),
		" tabs=",
		ctl.count_keys_tabs()
	)
	local saved_touched = ctl.remap_saved(from_str, to_str)

	-- Live-state remap and the follow-up rebuild only apply when this event
	-- belongs to the active tree tab. `rename` carries the originating tab id.
	if not ctl.active_tree() or not same_tab(payload.tab) then
		if saved_touched then
			ya.dbg("[tree-dbg] rename saved-state re-key only; from=", from_str, " to=", to_str)
		end
		return
	end
	local affected, new_order = rename_one(ctl, from_str, to_str)
	if not affected then
		if saved_touched then
			ya.dbg("[tree-dbg] rename saved-state re-key; from=", from_str, " to=", to_str)
		end
		return
	end
	ya.dbg("[tree-dbg] rename ", from_str, " -> ", to_str)
	ctl.commit_mutation(to_str, nil, new_order)
end

local function on_bulk_rename(ctl, payload)
	if not payload then
		return
	end

	-- Build the simultaneous old-to-new map up front. Applying a payload
	-- pairwise through pairs() is order-dependent: swaps (A->B, B->A) and
	-- chains (A->B, B->C) would clobber each other's keys mid-iteration.
	local map = {}
	for from, to in pairs(payload) do
		map[tostring(from)] = tostring(to)
	end

	-- Saved per-root state of every tab is re-keyed against the same untouched
	-- map, including roots other than the active one, regardless of which tab is
	-- active or whether it is in tree mode. A bulk rename performed from a
	-- classic tab must not leave a tree tab's stale expansion keys behind.
	local saved_touched = ctl.remap_saved_bulk(map)

	-- Live-state remap and the follow-up rebuild only apply to the active tree
	-- tab (bulk-rename carries no tab id, so scope by the active tree mode).
	if not ctl.active_tree() then
		if saved_touched then
			ya.dbg("[tree-dbg] bulk-rename saved-state re-key only; pairs=", #map)
		end
		return
	end

	local function remap(url_str)
		return map[url_str] or url_str
	end

	-- Destination of one cwd-relative path under the simultaneous map. A
	-- directory move also carries every path beneath it, so the most specific
	-- mapped ancestor (longest cwd-relative `from` prefix) wins; resolving each
	-- original against the untouched map is what keeps swaps/chains
	-- order-independent.
	local function remap_rel(rel)
		local best_from, best_to, best_len
		for from_str, to_str in pairs(map) do
			if from_str ~= to_str then
				local from_rel = ctl.rel_of(from_str)
				local to_rel = ctl.rel_of(to_str)
				if from_rel and to_rel and from_rel ~= "" then
					local suffix
					if rel == from_rel then
						suffix = ""
					elseif rel:sub(1, #from_rel + 1) == from_rel .. "/" then
						suffix = rel:sub(#from_rel + 1)
					end
					if suffix and (not best_len or #from_rel > best_len) then
						best_from, best_to, best_len = from_rel, to_rel, #from_rel
					end
				end
			end
		end
		if not best_from then
			return nil
		end
		if best_from == rel then
			return best_to
		end
		return best_to .. rel:sub(#best_from + 1)
	end

	local touched = false

	-- Rebuild the controlled keys from a snapshot of their originals so every
	-- pair is remapped exactly once, independent of payload order.
	local expanded = ctl.expanded_keys()
	local cwd = ctl.cwd()
	local new_expanded = {}
	for _, url_str in ipairs(expanded) do
		local to_str = remap(url_str)
		if to_str == url_str then
			local rel = ctl.rel_of(url_str)
			local mapped = rel and remap_rel(rel) or nil
			if mapped then
				to_str = tostring(cwd:join(mapped))
			end
		end
		new_expanded[to_str] = true
		if to_str ~= url_str then
			touched = true
		end
	end

	local order = ctl.root_order()
	local new_root_order
	if order then
		new_root_order = {}
		for i, url_str in ipairs(order) do
			new_root_order[i] = remap(url_str)
			if new_root_order[i] ~= url_str then
				touched = true
			end
		end
	end

	-- A rename inside an expanded subtree changes visible child rows even when
	-- no controlled key itself moved. The original set is still live here: the
	-- replacement is only installed by commit_mutation below.
	if not touched then
		for from_str, to_str in pairs(map) do
			for _, root in ipairs(ctl.expanded_keys()) do
				if ctl.in_any_subtree(from_str, { root }) or ctl.in_any_subtree(to_str, { root }) then
					touched = true
					break
				end
			end
			if touched then
				break
			end
		end
	end

	if not touched then
		if saved_touched then
			ya.dbg("[tree-dbg] bulk-rename saved-state re-key only; pairs=", #map)
		end
		return
	end

	-- Deterministic focus: the smallest destination among the moved URLs, so
	-- the cursor does not depend on pairs() order.
	local dests = {}
	for from_str, to_str in pairs(map) do
		if to_str ~= from_str then
			dests[#dests + 1] = to_str
		end
	end
	table.sort(dests)
	local focus = dests[1]

	ya.dbg("[tree-dbg] bulk-rename applied; pairs=", #dests, " focus=", tostring(focus))
	ctl.commit_mutation(focus, new_expanded, new_root_order)
end

-- ---------------------------------------------------------------------------
-- Deletion (stock trash / permanent delete) and copy/move transfer. Native
-- remove already targets the selected-or-hovered URLs at any depth and keeps its
-- confirmation, task, and selection behavior; the plugin only reacts to the
-- successful completion events to prune the controlled hierarchy and rebuild.
-- ---------------------------------------------------------------------------

-- Bound handler factory: the two events differ only in their diagnostics label.
local function on_remove(ctl, kind)
	return function(payload)
		local urls = payload and payload.urls
		if type(urls) ~= "table" then
			return
		end

		local roots = {}
		local all_removed = {}
		local affected = false
		for _, u in ipairs(urls) do
			local u_str = tostring(u)
			all_removed[#all_removed + 1] = u_str
			local rel = ctl.rel_of(u_str)
			if rel and rel ~= "" then
				roots[#roots + 1] = u_str
				local parent = Url(u_str).parent
				local parent_str = parent and tostring(parent) or ""
				if ctl.active_tree() and ctl.is_tree_parent(parent_str) then
					affected = true
				end
			end
		end
		-- Saved per-root state of every tab is maintained regardless of which
		-- tab is active or whether it is in tree mode: a removal performed from
		-- a classic tab must still prune the stale expansion keys of a tree tab,
		-- or a directory later recreated at the same URL would resurrect them.
		-- Absolute-URL subtree tests, so roots other than the active one are
		-- covered too.
		local saved_touched = ctl.prune_saved(all_removed)
		if not affected then
			if saved_touched then
				ya.dbg("[tree-dbg] " .. kind .. " saved-state prune only; urls=" .. #all_removed)
			end
			return
		end

		local pruned_expanded, pruned_rows = ctl.prune_for_removal(roots)

		-- Focus anchor. Stock Yazi's removal keeps the cursor's slot index: a
		-- surviving hovered row stays put, otherwise the next surviving row
		-- shifts up into the deleted slot, and only an end-of-list delete clamps
		-- back to the previous row. Recreate that over the pre-change visible
		-- sequence by scanning forward from the hovered slot, then backward,
		-- skipping every removed subtree. There is deliberately no ancestor
		-- tier: a surviving parent is not stock's replacement for a deleted
		-- descendant. Candidates are resolved in order by M:focus, so one later
		-- hidden by the active tree filter is skipped.
		local h = ctl.hovered()
		local hovered_str = h and tostring(h.url) or nil
		local candidates, seen = {}, {}
		local function add_candidate(u)
			if u and not seen[u] then
				seen[u] = true
				candidates[#candidates + 1] = u
			end
		end

		local files = cx.active.current.files
		local idx = 0
		for i = 1, #files do
			if hovered_str and tostring(files[i].url) == hovered_str then
				idx = i
				break
			end
		end
		if idx == 0 then
			idx = (cx.active.current.cursor or 0) + 1
		end
		local function survivor(u)
			return ctl.rel_of(u) ~= nil and not ctl.in_any_subtree(u, all_removed)
		end
		for i = idx, #files do
			local u = tostring(files[i].url)
			if survivor(u) then
				add_candidate(u)
			end
		end
		for i = idx - 1, 1, -1 do
			local u = tostring(files[i].url)
			if survivor(u) then
				add_candidate(u)
			end
		end

		local focus = #candidates > 0 and candidates or nil

		ya.dbg(
			"[tree-dbg] "
				.. kind
				.. " event urls="
				.. #roots
				.. " pruned_expanded="
				.. pruned_expanded
				.. " pruned_rows="
				.. pruned_rows
				.. " focus="
				.. tostring(focus and focus[1])
		)
		ctl.commit_mutation(focus)
	end
end

-- Successful copy/move completion for an expanded (or cwd) branch: rebuild so
-- new children appear under their parent and moved-away rows disappear.
--
-- A move also removes the source path from the filesystem, so every tab's saved
-- roots are pruned for the moved-away `from` URLs regardless of the active tab's
-- mode; a duplicate only adds a destination and never invalidates saved state.
local function on_transfer(ctl, kind)
	return function(payload)
		local items = payload and payload.items
		if type(items) ~= "table" then
			return
		end

		-- Move: drop saved roots/expansion keys under every moved-away source,
		-- for every tab, before any active-tab routing.
		if kind == "move" then
			local froms = {}
			for _, item in ipairs(items) do
				if item.from then
					froms[#froms + 1] = tostring(item.from)
				end
			end
			if ctl.prune_saved(froms) then
				ya.dbg("[tree-dbg] move saved-state prune; froms=", #froms)
			end
		end

		if not ctl.active_tree() then
			return
		end

		local affected = false
		for _, item in ipairs(items) do
			for _, key in ipairs({ "from", "to" }) do
				local u = item[key]
				if u then
					local parent = Url(tostring(u)).parent
					local parent_str = parent and tostring(parent) or ""
					if ctl.is_tree_parent(parent_str) then
						affected = true
					end
				end
			end
			if affected then
				break
			end
		end
		if not affected then
			return
		end

		local h = ctl.hovered()
		local focus = h and tostring(h.url) or nil
		ya.dbg("[tree-dbg] transfer complete; kind=", kind, " items=", #items)
		ctl.commit_mutation(focus)
	end
end

-- One-time bind/interface for the domain controller. Returns the plain
-- synchronous handlers main.lua subscribes with ps.sub.
function M.bind(ctl)
	return {
		on_rename = function(payload)
			on_rename(ctl, payload)
		end,
		on_bulk_rename = function(payload)
			on_bulk_rename(ctl, payload)
		end,
		on_remove = function(kind)
			return on_remove(ctl, kind)
		end,
		on_transfer = function(kind)
			return on_transfer(ctl, kind)
		end,
	}
end

return M
