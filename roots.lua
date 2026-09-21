-- URL/remap/prune and saved-root reconciliation helpers for the live tree. This
-- module owns the pure URL helpers and every per-tab/per-root remap, prune, and
-- saved-state operation. The live plugin state is reached only through the bound
-- accessor passed to bind() (installed once from main.lua's M:setup), so this
-- module never holds M -- the same no-M contract as events.lua and poller.lua.
-- The table accessors return the live references (never copies), so
-- prune_expanded and remap_expanded_prefix keep mutating the live expansion set
-- in place.

local M = {}

-- Bound once by main.lua; every stateful helper below reads and writes the live
-- plugin state through these closures.
local S

function M.bind(accessors)
	S = accessors
end

-- cwd-relative path of an absolute URL string, or nil when it is outside the
-- current tree root. Used for path-boundary-safe subtree comparisons.
local function rel_of(url_str)
	local rel = Url(url_str):strip_prefix(S.cwd())
	return rel and tostring(rel) or nil
end

-- ---------------------------------------------------------------------------
-- Pure URL helpers.
-- ---------------------------------------------------------------------------

-- Absolute-URL, path-boundary-safe subtree membership.
function M.in_any_subtree(url_str, roots)
	for _, r in ipairs(roots) do
		if url_str == r or url_str:sub(1, #r + 1) == r .. "/" then
			return true
		end
	end
	return false
end

-- Absolute-URL re-key for saved per-root state. Unlike remap_expanded_prefix
-- this never consults the active cwd, so it can address the saved sets of roots
-- other than the active one. `url_str` outside the moved subtree is unchanged.
function M.remap_abs(url_str, from_str, to_str)
	if url_str == from_str then
		return to_str
	end
	local prefix = from_str .. "/"
	if url_str:sub(1, #prefix) == prefix then
		return to_str .. url_str:sub(#from_str + 1)
	end
	return url_str
end

-- Simultaneous absolute-URL resolution for a bulk-rename map: the most specific
-- mapped ancestor wins, so swaps and chains stay order-independent.
function M.remap_abs_bulk(map, url_str)
	local best_from, best_to, best_len
	for from_str, to_str in pairs(map) do
		if from_str ~= to_str then
			if url_str == from_str then
				return to_str
			end
			if url_str:sub(1, #from_str + 1) == from_str .. "/" then
				if not best_len or #from_str > best_len then
					best_from, best_to, best_len = from_str, to_str, #from_str
				end
			end
		end
	end
	if not best_from then
		return url_str
	end
	return best_to .. url_str:sub(#best_from + 1)
end

-- Re-keyed copy of an expansion key set under `resolve`, computed against the
-- untouched original keys so a swap/chain cannot resolve twice. Returns the new
-- set plus whether any key actually moved.
function M.remap_key_set(exp, resolve)
	local out, moved = {}, false
	for k in pairs(exp) do
		local nk = resolve(k)
		if nk ~= k then
			moved = true
		end
		out[nk] = true
	end
	return out, moved
end

-- Re-keyed copy of a root-order list under `resolve`.
function M.remap_list(order, resolve)
	local out = {}
	for i, v in ipairs(order) do
		out[i] = resolve(v)
	end
	return out
end

function M.copy_set(s)
	local o = {}
	for k in pairs(s) do
		o[k] = true
	end
	return o
end

function M.copy_list(l)
	if not l then
		return nil
	end
	local o = {}
	for i, v in ipairs(l) do
		o[i] = v
	end
	return o
end

-- ---------------------------------------------------------------------------
-- Per-tab / per-root saved state. Yazi restores a cached Folder (including the
-- injected descendant rows) before it emits `cd`, and the event carries only the
-- new tab/root, so the plugin tracks the outgoing root itself and saves its live
-- state before replacing it.
-- ---------------------------------------------------------------------------

-- Save a tree tab's live state under the root it currently describes. Called at
-- activation for the outgoing tab, at on_cd before any load, and from toggle-off
-- so the hierarchy survives a normal-mode interlude. Classic tabs save nothing:
-- their roots map stays frozen and their live set is always empty.
function M.save_live(id)
	local t = S.tabs()[id]
	if not t or not t.tree or not t.root or t.root == "" then
		return
	end
	local any = next(S.expanded()) ~= nil
		or S.root_order() ~= nil
		or (S.filter_query() ~= nil and S.filter_query() ~= "")
	t.roots[t.root] = any and {
		expanded = M.copy_set(S.expanded()),
		order = M.copy_list(S.root_order()),
		filter = S.filter_query(),
	} or nil
end

-- Load a tab's frozen root state into the live working set. A classic tab always
-- loads an empty live set, so its roots map is never consulted while tree is off.
function M.load_roots(t, root)
	local st = t and t.tree and t.roots[root] or nil
	S.set_expanded(st and M.copy_set(st.expanded) or {})
	S.set_root_order(st and M.copy_list(st.order) or nil)
	S.set_filter_query(st and st.filter or nil)
	S.set_rows({})
end

-- ---------------------------------------------------------------------------
-- Remap / prune of the saved per-root state and the live controlled state.
-- ---------------------------------------------------------------------------

-- Apply `resolve` to every tab's saved roots, saved expansion keys, and saved
-- root-order entries, plus each tab's last-seen root. Collected first, then
-- re-keyed, so swaps/chains resolve against the untouched originals. Every tab
-- is visited, not just the active one, so a mutation performed from a classic
-- tab can never leave a tree tab's frozen roots pointing at a moved URL.
--
-- A root's *own* URL usually does not move when a path inside it is renamed, so
-- the expansion keys and root order of every root are re-keyed independently of
-- whether that root itself was re-keyed.
function M.remap_saved_generic(resolve)
	local changed = false
	for _, t in pairs(S.tabs()) do
		local saved_roots = t.roots

		-- Snapshot every (root, state) pair and resolve it against the untouched
		-- originals before writing anything back, so a swap (A->B, B->A) or a
		-- chain (A->B, B->C) cannot clobber its own source mid-iteration.
		local entries = {}
		for root, state in pairs(saved_roots) do
			local new_keys, keys_moved
			if state and state.expanded then
				new_keys, keys_moved = M.remap_key_set(state.expanded, resolve)
			end
			entries[#entries + 1] = {
				root = root,
				state = state,
				new_root = resolve(root),
				new_keys = new_keys,
				keys_moved = keys_moved,
				new_order = state and state.order and M.remap_list(state.order, resolve) or nil,
			}
		end
		for _, e in ipairs(entries) do
			saved_roots[e.root] = nil
		end
		for _, e in ipairs(entries) do
			if e.new_root ~= e.root or e.keys_moved then
				changed = true
			end
			local state = e.state
			if state then
				if e.new_keys then
					state.expanded = e.new_keys
				end
				if e.new_order then
					state.order = e.new_order
				end
			end
			saved_roots[e.new_root] = state
		end

		if t.root then
			local new_root = resolve(t.root)
			if new_root ~= t.root then
				t.root = new_root
				changed = true
			end
		end
	end
	return changed
end

function M.remap_saved(from_str, to_str)
	return M.remap_saved_generic(function(u)
		return M.remap_abs(u, from_str, to_str)
	end)
end

function M.remap_saved_bulk(map)
	return M.remap_saved_generic(function(u)
		return M.remap_abs_bulk(map, u)
	end)
end

-- Drop saved roots inside any removed URL, saved expansion keys inside them, and
-- the matching last-seen root of any tab. Absolute-URL tests, because a removed
-- URL may belong to a saved root other than the active one.
function M.prune_saved(roots)
	local changed = false
	for _, t in pairs(S.tabs()) do
		local saved_roots = t.roots
		local drop = {}
		for root, state in pairs(saved_roots) do
			if M.in_any_subtree(root, roots) then
				drop[#drop + 1] = root
			elseif state and state.expanded then
				for k in pairs(state.expanded) do
					if M.in_any_subtree(k, roots) then
						state.expanded[k] = nil
						changed = true
					end
				end
			end
		end
		for _, root in ipairs(drop) do
			saved_roots[root] = nil
			changed = true
		end
		if t.root and M.in_any_subtree(t.root, roots) then
			t.root = nil
			changed = true
		end
	end
	return changed
end

-- Forget `target` and every expanded directory inside its subtree, comparing
-- cwd-relative paths so collapsing "a/b" never matches "a/bc".
function M.prune_expanded(target_str)
	local cwd = S.cwd()
	local target_rel = tostring(Url(target_str):strip_prefix(cwd) or "")
	if target_rel == "" then
		return false
	end
	local prefix = target_rel .. "/"
	local removed = false
	for u in pairs(S.expanded()) do
		local rel = tostring(Url(u):strip_prefix(cwd) or "")
		if rel == target_rel or rel:sub(1, #prefix) == prefix then
			S.expanded()[u] = nil
			removed = true
		end
	end
	return removed
end

-- Re-key every expanded directory inside the moved subtree of a single
-- `from_str -> to_str` rename, comparing cwd-relative paths so `alpha/bc` is
-- never rewritten by a rename of `alpha/b`. A move out of the tree root prunes
-- the subtree instead, since those keys can never be reachable again. Returns
-- true when a key moved or was pruned.
function M.remap_expanded_prefix(from_str, to_str)
	local cwd = S.cwd()
	local from_rel = rel_of(from_str)
	if not from_rel or from_rel == "" then
		return false
	end
	local to_rel = rel_of(to_str)
	local from_prefix = from_rel .. "/"
	local updates = {}
	for u in pairs(S.expanded()) do
		local rel = rel_of(u)
		if rel then
			local suffix
			if rel == from_rel then
				suffix = ""
			elseif rel:sub(1, #from_prefix) == from_prefix then
				suffix = rel:sub(#from_prefix + 1)
			end
			if suffix then
				local new_url
				if to_rel and to_rel ~= "" and to_rel ~= from_rel then
					local new_rel = suffix == "" and to_rel or (to_rel .. "/" .. suffix)
					new_url = tostring(cwd:join(new_rel))
				end
				updates[#updates + 1] = { old = u, new = new_url }
			end
		end
	end
	for _, pair in ipairs(updates) do
		S.expanded()[pair.old] = nil
		if pair.new then
			S.expanded()[pair.new] = true
		end
	end
	return #updates > 0
end

-- Forget every M.rows entry for `target_str` or inside its subtree, with the
-- same cwd-relative, path-boundary-safe comparison as prune_expanded.
function M.prune_rows(target_str)
	local cwd = S.cwd()
	local target_rel = tostring(Url(target_str):strip_prefix(cwd) or "")
	if target_rel == "" then
		return false
	end
	local prefix = target_rel .. "/"
	local removed = false
	for u in pairs(S.rows()) do
		local rel = tostring(Url(u):strip_prefix(cwd) or "")
		if rel == target_rel or rel:sub(1, #prefix) == prefix then
			S.rows()[u] = nil
			removed = true
		end
	end
	return removed
end

-- Snapshot of the controlled expansion keys. The module rebuilds whole sets, so
-- it reads a plain list and hands the replacement back through commit_mutation.
function M.expanded_keys()
	local out = {}
	for url_str in pairs(S.expanded()) do
		out[#out + 1] = url_str
	end
	return out
end

-- Snapshot of the depth-0 URL order (nil when the plugin has none yet).
function M.root_order_snapshot()
	local order = S.root_order()
	if not order then
		return nil
	end
	local out = {}
	for i, url_str in ipairs(order) do
		out[i] = url_str
	end
	return out
end

-- Prune the controlled hierarchy for every removed root and report how many
-- expansion keys and visible-row entries were dropped.
function M.prune_for_removal(roots)
	local pruned_expanded, pruned_rows = 0, 0
	for _, u_str in ipairs(roots) do
		if M.prune_expanded(u_str) then
			pruned_expanded = pruned_expanded + 1
		end
		if M.prune_rows(u_str) then
			pruned_rows = pruned_rows + 1
		end
	end
	return pruned_expanded, pruned_rows
end

return M
