--- @since 26.9.1
--- @sync entry
--- Live recursive tree: lazily expand/collapse directories at any depth in
--- place while keeping Yazi's native Folder cursor, hover, and file entities.

local M = {}

-- Installed by M:setup (async init.lua context); redraw paths are unreachable
-- without setup, so direct lazy `@sync entry` actions never see it as nil.
local render

-- Raw module table for the async rebuild pass, resolved on the first rebuild
-- from inside the existing async context (same raw-cache pattern as render).
local rebuild_pass

-- Raw module table for the async create/rename mutation passes, resolved on
-- first use from inside their existing async contexts (same raw-cache pattern).
local operations

-- Raw module table for the setup-installed mutation event handlers, resolved
-- lazily inside the async init.lua context (same raw-cache pattern).
local events

-- ---------------------------------------------------------------------------
-- Layout toggles (tree/preview) — unchanged behavior.
-- ---------------------------------------------------------------------------

-- Base ratio captured from rt.mgr.ratio while the active tab is idle (tree off,
-- preview on), plus the startup defaults newly observed tabs are seeded from.
-- Mode state itself lives per tab in M.tabs; there is no bare global flag.
local base
local startup_defaults = { tree = false, preview = true }

local function tab_state(id)
	return M.tabs[id or M.active_tab]
end

-- Native fd/rg provider View. Yazi cds the tab to a `fd://`/`rg://` URL and
-- streams provider results as the Folder, so every tree path (renderer, actions,
-- events) must delegate to stock behavior there: the provider rows, stock `f`
-- filtering, and stock EscapeView (which cds back to the physical root) all
-- stay untouched. Recognized purely from a cwd scheme.
local function is_search_url(url_str)
	return url_str:sub(1, 5) == "fd://" or url_str:sub(1, 5) == "rg://"
end

local function native_search_view()
	return is_search_url(tostring(cx.active.current.cwd))
end

-- Renderer/header/action routing authority. Before any lifecycle handler has
-- observed a tab (the very first frame of a startup launch) fall back to the
-- configured startup default so the first paint is already tree-shaped. A
-- native search View is never a tree View, regardless of the tab's recorded
-- mode, so it delegates to stock Yazi everywhere.
local function active_tree()
	if native_search_view() then
		return false
	end
	local t = tab_state()
	if t then
		return t.tree == true
	end
	return startup_defaults.tree == true
end

local function capture_base()
	local r = rt.mgr.ratio
	base = { r[1], r[2], r[3] }
	ya.dbg("[tree-dbg] captured base ratio=", base[1], base[2], base[3])
end

-- A tab is idle (tree off, preview on) when its live ratio already equals the
-- canonical base, so an external ratio change observed now (manual config,
-- toggle-pane, etc.) is safe to adopt as the new base.
local function is_idle(t)
	return t ~= nil and not t.tree and t.preview
end

local function sync_base()
	if is_idle(tab_state()) then
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
	local t = tab_state()
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

-- Original preset Header.flags, captured once so setup() stays idempotent.
local saved_header_flags

-- ---------------------------------------------------------------------------
-- Tree state (module table so it survives across entry calls).
-- ---------------------------------------------------------------------------

M.expanded = {} -- set keyed by directory URL string, at any depth
M.rows = {} -- per-URL metadata: { depth, last, cont } for injected rows
M.gen = 0 -- generation, bumped by every sync user action
M.pending_focus = nil -- URL string (or ordered candidate list) to reposition onto
M.injected = false -- whether the last completed rebuild injected descendants
M.injecting = false -- a rebuild is scheduled or in flight (not yet completed)
M.root_order = nil -- authoritative depth-0 URL order (kept across rebuilds/rename)
M.filter_query = nil -- active hierarchy-aware tree filter query; nil shows every row
M.dir_sig = {} -- url -> { mtime, is_dir }: last successful expanded-dir metadata
M.poller = nil -- ya.async Handle of the active external-change poll loop
M.poller_token = nil -- identity of the loop M.poller currently refers to

-- Per-tab / per-root persistence. M.expanded/M.rows/M.root_order/M.filter_query
-- stay the live state for the active tab, while M.tabs owns everything that must
-- survive a tab switch: the tab's tree/preview modes, its sort/native-filter
-- handoff, its last-seen root, and its per-root expansion/order/tree-filter map.
-- Yazi restores a whole cached Folder (with the plugin's injected rows) on cd,
-- and `update_files` always targets the active tab, so the plugin must save the
-- outgoing tab itself and reconcile the incoming one against its saved set.
M.active_tab = nil -- numeric id of the tab M.expanded/M.rows describe
M.tabs = {} -- [tab_id] = { tree, preview, sort_saved, suspended_filter, root, roots }
-- roots[root_url] = { expanded=set, order=list|nil, filter=string|nil }

-- Tab ids arrive either as a Lua number or a userdata Id wrapper, from
-- cx.active.id and from the `cd`/`tab` event payloads.
local function id_num(id)
	if type(id) == "userdata" then
		id = id.value
	end
	return tonumber(id)
end

local function active_id()
	return id_num(cx.active.id)
end

-- cwd of an arbitrary (possibly inactive) tab, looked up by numeric id. Used by
-- the cd handler to record a background tab's new root without touching the
-- live state the plugin is rendering for the active tab.
local function tab_cwd(id)
	for i = 1, #cx.tabs do
		local tab = cx.tabs[i]
		if id_num(tab.id) == id then
			return tostring(tab.current.cwd)
		end
	end
	return nil
end

-- Native filtering is suspended for the whole injected-tree lifetime: a live
-- Entries filter is re-applied to every injected row and can orphan a child
-- from a hidden parent. The raw query is kept on the owning tab (t.suspended_filter)
-- so `suspend` can restore it and `adopt` can decide whether to hand the tree
-- query back, without bleeding between tabs.
-- How a native filter is transferred into (and out of) tree mode:
-- "adopt"   - apply it as the hierarchy-aware query, restore it on exit;
-- "suspend" - hide its effect while tree mode is on, restore it on exit;
-- "clear"   - discard it for good.
local filter_mode = "adopt"

-- Injection tickets must never collide with the folder loader's own tickets,
-- which start at 1 and increment per folder load, or a late loader op can
-- invalidate an injection.
M.seq = 1000000000

-- Per-tab sort handoff lives on M.tabs[id].sort_saved (see capture_sort below);
-- no process-global pin state.
local cd_subscribed = false
local tab_subscribed = false
local mutate_subscribed = false
local preflight_subscribed = false
local transfer_subscribed = false
local remove_subscribed = false

-- SortForm fields accepted by the `sort` action, captured for restoration.
local SORT_FIELDS = { "by", "reverse", "dir_first", "sensitive", "translit", "fallback" }

local function capture_sort()
	local p = cx.active.pref
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
-- entries. The configured sort is captured on the tab itself, never globally.
-- The live preference is re-checked on every call: a tab created with an
-- explicit target does not clone the creator's pinned `none` pref (it starts
-- from the configured sort) even though ensure_tab copies the creator's
-- sort_saved, so an early return on sort_saved alone would leave that tab's
-- live sorter reordering the injected rows.
local function pin_sort_for(t)
	if not t then
		return
	end
	if native_search_view() then
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
	if native_search_view() then
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

-- Preflight `key-sort`: while the active tab is in tree mode the flat Entries
-- list must stay unsorted or the injected hierarchy interleaves. Record what the
-- user asked for on the tab (so toggle-off restores it) and force by=none in
-- place.
local function on_key_sort(form)
	if not active_tree() then
		return form
	end
	local t = tab_state()
	if not t then
		return form
	end
	if not t.sort_saved then
		t.sort_saved = capture_sort()
	end
	for _, field in ipairs(SORT_FIELDS) do
		if form[field] ~= nil then
			t.sort_saved[field] = form[field]
		end
	end
	form.by = "none"
	ya.dbg("[tree-dbg] sort request captured; forcing by=none")
	return form
end

-- Preflight `key-hidden`: runs before Hidden::act, so the queued reassert is
-- processed after the hide/show change and rebuilds the controlled ordering.
local function on_key_hidden(form)
	if not active_tree() then
		return form
	end
	ya.dbg("[tree-dbg] hidden toggle; scheduling reassert")
	ya.emit("plugin", { "tree", "reassert" })
	return form
end

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

-- Depth-0 url order as currently displayed; used only to seed M.root_order.
local function capture_root_order()
	local order = {}
	for _, f in ipairs(cx.active.current.files) do
		order[#order + 1] = tostring(f.url)
	end
	return order
end

-- Code-point count without the utf8 library: counts bytes that are not UTF-8
-- continuation bytes, so multibyte names offset correctly (invalid UTF-8 is
-- approximated rather than matching Rust's lossy replacement).
local function char_count(s)
	return select(2, s:gsub("[^\128-\191]", ""))
end

-- Stock `rename --cursor=before_ext` places the caret at the char index of the
-- last '.' for regular files, unless that index is 0. The popup opens with the
-- caret at end-of-value, so return the negative offset to emit.
local function before_ext_move(name, regular)
	if not regular then
		return nil
	end
	local dot = name:match("[\0-\255]*()%.")
	if not dot or dot == 1 then
		return nil
	end
	return -char_count(name:sub(dot))
end

-- Regular file test mirroring stock `hovered.is_file()`: directories, links,
-- and special files all keep the default end-of-value rename caret.
local function is_regular(cha)
	if not cha then
		return false
	end
	return not (
		cha.is_dir
		or cha.is_link
		or cha.is_indirect
		or cha.is_fifo
		or cha.is_sock
		or cha.is_block
		or cha.is_char
	)
end

-- ---------------------------------------------------------------------------
-- Native filter hand-off. Yazi's own Entries filter is a regex applied to every
-- injected row by Entries::split_files, so a live native filter would
-- double-filter the tree and can hide an ancestor while keeping its child.
-- Before any injection the plugin takes ownership: read the raw native query,
-- clear native filtering through `filter_do`, then adopt it into
-- hierarchy-aware matching, suspend it for later restore, or discard it.
-- ---------------------------------------------------------------------------

-- Transfer any live native filter. Idempotent: once cleared, the Folder reports
-- no filter and later calls are no-ops for the rest of the tree-mode session.
-- Returns true when a query was taken over.
local function capture_native_filter()
	local flt = cx.active.current.files.filter
	local q = flt and tostring(flt) or nil
	if not q or q == "" then
		return false
	end
	ya.emit("filter_do", { "" })
	if filter_mode == "adopt" then
		M.filter_query = q
	elseif filter_mode == "suspend" then
		local t = tab_state()
		if t then
			t.suspended_filter = q
		end
	end
	ya.dbg("[tree-dbg] native filter transferred; mode=", filter_mode, " query=", q)
	return true
end

-- Hand native filtering back when tree mode ends. Adopt restores the current
-- effective tree query (smart case, like the stock `filter --smart` binding),
-- suspend restores the query saved on this tab, clear restores nothing. `query`
-- is the effective tree query captured just before M.filter_query was reset.
local function restore_native_filter(query)
	local t = tab_state()
	local q
	if filter_mode == "adopt" then
		q = query
	elseif filter_mode == "suspend" then
		q = t and t.suspended_filter or nil
	end
	if t then
		t.suspended_filter = nil
	end
	if q and q ~= "" then
		ya.emit("filter_do", { q, smart = true })
		ya.dbg("[tree-dbg] native filter restored; mode=", filter_mode, " query=", q)
	else
		ya.dbg("[tree-dbg] native filter not restored; mode=", filter_mode)
	end
end

-- ---------------------------------------------------------------------------
-- Rebuild: async read of the root and every expanded directory, then a single
-- FilesOp reset + append + done injection into the active Folder.
-- ---------------------------------------------------------------------------

-- Stale guard: the async callback must not reset a folder owned by a newer
-- generation, and it must still belong to the tab it was captured for, because
-- `update_files` always targets the active tab. Runs in the sync context
-- (ya.sync) with access to M.
local check_gen = ya.sync(function(_, gen, tab)
	return M.gen == gen and M.active_tab == tab
end)

-- The realtime filter stream runs in the async context and cannot touch `cx`,
-- so hand the query to the sync context through this bridge.
local set_filter_query = ya.sync(function(_, query)
	M.filter_query = query
end)

-- Record the pruned depth-0 order observed by a completed rebuild so a later
-- rename event can remap a root's slot in place.
local set_root_order = ya.sync(function(_, gen, tab, order)
	if M.gen == gen and M.active_tab == tab then
		M.root_order = order
	end
end)

-- Publish the per-row metadata (depth, last-sibling, ancestor continuation)
-- produced by the flatten, keyed by URL string, for the renderer and the
-- target-aware operations.
local set_rows = ya.sync(function(_, gen, tab, rows)
	if M.gen == gen and M.active_tab == tab then
		M.rows = rows or {}
	end
end)

-- Reconcile the live expansion set with what a completed rebuild actually
-- reached. A key whose chain of expanded ancestors no longer leads to it is
-- stale, so it is dropped here: the old URL becomes a tombstone and a directory
-- later recreated there cannot silently auto-expand. Keys under a directory
-- whose read failed are retained by the caller because that subtree is
-- unverifiable, not proven gone. Same generation/tab gate as every other
-- rebuild bridge, so a superseded rebuild cannot clobber newer user state.
local set_expanded = ya.sync(function(_, gen, tab, retained)
	if M.gen == gen and M.active_tab == tab then
		local new = {}
		for _, u in ipairs(retained) do
			new[u] = true
		end
		M.expanded = new
		-- Drop signatures for pruned keys so the next poll does not report a
		-- spurious change for a directory the plugin no longer tracks.
		for u in pairs(M.dir_sig) do
			if not new[u] then
				M.dir_sig[u] = nil
			end
		end
	end
end)

-- Completion marker: only the generation and tab that still own the folder may
-- clear the pending flag and record whether descendants are now injected. A
-- failed read passes nil and only clears the in-flight flag, or every later
-- toggle-off thinks a rebuild is still pending forever.
local finish_rebuild = ya.sync(function(_, gen, tab, injected)
	if M.gen == gen and M.active_tab == tab then
		M.injecting = false
		if injected ~= nil then
			M.injected = injected
		end
	end
end)

local function rebuild(gen, focus_str, pin)
	local tab = M.active_tab or active_id()
	if not tab then
		return
	end
	-- The provider owns a native search View's Folder: never read it back into
	-- the injected hierarchy or reset it (which would wipe the streamed rows).
	if native_search_view() then
		ya.dbg("[tree-dbg] rebuild skipped; native search view")
		return
	end
	M.active_tab = tab

	if pin ~= false then
		pin_sort_for(tab_state(tab))
	end

	-- Take ownership of any native filter before reading the visible set: it
	-- must stay off for the whole injected-tree lifetime, or injected rows get
	-- re-filtered by urn and children can outlive their hidden parent.
	capture_native_filter()

	local cwd_str = tostring(cx.active.current.cwd)

	-- Keep the per-tab root tracking current even when the plugin acts without
	-- a preceding cd (for example the first expansion after toggle-on).
	local t = tab_state(tab)
	if t then
		t.root = cwd_str
	end

	local expanded = {}
	for url_str in pairs(M.expanded) do
		expanded[#expanded + 1] = url_str
	end
	table.sort(expanded)

	if not M.root_order then
		M.root_order = capture_root_order()
	end
	local root_order = M.root_order
	local filter = M.filter_query

	local ticket = M.seq
	M.seq = M.seq + 1
	local injected = #expanded > 0
	M.pending_focus = focus_str
	M.injecting = true
	-- Transient row metadata is owned by the flatten below: clearing it here
	-- keeps a re-keyed expansion set from rendering against stale rows until
	-- the rebuild publishes its own snapshot.
	M.rows = {}

	ya.dbg(
		"[tree-dbg] rebuild gen=",
		gen,
		"ticket=",
		ticket,
		"expanded=",
		#expanded,
		"filter=",
		tostring(filter),
		"focus=",
		tostring(focus_str)
	)

	ya.async(function()
		if not rebuild_pass then
			require("tree.rebuild") -- async context: safe here
			-- Raw module table: plain sync entry, no require-proxy wrapper.
			rebuild_pass = package.loaded["tree.rebuild"]
		end
		rebuild_pass.run({
			gen = gen,
			tab = tab,
			cwd_str = cwd_str,
			expanded = expanded,
			root_order = root_order,
			filter = filter,
			ticket = ticket,
			injected = injected,
			focus_str = focus_str,
			check_gen = check_gen,
			set_root_order = set_root_order,
			set_rows = set_rows,
			set_expanded = set_expanded,
			finish_rebuild = finish_rebuild,
		})
	end)
end

-- ---------------------------------------------------------------------------
-- Header indication: Yazi's stock Header renders "(filter: query)" solely from
-- the native Entries filter, which the plugin keeps cleared while it owns
-- hierarchy-aware filtering. Conditionally wrap Header:flags so the active tree
-- query shows beside the cwd in the stock style/placement; every other case
-- (tree mode off, no tree query) delegates to the untouched renderer.
-- ---------------------------------------------------------------------------

local function install_header_filter()
	if saved_header_flags or not (Header and Header.flags) then
		return
	end
	saved_header_flags = Header.flags
	Header.flags = function(self)
		local q = active_tree() and M.filter_query or nil
		if not q or q == "" then
			return saved_header_flags(self)
		end
		-- Feed the stock renderer the plugin-owned query through the same field
		-- it reads for native filtering, so the indicator's text, style, and
		-- placement match exactly.
		return saved_header_flags({
			_current = { cwd = self._current.cwd, files = { filter = q } },
			_tab = self._tab,
		})
	end
end

-- ---------------------------------------------------------------------------
-- Key routing
-- ---------------------------------------------------------------------------

local function hovered()
	return cx.active.current.hovered
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

-- cwd-relative path of an absolute URL string, or nil when it is outside the
-- current tree root. Used for path-boundary-safe subtree comparisons.
local function rel_of(url_str)
	local rel = Url(url_str):strip_prefix(cx.active.current.cwd)
	return rel and tostring(rel) or nil
end

-- ---------------------------------------------------------------------------
-- Per-tab / per-root state. Yazi restores a cached Folder (including the
-- injected descendant rows) before it emits `cd`, and the event carries only the
-- new tab/root, so the plugin tracks the outgoing root itself and saves its live
-- state before replacing it.
-- ---------------------------------------------------------------------------

local function copy_set(s)
	local o = {}
	for k in pairs(s) do
		o[k] = true
	end
	return o
end

local function copy_list(l)
	if not l then
		return nil
	end
	local o = {}
	for i, v in ipairs(l) do
		o[i] = v
	end
	return o
end

-- Bounded diagnostic helper: how many keys a state table currently holds.
local function count_keys(t)
	local n = 0
	for _ in pairs(t or {}) do
		n = n + 1
	end
	return n
end

-- Save a tree tab's live state under the root it currently describes. Called at
-- activation for the outgoing tab, at on_cd before any load, and from toggle-off
-- so the hierarchy survives a normal-mode interlude. Classic tabs save nothing:
-- their roots map stays frozen and their live set is always empty.
local function save_live(id)
	local t = M.tabs[id]
	if not t or not t.tree or not t.root or t.root == "" then
		return
	end
	local any = next(M.expanded) ~= nil or M.root_order ~= nil or (M.filter_query ~= nil and M.filter_query ~= "")
	t.roots[t.root] = any and {
		expanded = copy_set(M.expanded),
		order = copy_list(M.root_order),
		filter = M.filter_query,
	} or nil
end

-- Load a tab's frozen root state into the live working set. A classic tab always
-- loads an empty live set, so its roots map is never consulted while tree is off.
local function load_roots(t, root)
	local st = t and t.tree and t.roots[root] or nil
	M.expanded = st and copy_set(st.expanded) or {}
	M.root_order = st and copy_list(st.order) or nil
	M.filter_query = st and st.filter or nil
	M.rows = {}
end

-- Regenerate M.rows for the rows already displayed, without a filesystem read.
-- Same math as redraw_tree's fallback, plus the parent URL M:left needs.
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
	M.rows = rows
end

-- Synchronously remove restored descendant rows when the live expansion set is
-- empty. Emits the same part/part/done sequence rebuild uses, but reuses the
-- current Folder's depth-0 File userdata, so no filesystem read is needed and no
-- phantom row outlives on_cd.
local function strip_descendants_sync()
	local files, cwd = cx.active.current.files, cx.active.current.cwd
	local cwd_str = tostring(cwd)
	local real = {}
	for i = 1, #files do
		local rel = files[i].url:strip_prefix(cwd)
		if rel and not tostring(rel):find("/", 1, true) then
			real[#real + 1] = files[i]
		end
	end
	local ticket = M.seq
	M.seq = M.seq + 1
	ya.emit("update_files", { op = fs.op("part", { id = ticket, url = Url(cwd_str), files = {} }) })
	ya.emit("update_files", { op = fs.op("part", { id = ticket, url = Url(cwd_str), files = real }) })
	ya.emit("update_files", {
		op = fs.op("done", { id = ticket, file = cx.active.current.file }),
	})
	M.injected, M.injecting = false, false
end

-- Make the live expansion set and the displayed rows agree in this handler, then
-- optionally re-flatten from disk. When the restored set is empty but the Folder
-- still carries injected descendants they are stripped synchronously; when
-- expansions exist the existing generation-checked rebuild validates the keys
-- and rereads disk (so `h`/`l` never observe expanded rows with an empty state).
local function reconcile_root()
	-- A native provider View must never be stripped or rehydrated: its rows are
	-- the provider's stream, not the plugin's injected hierarchy.
	if native_search_view() then
		return
	end
	M.pending_focus = nil
	local exp, has = next(M.expanded) ~= nil, has_descendants()
	if has and not exp then
		ya.dbg("[tree-dbg] reconcile strip; root=", tostring(cx.active.current.cwd))
		strip_descendants_sync()
		rehydrate_rows()
	else
		rehydrate_rows()
		M.injected, M.injecting = exp, false
		if exp then
			M.gen = M.gen + 1
			rebuild(M.gen, nil)
		end
	end
	ui.render()
end

-- A freshly activated tree tab starts with an empty expansion set and no
-- captured root order. Yazi's folder load normally applies the configured sort,
-- but when that configured sort is `none` (or was otherwise suppressed) the
-- listing is left in raw read_dir order, and a pinned `none` sorter will not
-- reorder it. Seed an explicit directories-first alphabetical root order from
-- the folder's real depth-0 children and rebuild once, so the fresh listing is
-- deterministic. Only when there is no captured order and nothing expanded;
-- native provider Views and an unloaded (or empty) folder are skipped. Returns
-- true when the folder rows were available to seed from.
local function seed_root_order()
	if native_search_view() then
		return true
	end
	if M.root_order ~= nil or next(M.expanded) ~= nil then
		return true
	end
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
		return false
	end
	table.sort(files, function(a, b)
		local ad = a.cha and a.cha.is_dir and true or false
		local bd = b.cha and b.cha.is_dir and true or false
		if ad ~= bd then
			return ad
		end
		return tostring(a.name) < tostring(b.name)
	end)
	local order = {}
	for i, f in ipairs(files) do
		order[i] = tostring(f.url)
	end
	M.root_order = order
	M.gen = M.gen + 1
	ya.dbg("[tree-dbg] seeded root order; entries=", #order)
	-- Pin here rather than in activate: the tab kept its configured sorter
	-- until the seeded directories-first rows are ready. rebuild pins
	-- synchronously before scheduling the injection.
	rebuild(M.gen, nil)
	return true
end

-- activate runs on the `tab` ember, before a newly created tab's folder has
-- loaded; a same-cwd `tab_create` emits no `cd`, so the root rows are not yet
-- available to seed from. Retry briefly from the async context until the folder
-- is loaded (or the tab/root changed), then seed once.
local seed_try = ya.sync(function(_, tab, root)
	if M.active_tab ~= tab or tostring(cx.active.current.cwd) ~= root then
		return true
	end
	if not active_tree() then
		return true
	end
	return seed_root_order()
end)

local function schedule_seed(tab, root)
	ya.async(function()
		for _ = 1, 40 do
			ya.sleep(0.05)
			if seed_try(tab, root) then
				return
			end
		end
	end)
end

-- Forget `target` and every expanded directory inside its subtree, comparing
-- cwd-relative paths so collapsing "a/b" never matches "a/bc".
local function prune_expanded(target_str)
	local cwd = cx.active.current.cwd
	local target_rel = tostring(Url(target_str):strip_prefix(cwd) or "")
	if target_rel == "" then
		return false
	end
	local prefix = target_rel .. "/"
	local removed = false
	for u in pairs(M.expanded) do
		local rel = tostring(Url(u):strip_prefix(cwd) or "")
		if rel == target_rel or rel:sub(1, #prefix) == prefix then
			M.expanded[u] = nil
			removed = true
		end
	end
	return removed
end

-- ---------------------------------------------------------------------------
-- Rename / bulk-rename: the injected rows and M.expanded are keyed by URL, so a
-- rename must remap metadata and rebuild before the hierarchy goes stale.
-- ---------------------------------------------------------------------------

-- Absolute-URL re-key for saved per-root state. Unlike remap_expanded_prefix
-- this never consults the active cwd, so it can address the saved sets of roots
-- other than the active one. `url_str` outside the moved subtree is unchanged.
local function remap_abs(url_str, from_str, to_str)
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
local function remap_abs_bulk(map, url_str)
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
local function remap_key_set(exp, resolve)
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
local function remap_list(order, resolve)
	local out = {}
	for i, v in ipairs(order) do
		out[i] = resolve(v)
	end
	return out
end

-- Apply `resolve` to every tab's saved roots, saved expansion keys, and saved
-- root-order entries, plus each tab's last-seen root. Collected first, then
-- re-keyed, so swaps/chains resolve against the untouched originals. Every tab
-- is visited, not just the active one, so a mutation performed from a classic
-- tab can never leave a tree tab's frozen roots pointing at a moved URL.
--
-- A root's *own* URL usually does not move when a path inside it is renamed, so
-- the expansion keys and root order of every root are re-keyed independently of
-- whether that root itself was re-keyed.
local function remap_saved_generic(resolve)
	local changed = false
	for _, t in pairs(M.tabs) do
		local saved_roots = t.roots

		-- Snapshot every (root, state) pair and resolve it against the untouched
		-- originals before writing anything back, so a swap (A->B, B->A) or a
		-- chain (A->B, B->C) cannot clobber its own source mid-iteration.
		local entries = {}
		for root, state in pairs(saved_roots) do
			local new_keys, keys_moved
			if state and state.expanded then
				new_keys, keys_moved = remap_key_set(state.expanded, resolve)
			end
			entries[#entries + 1] = {
				root = root,
				state = state,
				new_root = resolve(root),
				new_keys = new_keys,
				keys_moved = keys_moved,
				new_order = state and state.order and remap_list(state.order, resolve) or nil,
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

local function remap_saved(from_str, to_str)
	return remap_saved_generic(function(u)
		return remap_abs(u, from_str, to_str)
	end)
end

local function remap_saved_bulk(map)
	return remap_saved_generic(function(u)
		return remap_abs_bulk(map, u)
	end)
end

-- Absolute-URL, path-boundary-safe subtree membership. The events module has
-- its own copy; this one serves prune_saved, which stays behind the controller.
local function in_any_subtree(url_str, roots)
	for _, r in ipairs(roots) do
		if url_str == r or url_str:sub(1, #r + 1) == r .. "/" then
			return true
		end
	end
	return false
end

-- Drop saved roots inside any removed URL, saved expansion keys inside them, and
-- the matching last-seen root of any tab. Absolute-URL tests, because a removed
-- URL may belong to a saved root other than the active one.
local function prune_saved(roots)
	local changed = false
	for _, t in pairs(M.tabs) do
		local saved_roots = t.roots
		local drop = {}
		for root, state in pairs(saved_roots) do
			if in_any_subtree(root, roots) then
				drop[#drop + 1] = root
			elseif state and state.expanded then
				for k in pairs(state.expanded) do
					if in_any_subtree(k, roots) then
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
		if t.root and in_any_subtree(t.root, roots) then
			t.root = nil
			changed = true
		end
	end
	return changed
end

-- Re-key every expanded directory inside the moved subtree of a single
-- `from_str -> to_str` rename, comparing cwd-relative paths so `alpha/bc` is
-- never rewritten by a rename of `alpha/b`. A move out of the tree root prunes
-- the subtree instead, since those keys can never be reachable again. Returns
-- true when a key moved or was pruned.
local function remap_expanded_prefix(from_str, to_str)
	local cwd = cx.active.current.cwd
	local from_rel = rel_of(from_str)
	if not from_rel or from_rel == "" then
		return false
	end
	local to_rel = rel_of(to_str)
	local from_prefix = from_rel .. "/"
	local updates = {}
	for u in pairs(M.expanded) do
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
		M.expanded[pair.old] = nil
		if pair.new then
			M.expanded[pair.new] = true
		end
	end
	return #updates > 0
end

-- Sync-side application of a plugin-owned nested rename. The async input task
-- cannot touch M or cx, so it hands both the old and the resolved new URL back
-- here to re-key the expansion subtree (a renamed directory must keep its
-- expanded descendants), then bump the generation and coalesce one controlled
-- rebuild, keeping the current root.
local apply_nested_rename = ya.sync(function(_, old_str, new_str)
	local remapped = remap_expanded_prefix(old_str, new_str)
	local saved_touched = remap_saved(old_str, new_str)
	ya.dbg(
		"[tree-dbg] nested rename applied; old=",
		old_str,
		"new=",
		new_str,
		"remapped=",
		tostring(remapped),
		"saved=",
		tostring(saved_touched)
	)
	M.gen = M.gen + 1
	M.pending_focus = new_str
	ui.render()
	rebuild(M.gen, new_str)
end)

-- ---------------------------------------------------------------------------
-- Deletion (stock trash / permanent delete). Native remove already targets the
-- selected-or-hovered URLs at any depth and keeps its confirmation, task, and
-- selection behavior; the plugin only reacts to the successful completion
-- events to prune the controlled hierarchy and rebuild once.
-- ---------------------------------------------------------------------------

-- Forget every M.rows entry for `target_str` or inside its subtree, with the
-- same cwd-relative, path-boundary-safe comparison as prune_expanded.
local function prune_rows(target_str)
	local cwd = cx.active.current.cwd
	local target_rel = tostring(Url(target_str):strip_prefix(cwd) or "")
	if target_rel == "" then
		return false
	end
	local prefix = target_rel .. "/"
	local removed = false
	for u in pairs(M.rows) do
		local rel = tostring(Url(u):strip_prefix(cwd) or "")
		if rel == target_rel or rel:sub(1, #prefix) == prefix then
			M.rows[u] = nil
			removed = true
		end
	end
	return removed
end

-- ---------------------------------------------------------------------------
-- Mutation-event domain controller. events.lua owns the rename/remove/transfer
-- reconciliation policy; every read and write of M stays in main.lua behind
-- these bounded operations, so the module never holds the state table.
-- ---------------------------------------------------------------------------

-- True when `url_str` is the active tree root or an expanded directory: the two
-- places where a created/removed/transferred child becomes a visible row.
local function is_tree_parent(url_str)
	return url_str == tostring(cx.active.current.cwd) or M.expanded[url_str]
end

-- Snapshot of the controlled expansion keys. The module rebuilds whole sets, so
-- it reads a plain list and hands the replacement back through commit_mutation.
local function expanded_keys()
	local out = {}
	for url_str in pairs(M.expanded) do
		out[#out + 1] = url_str
	end
	return out
end

-- Snapshot of the depth-0 URL order (nil when the plugin has none yet).
local function root_order_snapshot()
	local order = M.root_order
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
local function prune_for_removal(roots)
	local pruned_expanded, pruned_rows = 0, 0
	for _, u_str in ipairs(roots) do
		if prune_expanded(u_str) then
			pruned_expanded = pruned_expanded + 1
		end
		if prune_rows(u_str) then
			pruned_rows = pruned_rows + 1
		end
	end
	return pruned_expanded, pruned_rows
end

-- Single commit for every mutation handler: install the replacement sets when
-- the module computed them, bump the generation, request the focus, then redraw
-- and coalesce one controlled rebuild. Preserves the existing update order.
local function commit_mutation(focus, new_expanded, new_root_order)
	if new_expanded then
		M.expanded = new_expanded
	end
	if new_root_order then
		M.root_order = new_root_order
	end
	M.gen = M.gen + 1
	M.pending_focus = focus
	ui.render()
	rebuild(M.gen, focus)
end

-- ---------------------------------------------------------------------------
-- External-change polling. Yazi's watcher only covers the active tab's current,
-- parent, and hovered folders non-recursively, so a mutation inside an expanded
-- directory at depth >= 1 never reaches the injected rows. The plugin keeps one
-- bounded poll loop alive for the active physical tree session: once per tick it
-- reads unfollowed metadata for each currently expanded directory and coalesces
-- any change, disappearance, or read failure into a single existing
-- generation-guarded rebuild. Collapsed subtrees, inactive saved roots, and
-- native fd/rg provider Views are never polled, and the plugin deliberately
-- does not touch the undocumented `watch`/`load` internals.
-- ---------------------------------------------------------------------------

-- Worst-case detection latency for one metadata tick. Directory mtime normally
-- changes on a direct child create/remove/rename, so a real change lands within
-- roughly one interval plus the rebuild.
local POLL_INTERVAL = 1.0

-- Identity of the newest poll session. Bumping it makes any older loop exit or
-- drop its result at the next scope/commit check, so a handle captured before a
-- lifecycle transition can never rebuild a different tab/root afterwards.
local poll_token = 0

-- Snapshot the active tree session for one tick. Runs in the sync context (with
-- M/cx access). Returns nil when the plugin no longer owns the active view
-- (tree off, classic tab, or a native fd/rg provider View) or when this loop has
-- been superseded, which makes the caller stop.
local poll_scope = ya.sync(function(_, token)
	if token ~= poll_token or not active_tree() then
		return nil
	end
	local tab = M.active_tab
	if not tab then
		return nil
	end
	local urls = {}
	for url_str in pairs(M.expanded) do
		urls[#urls + 1] = url_str
	end
	table.sort(urls)
	local sig = {}
	for _, url_str in ipairs(urls) do
		local s = M.dir_sig[url_str]
		if s then
			sig[url_str] = { mtime = s.mtime, is_dir = s.is_dir, dev = s.dev, btime = s.btime }
		end
	end
	local h = hovered()
	-- The one nested file the poll watches for content-only writes: the hovered
	-- visible injected regular file (depth > 0). Root-level writes are already
	-- covered by Yazi's own watcher, and a directory preview is limited to
	-- listing changes in expanded dirs. The baseline is the displayed File's own
	-- followed stat, so a hover change self-resets and no field persists.
	local hover_file
	if h and h.cha and not h.cha.is_dir and relative_of(h):find("/", 1, true) then
		hover_file = { url = tostring(h.url), mtime = h.cha.mtime, len = h.cha.len }
	end
	-- Pre-change visible flattened sequence and the hovered row's slot in it.
	-- The rebuild's empty FilesOp part resets the native cursor, so the tick
	-- reconstructs stock's slot-preserving focus from this snapshot instead of
	-- relying on the post-rebuild cursor. Captured here, not at commit time: a
	-- stock operation on an injected row can reset the Folder cursor between
	-- this snapshot and the commit.
	local visible = {}
	local hover_idx = 0
	local files = cx.active.current.files
	for i = 1, #files do
		local u = tostring(files[i].url)
		visible[i] = u
		if h and u == tostring(h.url) then
			hover_idx = i
		end
	end
	if hover_idx == 0 then
		hover_idx = (cx.active.current.cursor or 0) + 1
	end
	return {
		gen = M.gen,
		tab = tab,
		root = tostring(cx.active.current.cwd),
		urls = urls,
		sig = sig,
		injecting = M.injecting,
		visible = visible,
		hover_idx = hover_idx,
		hover_file = hover_file,
	}
end)

-- Install the tick's compact snapshot and, when the tick observed a real
-- change, coalesce exactly one rebuild through the existing guards. A newer
-- generation means an action or mutation event already owns the folder: the
-- tick yields without installing its snapshot so the next tick re-detects the
-- change once the folder is quiet. The snapshot otherwise replaces M.dir_sig
-- wholesale, so signatures for directories that are no longer expanded (or
-- belonged to a previous root) are pruned. Runs in the sync context.
--
-- `moves` (old URL -> new URL) and `prunes` (old URLs) describe an external
-- rename the async scan resolved by directory identity. They are applied to the
-- live and saved expansion state through the same remap/prune machinery the
-- rename/remove events use, before the one rebuild that follows.
--
-- Returns (rebuilt, empty_expansion): `empty_expansion` tells the poll loop to
-- stop when this tick pruned the last live expansion key, mirroring M:left.
local poll_apply = ya.sync(function(_, token, gen, tab, root, sig, visible, hover_idx, dirty, moves, prunes)
	if token ~= poll_token or not active_tree() then
		return false
	end
	if M.active_tab ~= tab or tab ~= active_id() then
		return false
	end
	if tostring(cx.active.current.cwd) ~= root then
		return false
	end
	if M.gen ~= gen then
		ya.dbg("[tree-dbg] poll change deferred; gen=", M.gen, "tick_gen=", gen)
		return false
	end
	M.dir_sig = sig
	if not dirty and not moves and not prunes then
		return false
	end
	if moves then
		-- Simultaneous longest-prefix resolution so a swap or chain stays
		-- order-independent; the destination key itself is absent from `sig`
		-- and is baselined on the next tick.
		local resolve = function(u)
			return remap_abs_bulk(moves, u)
		end
		M.expanded = remap_key_set(M.expanded, resolve)
		if M.root_order then
			M.root_order = remap_list(M.root_order, resolve)
		end
	end
	if prunes then
		for _, u in ipairs(prunes) do
			prune_expanded(u)
		end
	end
	if moves or prunes then
		-- Inactive tabs' saved roots and last-seen roots move/prune with the
		-- same absolute-URL policy as the rename/remove events.
		remap_saved_bulk(moves or {})
		prune_saved(prunes or {})
		ya.dbg(
			"[tree-dbg] poll remap; moves="
				.. tostring(moves and count_keys(moves) or 0)
				.. " prunes="
				.. tostring(prunes and #prunes or 0)
		)
	end
	M.gen = M.gen + 1
	-- Stock's removal keeps the cursor's slot: a surviving hovered row stays,
	-- else the next surviving row shifts up into the deleted slot, and only an
	-- end-of-list delete clamps back to the previous row. The rebuild reset the
	-- native cursor, so recreate that order over the pre-change visible sequence
	-- and let M:focus resolve it against the rebuilt files, skipping any row
	-- that vanished or is hidden by the active tree filter. An external move
	-- remaps each candidate through the same map as the expansion keys.
	local candidates, seen = {}, {}
	local function add_candidate(u)
		if u and not seen[u] then
			seen[u] = true
			candidates[#candidates + 1] = u
		end
	end
	local function candidate_at(i)
		local u = visible[i]
		if u and moves then
			u = remap_abs_bulk(moves, u)
		end
		return u
	end
	for i = hover_idx, #visible do
		add_candidate(candidate_at(i))
	end
	for i = hover_idx - 1, 1, -1 do
		add_candidate(candidate_at(i))
	end
	local focus = #candidates > 0 and candidates or nil
	local empty_expansion = next(M.expanded) == nil
	ya.dbg(
		"[tree-dbg] poll change; gen=",
		M.gen,
		"focus=",
		tostring(focus and focus[1]),
		"moves=",
		moves and count_keys(moves) or 0,
		"prunes=",
		prunes and #prunes or 0
	)
	M.pending_focus = focus
	ui.render()
	rebuild(M.gen, focus)
	return true, empty_expansion
end)

-- Clear M.poller only if it still refers to the loop that just ended, so a
-- superseded loop finishing later cannot clear a newer handle.
local poll_finish = ya.sync(function(_, token)
	if M.poller_token == token then
		M.poller = nil
		M.poller_token = nil
		M.dir_sig = {}
	end
end)

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
local function poll_tick(token)
	local scope = poll_scope(token)
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
		poll_apply(token, scope.gen, scope.tab, scope.root, sig, scope.visible, scope.hover_idx, dirty, moves, prunes)
	-- The last live expansion key was pruned: end the loop instead of waking once
	-- per interval for an empty scope. poll_finish clears the handle afterwards.
	if rebuilt and empty_expansion then
		return false
	end
	return true
end

-- Start the single poll loop for the active tree session. No-op while a loop is
-- already alive: the loop re-reads its scope from M every tick, so cd/reroot and
-- expansion/collapse are picked up in place without restarting it.
local function ensure_poller()
	if M.poller then
		return
	end
	if not active_tree() then
		return
	end
	poll_token = poll_token + 1
	local token = poll_token
	M.poller_token = token
	M.dir_sig = {}
	ya.dbg("[tree-dbg] poll start; token=", token)
	M.poller = ya.async(function()
		while true do
			ya.sleep(POLL_INTERVAL)
			if not poll_tick(token) then
				break
			end
		end
		poll_finish(token)
	end)
end

-- Cancel the poll loop and drop its snapshot. Every lifecycle transition that
-- leaves the active physical tree session (tree off, classic tab, provider
-- View) funnels through here.
local function stop_poller()
	poll_token = poll_token + 1
	if M.poller then
		M.poller:abort()
	end
	M.poller = nil
	M.poller_token = nil
	M.dir_sig = {}
	ya.dbg("[tree-dbg] poll stop")
end

-- r: tree-aware rename. Outside tree mode, for a depth-0 row, with a native
-- multi-selection, or during an active visual range this delegates to stock
-- rename (which routes selections to bulk rename, already remapped by the
-- events module). A visual range is not written to `cx.active.selected` until
-- stock's own Rename actor commits it (`escape_visual`), so it must be detected
-- through `cx.active.mode` and delegated before the nested-row decision.
-- Delegation forwards the stock preset binding's `cursor = "before_ext"` so
-- caret placement there is unchanged. A single injected descendant at any depth
-- is renamed beside its parent by the plugin, without stock `reveal` rerooting
-- the tab onto the child path; its caret reproduces `before_ext` by opening a
-- realtime input and emitting the input layer's own `move` offset. Casefold
-- handling remains the only stock capability the plugin-owned path cannot run.
function M:rename()
	if not active_tree() then
		ya.emit("rename", { cursor = "before_ext" })
		return
	end

	local h = hovered()
	if not h then
		ya.emit("rename", { cursor = "before_ext" })
		return
	end

	-- Stock rename hands any non-empty selection to bulk rename. An in-progress
	-- visual range has not been committed to `selected` yet (stock's Rename actor
	-- runs escape_visual itself), so any non-normal manager mode must delegate
	-- immediately or a nested row would fall through to the plugin-owned path.
	if #cx.active.selected > 0 or (cx.active.mode and not cx.active.mode.is_normal) then
		ya.emit("rename", { cursor = "before_ext" })
		return
	end

	-- Root rows keep stock behavior (with the forwarded `before_ext` cursor
	-- placement and stock casefold handling). Only injected descendants
	-- (relative path has a slash) need the plugin-owned path.
	if not relative_of(h):find("/", 1, true) then
		ya.emit("rename", { cursor = "before_ext" })
		return
	end

	local old_url_str = tostring(h.url)
	local name = h.name and tostring(h.name) or ""
	local move = before_ext_move(name, is_regular(h.cha))
	ya.dbg("[tree-dbg] nested rename open; old=", old_url_str, "move=", tostring(move))

	ya.async(function()
		if not operations then
			require("tree.operations") -- async context: safe here
			-- Raw module table: plain call, no require-proxy wrapper.
			operations = package.loaded["tree.operations"]
		end
		operations.nested_rename({
			old_url_str = old_url_str,
			name = name,
			move = move,
			apply_nested_rename = apply_nested_rename,
		})
	end)
end

-- l: expand a hovered safe directory at any depth; no-op on files and on
-- symlinked/indirect directories (cycle guard).
function M:right()
	if not active_tree() then
		ya.emit("enter", {})
		return
	end

	local h = hovered()
	if not h then
		return
	end
	if not h.cha.is_dir then
		return
	end
	if h.cha.is_link or h.cha.is_indirect then
		ya.dbg("[tree-dbg] refusing to expand linked directory; url=", tostring(h.url))
		return
	end

	local url_str = tostring(h.url)
	if M.expanded[url_str] then
		return
	end

	M.expanded[url_str] = true
	M.gen = M.gen + 1
	ya.dbg("[tree-dbg] expand ", url_str)
	ui.render()
	rebuild(M.gen, url_str)
	ensure_poller()
end

-- h: collapse the hovered expanded directory, or the immediate parent of a
-- nested row, pruning the whole subtree and focusing the collapsed directory.
-- Never leaves the cwd.
function M:left()
	if not active_tree() then
		ya.emit("leave", {})
		return
	end

	local h = hovered()
	if not h then
		return
	end

	local target
	local url_str = tostring(h.url)
	if h.cha and h.cha.is_dir and M.expanded[url_str] then
		target = url_str
	else
		local meta = M.rows[url_str]
		if meta and meta.parent then
			target = meta.parent
		else
			local rs = relative_of(h)
			if not rs:find("/", 1, true) then
				return
			end
			local parent_rel = rs:match("^(.*)/[^/]*$")
			if not parent_rel or parent_rel == "" then
				return
			end
			target = tostring(cx.active.current.cwd:join(parent_rel))
		end
	end

	if not target or not M.expanded[target] then
		return
	end

	prune_expanded(target)
	M.gen = M.gen + 1
	ya.dbg("[tree-dbg] collapse ", target)
	ui.render()
	rebuild(M.gen, target)
	-- Collapsing the last expanded directory leaves nothing to poll; stop the
	-- loop instead of waking once per interval for an empty scope.
	if next(M.expanded) == nil then
		stop_poller()
	end
end

-- H: reroot the tree one directory up (the parent of the current tree root).
-- No-op at the filesystem root; outside tree mode this is stock history back.
function M:root_up()
	if not active_tree() then
		ya.emit("back", {})
		return
	end
	local parent = cx.active.current.cwd.parent
	if not parent then
		ya.dbg("[tree-dbg] root_up at filesystem root; no-op")
		return
	end
	ya.dbg("[tree-dbg] root_up -> ", tostring(parent))
	ya.emit("cd", { parent })
end

-- L: reroot into a hovered directory (any depth); reveal a nested file in its
-- containing directory (cd + hover, one action); open a root-level file
-- normally. Outside tree mode this is stock history forward.
function M:root_down()
	if not active_tree() then
		ya.emit("forward", {})
		return
	end
	local h = hovered()
	if not h then
		return
	end
	if h.cha and h.cha.is_dir then
		ya.dbg("[tree-dbg] root_down dir -> ", tostring(h.url))
		ya.emit("cd", { h.url })
		return
	end
	if relative_of(h):find("/", 1, true) then
		ya.dbg("[tree-dbg] root_down reveal -> ", tostring(h.url))
		ya.emit("reveal", { h.url })
	else
		ya.emit("open", {})
	end
end

-- t t: in tree mode a new tab always opens at the tree cwd, ignoring the hover.
-- Stock `tab_create --current` passes target=None, so Yazi's TabCreate actor
-- reveals the hovered URL; for a plugin-injected descendant that cds to the
-- descendant's parent (for example `flavors` for `flavors/arrowlake-light.yazi`)
-- instead of the tree root. Emitting the cwd as an explicit target takes the
-- actor's target branch and never consults the hover. Outside tree mode (and in
-- native fd/rg Views, where active_tree() is false) this re-emits the stock
-- smart-tab behavior unchanged.
function M:tab_create(args)
	args = args or {}
	if not active_tree() then
		ya.emit("tab_create", { current = true })
		return
	end
	ya.dbg("[tree-dbg] tab_create at tree cwd=", tostring(cx.active.current.cwd))
	ya.emit("tab_create", { cx.active.current.cwd })
end

-- ---------------------------------------------------------------------------
-- Target-aware create. Stock create always joins the typed name to the active
-- cwd and then reveals (a cd whenever the target parent differs from cwd), so a
-- hovered directory or injected child cannot be delegated to it. The plugin
-- reproduces the prompt and filesystem work without ever changing cwd, then
-- rebuilds the expanded hierarchy so the new row is injected in place.
-- ---------------------------------------------------------------------------

-- Sync-side completion: only rebuild when the root is unchanged and the target
-- is part of the injected hierarchy (or rows are already injected), so a
-- watcher-driven Full reload cannot leave injected rows stale.
local create_after = ya.sync(function(_, cwd_str, target_str, joined_str)
	if tostring(cx.active.current.cwd) ~= cwd_str then
		ya.dbg("[tree-dbg] create finished after reroot; skipping rebuild")
		return
	end
	if M.expanded[target_str] or M.injected or M.injecting then
		M.gen = M.gen + 1
		M.pending_focus = joined_str
		ui.render()
		rebuild(M.gen, joined_str)
	else
		ya.dbg("[tree-dbg] create target not injected; no rebuild")
	end
end)

-- a: create at the hovered tree level. Outside tree mode, with no hover, or
-- when the resolved destination is the tree root, delegate to stock create
-- (which is byte-for-byte what is wanted there). A trailing path separator
-- selects directory creation; an existing file asks before being replaced.
function M:create(args)
	args = args or {}
	local force = args.force == true

	if not active_tree() then
		ya.emit("create", { force = force })
		return
	end

	local h = hovered()
	if not h then
		ya.emit("create", { force = force })
		return
	end

	local target = h.cha and h.cha.is_dir and h.url or h.url.parent
	if not target then
		ya.emit("create", { force = force })
		return
	end

	local cwd_str = tostring(cx.active.current.cwd)
	local target_str = tostring(target)
	if target_str == cwd_str then
		ya.emit("create", { force = force })
		return
	end

	ya.dbg("[tree-dbg] create target=", target_str, " force=", tostring(force))
	ya.async(function()
		if not operations then
			require("tree.operations") -- async context: safe here
			-- Raw module table: plain call, no require-proxy wrapper.
			operations = package.loaded["tree.operations"]
		end
		operations.create({
			force = force,
			target_str = target_str,
			cwd_str = cwd_str,
			create_after = create_after,
		})
	end)
end

-- ---------------------------------------------------------------------------
-- Target-aware paste. Native yank/cut already work on injected rows, so only
-- the destination needs redirecting. Stock paste always uses tab.cwd(), so a
-- non-cwd destination reproduces it through Yazi's own copy/move tasks; the
-- scheduler keeps unique-name/force behavior, task progress, hooks, watcher
-- reports, and duplicate/move DDS events identical to stock.
-- ---------------------------------------------------------------------------

-- p / P: paste into the hovered tree level. A cwd destination (root-level file,
-- or no hover) delegates to stock paste for exact parity; otherwise every
-- yanked source is spawned as one native copy/move task. Cut clears the yank
-- set and the stale active selection, matching stock's visible bookkeeping.
function M:paste(args)
	args = args or {}
	local force = args.force == true
	local follow = args.follow == true

	if not active_tree() then
		ya.emit("paste", { force = force, follow = follow })
		return
	end

	local h = hovered()
	local cwd_str = tostring(cx.active.current.cwd)
	local dest = h and (h.cha and h.cha.is_dir and h.url or h.url.parent) or nil
	if not dest or tostring(dest) == cwd_str then
		ya.emit("paste", { force = force, follow = follow })
		return
	end

	local cut = cx.yanked.is_cut
	local items = {}
	for _, f in pairs(cx.yanked) do
		if f.name then
			items[#items + 1] = { from = tostring(f.url), name = tostring(f.name) }
		end
	end

	local dest_str = tostring(dest)
	ya.dbg(
		"[tree-dbg] paste force=",
		tostring(force),
		"cut=",
		tostring(cut),
		"dest=",
		dest_str,
		"items=",
		#items
	)
	if #items == 0 then
		return
	end
	-- Mirrors stock paste: reset task tracing so a successful first task reveals
	-- its result, then spawn one task per source.
	cx.tasks.behavior:reset()
	ya.async(function()
		for _, it in ipairs(items) do
			local from = Url(it.from)
			local to = Url(dest_str):join(it.name)
			if force and tostring(from) == tostring(to) then
				ya.dbg("[tree-dbg] paste skipping identical forced endpoint; url=", it.from)
			else
				local ok, err = pcall(function()
					if cut then
						ya.task("move", { from = from, to = to, force = force }):spawn()
					else
						ya.task("copy", { from = from, to = to, force = force, follow = follow }):spawn()
					end
				end)
				if not ok then
					ya.dbg("[tree-dbg] paste spawn failed; from=", it.from, " err=", tostring(err))
					ya.notify({ title = "Paste failed", content = tostring(err), level = "error", timeout = 3 })
				end
			end
		end
	end)

	if cut then
		ya.dbg("[tree-dbg] cut paste unyank")
		ya.emit("unyank", {})
		if #cx.active.selected > 0 then
			ya.emit("escape", { select = true })
		end
	end
end

-- Enter: in tree mode a hovered directory reroots (native enter), a file opens
-- normally; outside tree mode this is exactly the stock open action.
function M:open()
	if active_tree() then
		local h = hovered()
		if h and h.cha.is_dir then
			ya.emit("enter", {})
			return
		end
	end
	ya.emit("open", {})
end

-- Emitted by a completed rebuild to place the cursor on the anchor row.
-- M.pending_focus is either one URL string or an ordered candidate list (used by
-- removal focus so a fallback hidden by the active tree filter is skipped).
function M:focus()
	local focus = M.pending_focus
	M.pending_focus = nil
	if not focus then
		return
	end

	local candidates
	if type(focus) == "table" then
		candidates = focus
	else
		candidates = { focus }
	end

	local folder = cx.active.current
	local files = folder.files
	local cursor = folder.cursor or 0
	local index = {}
	for i = 1, #files do
		index[tostring(files[i].url)] = i
	end
	for _, url_str in ipairs(candidates) do
		local i = index[url_str]
		if i then
			local delta = (i - 1) - cursor
			if delta ~= 0 then
				ya.emit("arrow", { step = delta })
			end
			return
		end
	end
end

-- ---------------------------------------------------------------------------
-- Tree-aware filtering. Yazi's native filter has no event or preflight hook and
-- matches the full urn, so it cannot keep injected descendants attached to
-- their parents. The plugin owns the query instead: it rebuilds the real
-- Entries subset (Yazi's own `entries.filter` stays nil) so rendered rows,
-- Folder cursor, hover, selection, and operations stay aligned.
-- ---------------------------------------------------------------------------

-- Rebuild after an event-free external change (hidden toggle, realtime filter).
function M:reassert()
	if not active_tree() then
		return
	end
	M.gen = M.gen + 1

	local h = hovered()
	local focus
	if h then
		local rs = relative_of(h)
		if M.filter_query and rs:find("/", 1, true) then
			local root = rs:match("^([^/]+)")
			focus = root and tostring(cx.active.current.cwd:join(root)) or tostring(h.url)
		else
			focus = tostring(h.url)
		end
	end

	ui.render()
	rebuild(M.gen, focus)
end

-- f: in tree mode collect a realtime query and rebuild the visible subset;
-- outside tree mode delegate to the stock `filter --smart` behavior.
function M:filter()
	if not active_tree() then
		ya.emit("filter", { smart = true })
		return
	end

	local initial = ""
	ya.dbg("[tree-dbg] filter input opened")
	ya.async(function()
		-- Stock popup parity: the input always opens blank (value defaults to
		-- ""), with the shared filter history, and opening emits no filter
		-- change. An existing hierarchy-aware query therefore stays applied
		-- until the first realtime typed value replaces it, exactly like
		-- Yazi's native `filter` popup over a live native filter.
		local stream = ya.input({
			name = "filter",
			title = "Filter: ",
			history = "shared",
			value = initial,
			-- Match Yazi's stock filter popup (top-center, offset [0, 2, 50, 3]);
			-- omitting `pos` leaves the popup zero-width and invisible.
			pos = { "top-center", y = 2, w = 50 },
			realtime = true,
			debounce = 0.05,
		})
		while true do
			local value, event = stream:recv()
			-- 1=submit, 3=type; 2=cancel, 0=end.
			if event == 1 or event == 3 then
				set_filter_query((value ~= nil and value ~= "") and value or nil)
				ya.emit("plugin", { "tree", "reassert" })
			end
			-- Cancel/Escape is ignored, like stock's Filter actor: it closes the
			-- popup and keeps the latest live-applied query without reverting or
			-- clearing it. Submitting a blank value still clears (stock Submit
			-- runs filter_do with an empty query).
			if event == 0 or event == 1 or event == 2 then
				break
			end
		end
	end)
end

-- <Esc>: clear an active tree filter and restore the full hierarchy; otherwise
-- fall through to Yazi's stock escape cascade.
function M:escape()
	if active_tree() and M.filter_query then
		M.filter_query = nil
		M.gen = M.gen + 1
		local h = hovered()
		ya.dbg("[tree-dbg] filter cleared")
		ui.render()
		rebuild(M.gen, h and tostring(h.url) or nil)
		return
	end
	ya.emit("escape", {})
end

-- ---------------------------------------------------------------------------
-- cwd/root change: save the outgoing root's live state and restore the incoming
-- root's saved state (or an empty one), then make rows and state agree.
-- ---------------------------------------------------------------------------

-- Seed a newly observed tab. Tabs created by tab_create inherit the creating
-- tab's tree/preview modes (and its configured sort, because Yazi cloned the
-- creator's pref including a pinned sort_by=none). Boot tabs the plugin sees for
-- the first time start from the configured startup defaults.
local function ensure_tab(id, creator)
	if not id then
		return nil
	end
	local t = M.tabs[id]
	if t then
		return t
	end
	t = { tree = false, preview = true, root = nil, roots = {} }
	if creator then
		t.tree, t.preview = creator.tree, creator.preview
		if creator.tree and creator.sort_saved then
			t.sort_saved = copy_sort(creator.sort_saved)
		end
	else
		t.tree = startup_defaults.tree
		t.preview = startup_defaults.preview
	end
	M.tabs[id] = t
	return t
end

-- Drop per-tab state for tabs Yazi has closed. 26.9.1 has no close/quit event
-- and Tabs::set_idx publishes `tab` even when the active id is unchanged, so
-- this must run before any same-id early return. Tab ids are never reused, so
-- dropping the state is safe.
local function prune_tabs()
	local live = {}
	for i = 1, #cx.tabs do
		live[id_num(cx.tabs[i].id)] = true
	end
	for id in pairs(M.tabs) do
		if not live[id] then
			M.tabs[id] = nil
			ya.dbg("[tree-dbg] pruned closed tab=", id)
		end
	end
end

-- Activate `tab`: save the outgoing tab's live state, invalidate any in-flight
-- rebuild, seed/load the incoming tab, apply its own ratio, and reconcile its
-- root. reconcile_root runs even for a classic incoming tab, so injected rows
-- restored from that tab's cached Folder are stripped and can never render as
-- flat classic rows.
local function activate(tab)
	local old = M.active_tab
	local old_t = old and M.tabs[old] or nil
	if old_t then
		save_live(old)
		if is_idle(old_t) then
			capture_base()
		end
	end

	M.gen = M.gen + 1
	M.active_tab = tab
	local t = ensure_tab(tab, old_t)
	if not t then
		return
	end
	local root = tostring(cx.active.current.cwd)
	if native_search_view() then
		-- Activating a tab whose Folder is a native provider View: keep the
		-- provider rows intact. The tab's recorded root stays the provider URL
		-- and its saved physical state stays in t.roots; only the layout is
		-- re-applied, and reconcile_root is skipped entirely.
		t.root = root
		M.pending_focus, M.injected, M.injecting = nil, false, false
		load_roots(t, root)
		stop_poller()
		apply_active()
		prune_tabs()
		return
	end
	t.root = root
	M.pending_focus, M.injected, M.injecting = nil, false, false
	if t.tree then
		-- A fresh tree tab has no saved root entry yet, so its folder is still
		-- loading. Pinning `none` now would force the first loaded frame to raw
		-- read_dir order; leave the configured sorter in place and let
		-- seed_root_order pin together with the injected directories-first rows.
		if t.roots[root] ~= nil then
			pin_sort_for(t)
		end
	else
		restore_sort_for(t)
	end
	load_roots(t, root)
	apply_active()
	reconcile_root()
	if t.tree and not seed_root_order() then
		schedule_seed(tab, root)
	end
	prune_tabs()
	if t.tree then
		ensure_poller()
	else
		stop_poller()
	end
end

local function on_cd(payload)
	local tab = id_num(payload and payload.tab)
	if not tab then
		return
	end
	-- Boot tabs the plugin has never seen are seeded with startup defaults; a
	-- new tab created by tab_create was already seeded (with inheritance) by the
	-- `tab` handler before this cd was processed.
	local t = ensure_tab(tab)
	if not t then
		return
	end
	-- The local `cd` ember carries only the tab id (its url field is the owned
	-- dummy), but the Folder swap has already happened by the time local
	-- subscribers run, so the live cwd is the incoming root.
	if tab ~= active_id() then
		-- A background tab rerooted (task/plugin-driven; no stock key does this).
		-- Never touch the live state being rendered for the active tab, but do
		-- keep that tab's own bookkeeping current: record its new root and drop
		-- the suspended native query, which belonged to the folder it just left,
		-- mirroring the active-tab reset below.
		local bg_root = tab_cwd(tab)
		if bg_root then
			t.root = bg_root
		end
		t.suspended_filter = nil
		ya.dbg("[tree-dbg] cd background tab=", tab, " root=", tostring(bg_root))
		return
	end
	local root = tostring(cx.active.current.cwd)
	if M.active_tab == nil then
		ya.dbg("[tree-dbg] cd bootstrap tab=", tab, " root=", root)
	end
	if M.active_tab == tab and root == t.root then
		-- tab_create's queued `tab` handler already activated and reconciled
		-- this root.
		return
	end

	if native_search_view() then
		-- cd into a native fd/rg View: delegate the provider Folder entirely.
		-- Save the outgoing physical root's live state (t.root is still the
		-- physical root), advance the tab's recorded root to the provider URL so
		-- returning to the physical root is a real reroot that restores the
		-- saved hierarchy, and drop the live working set without touching the
		-- Folder (no strip, rehydrate, or rebuild).
		if t.tree then
			save_live(tab)
		end
		M.gen = M.gen + 1
		M.active_tab = tab
		t.root = root
		t.suspended_filter = nil
		M.pending_focus, M.injected, M.injecting = nil, false, false
		M.expanded, M.rows = {}, {}
		M.root_order, M.filter_query = nil, nil
		ya.dbg(
			"[tree-dbg] cd search view; tab=",
			tab,
			" root=",
			root,
			" tree=",
			tostring(t.tree)
		)
		stop_poller()
		return
	end

	-- save_live still sees the outgoing root here: Yazi's Folder swap does not
	-- touch Lua state and on_cd is the first callback after it.
	if t.tree then
		save_live(tab)
	end
	-- A cd back from a native search View applies the mode that was recorded
	-- while the View was active: the sort pin (tree on) or configured-sort
	-- restore (tree off) was deferred because the provider Folder must not be
	-- reordered. Ordinary cds keep the baseline pin/restore timing (activate or
	-- toggle), so the initial folder load is untouched.
	local from_search_view = t.root ~= nil and is_search_url(t.root)
	M.gen = M.gen + 1
	M.active_tab = tab
	t.root = root
	-- Never restore a saved native query across a cd/reroot: it belongs to the
	-- folder that owned it, and the new Folder may carry its own filter.
	t.suspended_filter = nil
	if from_search_view then
		if t.tree then
			pin_sort_for(t)
		else
			restore_sort_for(t)
		end
	end
	load_roots(t, root)
	M.pending_focus, M.injected, M.injecting = nil, false, false
	ya.dbg(
		"[tree-dbg] cd restore; tab=",
		tab,
		" root=",
		root,
		" saved=",
		tostring(t.roots[root] ~= nil),
		" expanded=",
		tostring(next(M.expanded) ~= nil)
	)
	reconcile_root()
	if t.tree then
		ensure_poller()
	else
		stop_poller()
	end
end

-- Tab switch/create. The live M.* describes only the previously active tab, so
-- save it, then restore the incoming tab's own state. prune_tabs runs first
-- because set_idx publishes even when the active id is unchanged (a closed
-- background tab must still be forgotten).
local function on_tab(payload)
	local tab = id_num(payload and payload.idx)
	if not tab then
		return
	end
	prune_tabs()
	if tab == M.active_tab then
		-- Same-id publication (for example closing a background tab). Reconcile
		-- only if the active folder moved without a matching cd.
		local t = M.tabs[tab]
		if t and t.root ~= tostring(cx.active.current.cwd) then
			activate(tab)
		end
		return
	end
	ya.dbg("[tree-dbg] tab switch; tab=", tab)
	activate(tab)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function M:setup(opts)
	opts = opts or {}

	if not render then
		require(".render") -- runs in init.lua's async context
		-- Raw module table: plain sync functions, no per-row require proxy.
		render = package.loaded["tree.render"]
	end
	render.configure(opts)

	if opts.filter_mode == "suspend" or opts.filter_mode == "clear" then
		filter_mode = opts.filter_mode
	else
		filter_mode = "adopt"
	end
	ya.dbg("[tree-dbg] setup; style=", render.style(), " filter_mode=", filter_mode)

	if
		render.install({
			saved = Current.redraw,
			active_tree = active_tree,
			relative_depth = relative_depth,
			rows = function()
				return M.rows
			end,
			expanded = function()
				return M.expanded
			end,
		})
	then
		Current.redraw = render.redraw
	end

	install_header_filter()

	-- Capture the configured base ratio once, before any startup state mutates
	-- what effective_ratio() composes from.
	if not base then
		capture_base()
	end

	-- Save/restore per-tab/per-root expansion state whenever the root changes.
	-- Registered once.
	if not cd_subscribed then
		cd_subscribed = true
		ps.sub("cd", on_cd)
	end

	-- Isolate saved roots by tab: switching or creating a tab restores that
	-- tab's own state instead of leaking the previous tab's hierarchy in.
	if not tab_subscribed then
		tab_subscribed = true
		ps.sub("tab", on_tab)
	end

	-- Setup-installed mutation event reconciliation. events.lua owns the
	-- rename/bulk-rename and remove/transfer policy; the bounded controller
	-- keeps every read and write of M in main.lua.
	if not events then
		require(".events") -- runs in init.lua's async context
		-- Raw module table: plain sync handlers, no per-event require proxy.
		events = package.loaded["tree.events"]
	end
	local mutation = events.bind({
		active_tree = active_tree,
		hovered = hovered,
		rel_of = rel_of,
		cwd = function()
			return cx.active.current.cwd
		end,
		is_tree_parent = is_tree_parent,
		count_keys_tabs = function()
			return count_keys(M.tabs)
		end,
		remap_saved = remap_saved,
		remap_saved_bulk = remap_saved_bulk,
		remap_expanded_prefix = remap_expanded_prefix,
		expanded_keys = expanded_keys,
		root_order = root_order_snapshot,
		prune_saved = prune_saved,
		prune_for_removal = prune_for_removal,
		commit_mutation = commit_mutation,
	})

	-- Remap/rebuild the injected hierarchy when rows are renamed.
	if not mutate_subscribed then
		mutate_subscribed = true
		ps.sub("rename", mutation.on_rename)
		ps.sub("bulk-rename", mutation.on_bulk_rename)
	end

	-- Sort is transformed and hidden changes are re-asserted after the actor,
	-- because the injected flat list must keep its controlled ordering.
	if not preflight_subscribed then
		preflight_subscribed = true
		ps.sub("key-sort", on_key_sort)
		ps.sub("key-hidden", on_key_hidden)
	end

	-- Successful copy/move completion: refresh the affected injected branches.
	if not transfer_subscribed then
		transfer_subscribed = true
		ps.sub("duplicate", mutation.on_transfer("duplicate"))
		ps.sub("move", mutation.on_transfer("move"))
	end

	-- Successful trash/permanent-delete completion: prune every removed URL
	-- and subtree from the controlled hierarchy and coalesce one rebuild.
	if not remove_subscribed then
		remove_subscribed = true
		ps.sub("trash", mutation.on_remove("trash"))
		ps.sub("delete", mutation.on_remove("delete"))
	end

	-- Optional per-launch startup state. setup() runs during init.lua, before
	-- Yazi's bootstrap reflow and first paint, so assigning rt.mgr.ratio here
	-- makes the very first frame tree-shaped. app:resize/ui.render are not
	-- needed on this path (and app:resize would only be drained afterwards).
	local startup = opts.startup
	if startup ~= nil then
		startup_defaults = {
			tree = startup.tree == true,
			preview = startup.preview ~= false,
		}
		render.reset_logs()
		ya.dbg(
			"[tree-dbg] startup tree=",
			tostring(startup_defaults.tree),
			"preview=",
			tostring(startup_defaults.preview)
		)
		rt.mgr.ratio = effective_ratio(startup_defaults)
	end
end

function M:toggle()
	M.active_tab = M.active_tab or active_id()
	local t = ensure_tab(M.active_tab)
	if not t then
		return
	end
	sync_base()
	if render then
		render.reset_logs()
	end

	if native_search_view() then
		-- Toggling tree mode inside a native fd/rg View only records the tab's
		-- desired mode and reflows the layout; sort pin/restore and root
		-- reconciliation are deferred until the next physical cd applies them,
		-- so the provider Folder is never mutated.
		t.tree = not t.tree
		ya.dbg(
			"[tree-dbg] toggle in search view; tab=",
			M.active_tab,
			" recorded tree=",
			tostring(t.tree)
		)
		stop_poller()
		apply_active()
		return
	end

	if t.tree then
		-- Turning tree mode OFF for this tab only. Collapse everything by
		-- re-injecting the root entries only, then hand this tab's Folder
		-- ordering back to its configured sort. Cleanup is required whenever
		-- descendants may exist OR a rebuild is still in flight: collapsing the
		-- last expanded directory records `injected = false` only after its
		-- async rebuild completes, so gating on that flag alone can skip
		-- cleanup and leave stale descendant rows in the folder.
		local restoring = M.filter_query
		local had_work = M.injected or M.injecting or t.sort_saved ~= nil or has_descendants()
		-- Preserve this tab/root's hierarchy in its own roots map before the
		-- live state is cleared, so re-enabling tree mode can restore it.
		-- Classic tabs keep live state empty and their roots map frozen.
		t.root = tostring(cx.active.current.cwd)
		save_live(M.active_tab)
		t.tree = false
		M.gen = M.gen + 1
		M.expanded = {}
		M.rows = {}
		M.injected = false
		M.injecting = false
		M.pending_focus = nil
		M.root_order = nil
		M.filter_query = nil
		ya.dbg(
			"[tree-dbg] toggle off; tab=",
			M.active_tab,
			" saved_roots=",
			count_keys(t.roots),
			" work=",
			tostring(had_work)
		)
		if had_work then
			rebuild(M.gen, nil, false)
		end
		stop_poller()
		restore_sort_for(t)
		-- Hand native filtering back only after the root rows are re-injected,
		-- so the restored query is applied to the real folder contents. cd and
		-- other reroot paths reset without restoring (see on_cd).
		restore_native_filter(restoring)
	else
		-- Entering tree mode for this tab: restore this tab/root's saved
		-- expansions and root order, then take ownership of any native filter
		-- before the first injection. Native filter changes made while tree
		-- mode was off stay authoritative; the restored hierarchy is root-local.
		t.tree = true
		t.root = tostring(cx.active.current.cwd)
		pin_sort_for(t)
		load_roots(t, t.root)
		M.pending_focus, M.injected, M.injecting = nil, false, false
		ya.dbg("[tree-dbg] toggle on; tab=", M.active_tab, " restored=", count_keys(M.expanded))
		-- `adopt` re-applies a live native query hierarchy-aware through a
		-- reassert queued behind the native-clear action; `suspend` and `clear`
		-- leave the tree unfiltered until the user sets a tree query. Either
		-- path reconciles the restored expansions against the fresh root rows.
		if capture_native_filter() and M.filter_query then
			ya.emit("plugin", { "tree", "reassert" })
		else
			reconcile_root()
		end
		ensure_poller()
	end

	apply_active()
end

function M:preview()
	M.active_tab = M.active_tab or active_id()
	local t = ensure_tab(M.active_tab)
	if not t then
		return
	end
	sync_base()
	t.preview = not t.preview
	ya.dbg("[tree-dbg] toggle preview=", tostring(t.preview))
	apply_active()
end

function M:entry(job)
	-- `job.args` is a memoized userdata field whose cached table can be
	-- collected between accesses, so read it once and reuse it for dispatch.
	local args = job and job.args
	local action = args and args[1]
	M.active_tab = M.active_tab or active_id()
	if M.active_tab then
		ensure_tab(M.active_tab)
	end
	local t = tab_state()
	local log_tree, log_preview
	if t then
		log_tree, log_preview = t.tree, t.preview
	else
		log_tree, log_preview = startup_defaults.tree, startup_defaults.preview
	end
	ya.dbg(
		"[tree-dbg] entry action=",
		tostring(action),
		"tree=",
		tostring(log_tree),
		"preview=",
		tostring(log_preview)
	)

	if action == "toggle" then
		M:toggle()
	elseif action == "preview" then
		M:preview()
	elseif action == "right" then
		M:right()
	elseif action == "left" then
		M:left()
	elseif action == "root_up" then
		M:root_up()
	elseif action == "root_down" then
		M:root_down()
	elseif action == "tab_create" then
		M:tab_create(args)
	elseif action == "open" then
		M:open()
	elseif action == "create" then
		M:create(args)
	elseif action == "paste" then
		M:paste(args)
	elseif action == "focus" then
		M:focus()
	elseif action == "filter" then
		M:filter()
	elseif action == "rename" then
		M:rename()
	elseif action == "escape" then
		M:escape()
	elseif action == "reassert" then
		M:reassert()
	end
end

return M
