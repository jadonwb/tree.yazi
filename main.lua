--- @since 26.9.1
--- @sync entry

local M = {}

-- Sibling modules are raw module tables: either loaded lazily from inside an
-- existing async context, or resolved and bound once from setup()'s async
-- init.lua context. Either way they are the plain `package.loaded["tree.<name>"]`
-- table.

-- Installed by M:setup (async init.lua context); redraw paths are unreachable
-- without setup, so direct lazy `@sync entry` actions never see it as nil.
local render

-- Async rebuild pass; resolved lazily on first rebuild (async context).
local rebuild_pass

-- Async create/rename passes; resolved lazily on first use.
local operations

-- Setup-installed mutation event handlers; resolved lazily.
local events

-- External-change poll loop, resolved in setup (the sync action paths that call
-- ensure_poller cannot require it themselves).
local poller

-- URL/remap/prune and saved-root reconciliation helpers, bound in setup (called
-- from ya.sync bridges and the events controller).
local roots

local layout

local rows

-- Startup defaults for newly observed tabs; mode state lives per tab in M.tabs
-- (no bare global flag).
local startup_defaults = { tree = false, preview = true }

-- Defaults mirror stock's [input]/[confirm] values; setup()'s `dialogs` option
-- overrides per field.
local DIALOG_DEFAULTS = {
	create_pos = { "top-center", y = 2, w = 80 },
	rename_pos = { "hovered", y = 1, w = 80 },
	filter_pos = { "top-center", y = 2, w = 80 },
	overwrite_pos = { "center", w = 50, h = 15 },
	create_title = "Create:",
	rename_title = "Rename:",
	filter_title = "Filter:",
	overwrite_title = "Overwrite file?",
	overwrite_body = "Will overwrite the following file:",
}

local dialogs = {
	create_pos = DIALOG_DEFAULTS.create_pos,
	rename_pos = DIALOG_DEFAULTS.rename_pos,
	filter_pos = DIALOG_DEFAULTS.filter_pos,
	overwrite_pos = DIALOG_DEFAULTS.overwrite_pos,
	create_title = DIALOG_DEFAULTS.create_title,
	rename_title = DIALOG_DEFAULTS.rename_title,
	filter_title = DIALOG_DEFAULTS.filter_title,
	overwrite_title = DIALOG_DEFAULTS.overwrite_title,
	overwrite_body = DIALOG_DEFAULTS.overwrite_body,
}

-- Per-field: a right-typed value wins; omitted or wrong-typed falls back to the
-- default.
local function resolve_dialogs(overrides)
	local pick = {}
	for name, default in pairs(DIALOG_DEFAULTS) do
		local value = overrides[name]
		if type(value) == type(default) then
			pick[name] = value
		else
			if value ~= nil then
				ya.dbg("[tree-dbg] ignoring dialog override: ", name, " has the wrong type")
			end
			pick[name] = default
		end
	end
	return pick
end

local function tab_state(id)
	return M.tabs[id or M.active_tab]
end

-- Native provider View: Yazi cds into a provider URL and streams results as the
-- Folder; detected via spec.is_view (not a scheme prefix), so custom providers
-- match too.
local function url_is_view(url)
	return url ~= nil and url.spec ~= nil and url.spec.is_view == true
end

local function native_search_view()
	return url_is_view(cx.active.current.cwd)
end

-- Renderer/header/action routing authority; before the first lifecycle event
-- fall back to the startup default so the first frame is already tree-shaped.
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

-- Original preset Header.flags, captured once so setup() stays idempotent.
local saved_header_flags

M.expanded = {} -- set keyed by directory URL string, at any depth
M.rows = {} -- per-URL metadata: { depth, last, cont, parent } for injected rows
M.gen = 0 -- bumped by every sync user action
M.pending_focus = nil -- URL string (or ordered candidate list) to reposition onto
M.injected = false -- whether the last completed rebuild injected descendants
M.injecting = false -- a rebuild is scheduled or in flight (not yet completed)
M.inject_snapshot = nil -- plain-table replay stash of the last injected rows
M.inject_cwd = nil -- root URL for inject_snapshot
M.inject_tab = nil
M.inject_has_descendants = nil
M.last_hovered = nil -- URL last seen hovered by the poll scope
M.root_order = nil -- authoritative depth-0 URL order (kept across rebuilds/rename)
M.filter_query = nil -- active hierarchy-aware tree filter query; nil shows every row
M.dir_sig = {} -- url -> { mtime, is_dir, dev, btime }: last successful expanded-dir metadata
M.hidden_roots = {} -- topmost hidden URLs skipped while show_hidden is false
M.poller = nil -- ya.async Handle of the active external-change poll loop
M.poller_token = nil -- identity of the loop M.poller currently refers to

-- M.expanded/M.rows/M.root_order/M.filter_query are the live active-tab state;
-- M.tabs[id] saves the modes, sort/filter handoff, last root, and per-root
-- expansion/order/filter map across a switch.
M.active_tab = nil -- numeric id of the tab M.expanded/M.rows describe
M.tabs = {} -- [tab_id] = { tree, preview, sort_saved, suspended_filter, random_seed, root, roots }; replay stash on M is tab-gated (inject_snapshot/inject_cwd/inject_tab)
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

-- Used by the cd handler to record a background tab's new root without touching
-- the live state the plugin is rendering for the active tab.
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
-- from a hidden parent. The raw query is kept on the owning tab
-- (t.suspended_filter) so it can be restored without bleeding between tabs.
local filter_mode = "adopt"

-- Injection tickets must never collide with the folder loader's own tickets,
-- which start at 1 and increment per folder load, or a late loader op can
-- invalidate an injection.
M.seq = 1000000000

local cd_subscribed = false
local tab_subscribed = false
local mutate_subscribed = false
local preflight_subscribed = false
local transfer_subscribed = false
local remove_subscribed = false
local load_subscribed = false

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
		t.sort_saved = layout.capture_sort()
	end
	-- Every explicit random request reshuffles by advancing this tab's frozen
	-- seed; the emulated comparator reads it from the SortForm copy.
	if form.by == "random" then
		t.random_seed = (t.random_seed or 0) + 1
		ya.dbg("[tree-dbg] random seed=", t.random_seed)
	end
	for _, field in ipairs(layout.SORT_FIELDS) do
		if form[field] ~= nil then
			t.sort_saved[field] = form[field]
		end
	end
	form.by = "none"
	ya.dbg("[tree-dbg] sort request captured; forcing by=none")
	-- Re-emulate the captured sort immediately, exactly like the hidden
	-- toggle: the queued reassert bumps the generation and rebuilds the
	-- controlled order with the new preference.
	ya.emit("plugin", { "tree", "reassert" })
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

-- Post-load repair for a native Full reload. A Full load (window focus after an
-- external save marks the folder stale, `refresh`/Ctrl+R, a re-entered root)
-- replaces the cwd Folder's entries wholesale and, with the tab's sort pinned
-- to `none`, lists raw read_dir order with the injected descendants gone. The
-- DDS `load` event fires after that swap, so re-emit the recorded hierarchy
-- synchronously from the plain-table stash (set_injected_files) so the flat
-- listing is never painted: fresh File userdata are rebuilt under a new ticket,
-- the prior hover is re-arrowed, and an async reassert refreshes metadata. When
-- no usable stash exists, fall back to the queued reassert. Guards: tree mode
-- on, nothing injecting, an expansion recorded, and a stash that recorded
-- descendants (a hidden/filtered/empty expansion must not loop on the `load`
-- the replay itself publishes).
local function on_load(body)
	if not active_tree() or M.injecting then
		return
	end
	if next(M.expanded) == nil then
		return
	end
	local url = body and body.url
	if not url or tostring(url) ~= tostring(cx.active.current.cwd) then
		return
	end
	if rows.has_descendants() then
		return
	end

	local cwd = tostring(cx.active.current.cwd)
	local snapshot = M.inject_snapshot
	if snapshot == nil or M.inject_cwd ~= cwd or M.inject_tab ~= active_id() then
		ya.dbg("[tree-dbg] full load without descendants; scheduling reassert")
		ya.emit("plugin", { "tree", "reassert" })
		return
	end

	-- Only replay when the recorded injection actually carried descendant rows.
	-- The plugin's own Part/Done publishes `load`, and a state whose injected
	-- set legitimately has no depth>0 rows (expanded-but-empty, hidden, or
	-- filtered subtree) would otherwise replay forever; returning makes that
	-- `load` a no-op. A genuine Full that ate a tree always has depth>0 rows in
	-- the stash.
	if M.inject_has_descendants ~= true then
		return
	end

	-- A fresh ticket above the current entries.ticket() is required or
	-- Folder::update drops the replay's Part/Done.
	local ticket = M.seq
	M.seq = M.seq + 1
	local hover = M.last_hovered
	local files = {}
	for i, t in ipairs(snapshot) do
		-- Rebuild fresh File userdata from the plain-table stash: Stat from the
		-- serialized fields, the link target from its string, and the URL from
		-- its string. None of these consume the stash, so repeated replays work.
		local link_to
		if t.link_to then
			local ok, p = pcall(Path.os, t.link_to)
			link_to = ok and p or nil
		end
		files[i] = File({
			url = t.url,
			stat = t.stat and Stat(t.stat) or nil,
			lstat = t.lstat and Stat(t.lstat) or nil,
			link_to = link_to,
		})
	end
	ya.dbg("[tree-dbg] full load replay; ticket=", ticket, "rows=", #files, "hover=", tostring(hover))

	M.injecting = true
	ya.emit("update_files", { op = fs.op("part", { id = ticket, url = Url(cwd), files = {} }) })
	ya.emit("update_files", { op = fs.op("part", { id = ticket, url = Url(cwd), files = files }) })
	ya.emit("update_files", {
		op = fs.op("done", {
			-- The live root File is already re-stat'ed by the Full load that
			-- dropped the rows; re-stat'ing here would need an async call.
			id = ticket,
			file = cx.active.current.file,
		}),
	})
	M.injecting = false

	-- Re-arrow to the pre-reload hover, then rebuild asynchronously.
	M.pending_focus = hover
	ya.emit("plugin", { "tree", "focus" })
	ya.emit("plugin", { "tree", "reassert" })
end

-- ---------------------------------------------------------------------------
-- Rename-caret helpers (pure; used only by the M:rename handler).
-- ---------------------------------------------------------------------------

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
local function is_regular(stat)
	if not stat then
		return false
	end
	return not (
		stat.is_dir
		or stat.is_link
		or stat.is_indirect
		or stat.is_fifo
		or stat.is_sock
		or stat.is_block
		or stat.is_char
	)
end

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

-- Record the pruned depth-0 order so a later rename event can remap a root's
-- slot in place.
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

-- Publish the plain-table replay stash (see on_load) with the pre-reload hover
-- and whether the emitted set carried any depth>0 row. Same generation/tab gate
-- as check_gen.
local set_injected_files = ya.sync(function(_, gen, tab, cwd, snapshot, hovered_url, has_descendants)
	if M.gen == gen and M.active_tab == tab then
		M.inject_snapshot = snapshot
		M.inject_cwd = cwd
		M.inject_tab = tab
		M.last_hovered = hovered_url
		M.inject_has_descendants = has_descendants == true
	end
end)

-- Reconcile the live expansion set with what a completed rebuild actually
-- reached. A key whose chain of expanded ancestors no longer leads to it is
-- stale, so it is dropped here: the old URL becomes a tombstone and a directory
-- later recreated there cannot silently auto-expand. Keys under a directory
-- whose read failed are retained by the caller because that subtree is
-- unverifiable, not proven gone. Same gate as check_gen.
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

-- Publish the topmost hidden directories skipped by the last completed rebuild
-- while hidden files were off, keyed by absolute URL string. The poll scope
-- uses this set to drop the hidden subtree from the polled keys, so a hidden
-- subtree is never stat'd until hidden is shown again. Same gate as check_gen.
local set_hidden_roots = ya.sync(function(_, gen, tab, hidden)
	if M.gen == gen and M.active_tab == tab then
		local new = {}
		for u in pairs(hidden or {}) do
			new[u] = true
		end
		M.hidden_roots = new
	end
end)

-- Completion marker: clears the pending flag and records whether descendants
-- are now injected. A failed read passes nil and only clears the in-flight
-- flag, or every later toggle-off thinks a rebuild is still pending forever.
-- Same gate as check_gen.
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
		layout.pin_sort_for(tab_state(tab))
	end
	-- The captured SortForm drives the emulated per-directory ordering; nil is
	-- fine (flatten falls back to alphabetical with directories first).
	local sort_pref = layout.copy_sort((tab_state(tab) or {}).sort_saved)
	-- The emulated random order reads a frozen per-tab seed off this copy; the
	-- seed lives on the tab record (not in SortForm) so the copy/restore
	-- handoff never emits it. A configured `by = "random"` initializes it once.
	local sort_t = tab_state(tab)
	if sort_t and sort_pref then
		if sort_t.random_seed == nil and sort_pref.by == "random" then
			sort_t.random_seed = 1
		end
		sort_pref.random_seed = sort_t.random_seed
	end

	-- Take ownership of any native filter before reading the visible set: it
	-- must stay off for the whole injected-tree lifetime, or injected rows get
	-- re-filtered by urn and children can outlive their hidden parent.
	capture_native_filter()

	local cwd_str = tostring(cx.active.current.cwd)
	-- Capture the hovered row as the rebuild enters so the Full-load repair can
	-- restore it: by the time a Full load lands the Folder cursor has been reset
	-- to the raw first row, so the live hover is no longer the user's.
	local h = cx.active.current.hovered
	local hovered_url = h and tostring(h.url) or nil
	-- Per-tab live show-hidden state. `on_key_hidden` queues this rebuild behind
	-- the Hidden actor, so the value read here is the post-toggle state.
	local show_hidden = cx.active.pref.show_hidden

	-- Keep the per-tab root tracking current when the plugin acts without a
	-- preceding cd.
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
		M.root_order = rows.capture_root_order()
	end
	local root_order = M.root_order
	local filter = M.filter_query

	local ticket = M.seq
	M.seq = M.seq + 1
	local injected = #expanded > 0
	M.pending_focus = focus_str
	M.injecting = true
	-- Transient row metadata is owned by the async rebuild pass (rebuild.lua):
	-- clearing it here keeps a re-keyed expansion set from rendering against
	-- stale rows until the rebuild publishes its own snapshot.
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
			rebuild_pass = package.loaded["tree.rebuild"]
		end
		rebuild_pass.run({
			gen = gen,
			tab = tab,
			cwd_str = cwd_str,
			expanded = expanded,
			root_order = root_order,
			filter = filter,
			sort = sort_pref,
			show_hidden = show_hidden,
			ticket = ticket,
			injected = injected,
			focus_str = focus_str,
			hovered_url = hovered_url,
			check_gen = check_gen,
			set_root_order = set_root_order,
			set_rows = set_rows,
			set_injected_files = set_injected_files,
			set_expanded = set_expanded,
			set_hidden_roots = set_hidden_roots,
			finish_rebuild = finish_rebuild,
		})
	end)
end

local function install_header_filter()
	if saved_header_flags then
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

local function hovered()
	return cx.active.current.hovered
end

-- Synchronously strip restored descendant rows when the live expansion set is
-- empty. Emits the same part/part/done sequence rebuild uses; rows.lua reuses
-- the current Folder's depth-0 File userdata, so no filesystem read is needed
-- and no phantom row outlives on_cd.
local function strip_descendants_sync()
	local ticket = M.seq
	M.seq = M.seq + 1
	rows.strip_descendants(ticket)
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
	local exp, has = next(M.expanded) ~= nil, rows.has_descendants()
	if has and not exp then
		ya.dbg("[tree-dbg] reconcile strip; root=", tostring(cx.active.current.cwd))
		strip_descendants_sync()
		M.rows = rows.rehydrate_rows()
	else
		M.rows = rows.rehydrate_rows()
		M.injected, M.injecting = exp, false
		if exp then
			M.gen = M.gen + 1
			rebuild(M.gen, nil)
		end
	end
	ui.render()
end

-- Seed a directories-first alphabetical root order for a freshly activated tree
-- tab with no captured order and nothing expanded, then rebuild once so the
-- listing is deterministic rather than raw read_dir order. Returns true when the
-- folder rows were available to seed from.
local function seed_root_order()
	if native_search_view() then
		return true
	end
	if M.root_order ~= nil or next(M.expanded) ~= nil then
		return true
	end
	local order = rows.seed_root_order()
	if not order then
		return false
	end
	M.root_order = order
	M.gen = M.gen + 1
	ya.dbg("[tree-dbg] seeded root order; entries=", #order)
	-- Pin here, not in activate: the tab keeps its configured sorter until the
	-- seeded directories-first rows are ready, and rebuild pins synchronously
	-- before scheduling the injection.
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

-- Sync-side application of a plugin-owned nested rename. The async input task
-- cannot touch M or cx, so it hands both the old and the resolved new URL back
-- here to re-key the expansion subtree (a renamed directory must keep its
-- expanded descendants), then bump the generation and coalesce one controlled
-- rebuild, keeping the current root.
local apply_nested_rename = ya.sync(function(_, old_str, new_str)
	local remapped = roots.remap_expanded_prefix(old_str, new_str)
	local saved_touched = roots.remap_saved(old_str, new_str)
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

-- True when `url_str` is the active tree root or an expanded directory: the two
-- places where a created/removed/transferred child becomes a visible row.
local function is_tree_parent(url_str)
	return url_str == tostring(cx.active.current.cwd) or M.expanded[url_str]
end

-- Single commit for every mutation handler: install the replacement sets, bump
-- the generation, request the focus, redraw, and coalesce one controlled rebuild.
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

-- Identity of the newest poll session. Bumping it makes any older loop exit or
-- drop its result at the next scope/commit check, so a handle captured before a
-- lifecycle transition can never rebuild a different tab/root afterwards.
local poll_token = 0

-- Snapshot the active tree session for one tick. Runs in the sync context (with
-- M/cx access). Returns nil when tree mode no longer applies to the active view
-- (tree off, classic tab, or a native provider View) or when this loop has
-- been superseded, which makes the caller stop.
local poll_scope = ya.sync(function(_, token)
	if token ~= poll_token or not active_tree() then
		return nil
	end
	local tab = M.active_tab
	if not tab then
		return nil
	end
	-- While hidden files are off, rebuild never read a hidden directory, so its
	-- subtree must not be stat'd here either: drop every expanded key equal to
	-- or under a hidden root from the polled scope (and therefore from the
	-- published signature). Their expansion keys are retained, so re-showing
	-- hidden restores the scope and the next tick baselines them again.
	local hidden
	if not cx.active.pref.show_hidden then
		hidden = {}
		for u in pairs(M.hidden_roots) do
			hidden[#hidden + 1] = u
		end
	end
	local urls = {}
	for url_str in pairs(M.expanded) do
		if not hidden or not roots.in_any_subtree(url_str, hidden) then
			urls[#urls + 1] = url_str
		end
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
	-- Track the hovered row each tick so the native Full-load repair can restore
	-- the cursor the user last had, even if it moved since the last rebuild.
	M.last_hovered = h and tostring(h.url) or nil
	-- The one nested file the poll watches for content-only writes: the hovered
	-- visible injected regular file (depth > 0). Root-level writes are already
	-- covered by Yazi's own watcher, and a directory preview is limited to
	-- listing changes in expanded dirs. The baseline is the displayed File's own
	-- followed stat, so a hover change self-resets and no field persists.
	local hover_file
	if h and h.stat and not h.stat.is_dir and rows.relative_of(h):find("/", 1, true) then
		hover_file = { url = tostring(h.url), mtime = h.stat.mtime, len = h.stat.len }
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

-- Install the tick's compact snapshot and, when a real change was observed,
-- coalesce exactly one rebuild through the existing guards. A newer generation
-- means an action or mutation event already owns the folder, so the tick yields
-- without installing its snapshot; otherwise the snapshot replaces M.dir_sig
-- wholesale, pruning signatures for directories no longer expanded. `moves`
-- (old URL -> new URL) and `prunes` (old URLs) are an external rename resolved
-- by directory identity, applied through the same remap/prune machinery as the
-- rename/remove events. Returns (rebuilt, empty_expansion): the poll loop stops
-- when this tick pruned the last live expansion key.
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
			return roots.remap_abs_bulk(moves, u)
		end
		M.expanded = roots.remap_key_set(M.expanded, resolve)
		if M.root_order then
			M.root_order = roots.remap_list(M.root_order, resolve)
		end
	end
	if prunes then
		for _, u in ipairs(prunes) do
			roots.prune_expanded(u)
		end
	end
	if moves or prunes then
		-- Inactive tabs' saved roots and last-seen roots move/prune with the
		-- same absolute-URL policy as the rename/remove events.
		roots.remap_saved_bulk(moves or {})
		roots.prune_saved(prunes or {})
		ya.dbg(
			"[tree-dbg] poll remap; moves="
				.. tostring(moves and rows.count_keys(moves) or 0)
				.. " prunes="
				.. tostring(prunes and #prunes or 0)
		)
	end
	M.gen = M.gen + 1
	-- Removal focus anchor as in events.lua's on_remove: recreate stock's
	-- keep-the-slot cursor over the pre-change visible sequence and let M:focus
	-- resolve it against the rebuilt files, skipping any row that vanished or is
	-- hidden by the active tree filter. An external move remaps each candidate
	-- through the same map as the expansion keys.
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
			u = roots.remap_abs_bulk(moves, u)
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
		moves and rows.count_keys(moves) or 0,
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
		M.hidden_roots = {}
	end
end)

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
	M.poller = poller.start(token, { scope = poll_scope, apply = poll_apply, finish = poll_finish })
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
	M.hidden_roots = {}
	ya.dbg("[tree-dbg] poll stop")
end

-- r: delegate to stock rename outside tree mode, for depth-0 rows, with a
-- multi-selection, or during a visual range; an injected descendant is renamed
-- in place (input:move reproduces before_ext) without reveal rerooting.
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

	-- Any native multi-selection, and any uncommitted visual range (non-normal
	-- manager mode), must delegate to stock.
	if #cx.active.selected > 0 or not cx.active.mode.is_normal then
		ya.emit("rename", { cursor = "before_ext" })
		return
	end

	-- Root rows keep stock behavior (with the forwarded `before_ext` cursor
	-- placement and stock casefold handling). Only injected descendants
	-- (relative path has a slash) need the plugin-owned path.
	if not rows.relative_of(h):find("/", 1, true) then
		ya.emit("rename", { cursor = "before_ext" })
		return
	end

	local old_url_str = tostring(h.url)
	local name = h.name and tostring(h.name) or ""
	local move = before_ext_move(name, is_regular(h.stat))
	ya.dbg("[tree-dbg] nested rename open; old=", old_url_str, "move=", tostring(move))

	ya.async(function()
		if not operations then
			require("tree.operations") -- async context: safe here
			operations = package.loaded["tree.operations"]
		end
		operations.nested_rename({
			old_url_str = old_url_str,
			name = name,
			move = move,
			apply_nested_rename = apply_nested_rename,
			dialogs = dialogs,
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
	if not h.stat.is_dir then
		return
	end
	if h.stat.is_link or h.stat.is_indirect then
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
	if h.stat and h.stat.is_dir and M.expanded[url_str] then
		target = url_str
	else
		local meta = M.rows[url_str]
		if meta and meta.parent then
			target = meta.parent
		else
			local rs = rows.relative_of(h)
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

	roots.prune_expanded(target)
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
	if h.stat and h.stat.is_dir then
		ya.dbg("[tree-dbg] root_down dir -> ", tostring(h.url))
		ya.emit("cd", { h.url })
		return
	end
	if rows.relative_of(h):find("/", 1, true) then
		ya.dbg("[tree-dbg] root_down reveal -> ", tostring(h.url))
		ya.emit("reveal", { h.url })
	else
		ya.emit("open", {})
	end
end

-- Tree mode: emit the cwd as an explicit target so tab_create ignores the
-- hover; outside, re-emit stock tab_create --current.
function M:tab_create(args)
	args = args or {}
	if not active_tree() then
		ya.emit("tab_create", { current = true })
		return
	end
	ya.dbg("[tree-dbg] tab_create at tree cwd=", tostring(cx.active.current.cwd))
	ya.emit("tab_create", { cx.active.current.cwd })
end

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

	local target = h.stat and h.stat.is_dir and h.url or h.url.parent
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
			operations = package.loaded["tree.operations"]
		end
		operations.create({
			force = force,
			target_str = target_str,
			cwd_str = cwd_str,
			create_after = create_after,
			dialogs = dialogs,
		})
	end)
end

-- A: bulk create under the hovered directory (or file's parent) without
-- changing cwd; a cwd destination delegates to stock.
function M:bulk_create(args)
	if not active_tree() then
		ya.emit("bulk_create", {})
		return
	end

	local h = hovered()
	if not h then
		ya.emit("bulk_create", {})
		return
	end

	local target = h.stat and h.stat.is_dir and h.url or h.url.parent
	if not target then
		ya.emit("bulk_create", {})
		return
	end

	local cwd_str = tostring(cx.active.current.cwd)
	local target_str = tostring(target)
	if target_str == cwd_str then
		ya.emit("bulk_create", {})
		return
	end

	ya.dbg("[tree-dbg] bulk_create target=", target_str)
	ya.async(function()
		if not operations then
			require("tree.operations") -- async context: safe here
			operations = package.loaded["tree.operations"]
		end
		operations.bulk_create({
			target_str = target_str,
			cwd_str = cwd_str,
			create_after = create_after,
		})
	end)
end

-- p/P: paste into the hovered tree level (one native task per yanked source;
-- cut clears the yank set); a cwd destination delegates to stock.
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
	local dest = h and (h.stat and h.stat.is_dir and h.url or h.url.parent) or nil
	if not dest or tostring(dest) == cwd_str then
		ya.emit("paste", { force = force, follow = follow })
		return
	end

	local cut = cx.yanked.is_cut
	local items = {}
	for _, f in pairs(cx.yanked) do
		if f.name then
			items[#items + 1] = { file = f, from = tostring(f.url), name = tostring(f.name) }
		end
	end

	local dest_str = tostring(dest)
	ya.dbg("[tree-dbg] paste force=", tostring(force), "cut=", tostring(cut), "dest=", dest_str, "items=", #items)
	if #items == 0 then
		return
	end
	-- Resolve every scheduled endpoint synchronously so the forced-identical
	-- skips are known before scheduling; the tail selection update may only drop
	-- the URLs that were actually moved. `moved` keeps the File userdata because
	-- toggle_all parses its positional args as Files, not URL strings.
	local jobs = {}
	local moved = {}
	for _, it in ipairs(items) do
		local from = Url(it.from)
		local to = Url(dest_str):join(it.name)
		if force and tostring(from) == tostring(to) then
			ya.dbg("[tree-dbg] paste skipping identical forced endpoint; url=", it.from)
		else
			jobs[#jobs + 1] = { from = from, to = to }
			if cut then
				moved[#moved + 1] = it.file
			end
		end
	end
	-- Mirrors stock paste: reset task tracing so a successful first task reveals
	-- its result, then spawn one task per source.
	cx.tasks.behavior:reset()
	ya.async(function()
		for _, job in ipairs(jobs) do
			local ok, err = pcall(function()
				if cut then
					ya.task("move", { from = job.from, to = job.to, force = force }):spawn()
				else
					ya.task("copy", { from = job.from, to = job.to, force = force, follow = follow }):spawn()
				end
			end)
			if not ok then
				ya.dbg("[tree-dbg] paste spawn failed; from=", tostring(job.from), " err=", tostring(err))
				ya.notify({ title = "Paste failed", content = tostring(err), level = "error", timeout = 3 })
			end
		end
	end)

	if cut then
		ya.dbg("[tree-dbg] cut paste unyank")
		ya.emit("unyank", {})
		if #moved > 0 then
			moved.state = "off"
			ya.emit("toggle_all", moved)
		end
	end
end

-- Enter: in tree mode a hovered directory reroots (native enter), a file opens
-- normally; outside tree mode this is exactly the stock open action.
function M:open()
	if active_tree() then
		local h = hovered()
		if h and h.stat.is_dir then
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

-- Tree-aware filtering: Yazi's native filter has no event/preflight hook and
-- cannot keep injected descendants attached to their parents, so the plugin
-- tracks the query itself.

-- Rebuild after an event-free external change (hidden toggle, realtime filter).
function M:reassert()
	if not active_tree() then
		return
	end
	M.gen = M.gen + 1

	local h = hovered()
	local focus
	if h then
		local rs = rows.relative_of(h)
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
		-- ""), with the shared filter history, so an existing hierarchy-aware
		-- query stays applied until the first realtime typed value replaces it,
		-- exactly like Yazi's native `filter` popup over a live native filter.
		local stream = ya.input({
			name = "filter",
			title = dialogs.filter_title,
			history = "shared",
			value = initial,
			-- Top-center input at stock's width/title so the popup matches the
			-- native filter (stock's filter popup is 80 wide); omitting `pos`
			-- leaves the popup zero-width and invisible.
			pos = dialogs.filter_pos,
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

-- Seed a newly observed tab. Tabs created by tab_create inherit the creating
-- tab's tree/preview modes and, when the creator is a tree tab with a saved
-- sort, its captured sort; a tab created with an explicit target keeps its
-- configured sort until the rebuild re-pins it. Boot tabs the plugin sees for
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
			t.sort_saved = layout.copy_sort(creator.sort_saved)
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
		roots.save_live(old)
		if layout.is_idle(old_t) then
			layout.capture_base()
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
		M.inject_snapshot = nil
		M.inject_has_descendants = nil
		roots.load_roots(t, root)
		stop_poller()
		layout.apply_active()
		prune_tabs()
		return
	end
	t.root = root
	M.pending_focus, M.injected, M.injecting = nil, false, false
	M.inject_snapshot = nil
	M.inject_has_descendants = nil
	if t.tree then
		-- A fresh tree tab has no saved root entry yet, so its folder is still
		-- loading. Pinning `none` now would force the first loaded frame to raw
		-- read_dir order; leave the configured sorter in place and let
		-- seed_root_order pin together with the injected directories-first rows.
		if t.roots[root] ~= nil then
			layout.pin_sort_for(t)
		end
	else
		layout.restore_sort_for(t)
	end
	roots.load_roots(t, root)
	layout.apply_active()
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
		-- cd into a native provider View: delegate the provider Folder entirely.
		-- Save the outgoing physical root's live state (t.root is still the
		-- physical root), advance the tab's recorded root to the provider URL so
		-- returning to the physical root is a real reroot that restores the
		-- saved hierarchy, and drop the live working set without touching the
		-- Folder (no strip, rehydrate, or rebuild).
		if t.tree then
			roots.save_live(tab)
		end
		M.gen = M.gen + 1
		M.active_tab = tab
		t.root = root
		t.suspended_filter = nil
		M.pending_focus, M.injected, M.injecting = nil, false, false
		M.inject_snapshot = nil
		M.inject_has_descendants = nil
		M.expanded, M.rows = {}, {}
		M.root_order, M.filter_query = nil, nil
		ya.dbg("[tree-dbg] cd search view; tab=", tab, " root=", root, " tree=", tostring(t.tree))
		stop_poller()
		return
	end

	-- save_live still sees the outgoing root here: Yazi's Folder swap does not
	-- touch Lua state and on_cd is the first callback after it.
	if t.tree then
		roots.save_live(tab)
	end
	-- A cd back from a native search View applies the mode that was recorded
	-- while the View was active: the sort pin (tree on) or configured-sort
	-- restore (tree off) was deferred because the provider Folder must not be
	-- reordered. Ordinary cds keep the baseline pin/restore timing (activate or
	-- toggle), so the initial folder load is untouched.
	local from_search_view = t.root ~= nil and url_is_view(Url(t.root))
	M.gen = M.gen + 1
	M.active_tab = tab
	t.root = root
	-- Never restore a saved native query across a cd/reroot: it belongs to the
	-- folder that owned it, and the new Folder may carry its own filter.
	t.suspended_filter = nil
	if from_search_view then
		if t.tree then
			layout.pin_sort_for(t)
		else
			layout.restore_sort_for(t)
		end
	end
	roots.load_roots(t, root)
	M.pending_focus, M.injected, M.injecting = nil, false, false
	M.inject_snapshot = nil
	M.inject_has_descendants = nil
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

function M:setup(opts)
	opts = opts or {}

	dialogs = resolve_dialogs(type(opts.dialogs) == "table" and opts.dialogs or {})

	-- Resolve and bind the layout/ratio + sort-handoff module first: setup
	-- captures the base ratio and may assign the startup ratio, so the bound
	-- accessor must exist before any layout.* call below.
	if not layout then
		require(".layout") -- runs in init.lua's async context
		layout = package.loaded["tree.layout"]
	end
	layout.bind({
		tab_state = function(id)
			return tab_state(id)
		end,
		native_search = native_search_view,
		pref = function()
			return cx.active.pref
		end,
	})

	if not render then
		require(".render") -- runs in init.lua's async context
		render = package.loaded["tree.render"]
	end
	render.configure(opts)

	if not poller then
		require(".poller") -- runs in init.lua's async context
		poller = package.loaded["tree.poller"]
	end

	if not roots then
		require(".roots") -- runs in init.lua's async context
		roots = package.loaded["tree.roots"]
	end
	roots.bind({
		tabs = function()
			return M.tabs
		end,
		expanded = function()
			return M.expanded
		end,
		set_expanded = function(set)
			M.expanded = set
		end,
		rows = function()
			return M.rows
		end,
		set_rows = function(t)
			M.rows = t
		end,
		root_order = function()
			return M.root_order
		end,
		set_root_order = function(o)
			M.root_order = o
		end,
		filter_query = function()
			return M.filter_query
		end,
		set_filter_query = function(q)
			M.filter_query = q
		end,
		cwd = function()
			return cx.active.current.cwd
		end,
	})

	if not rows then
		require(".rows") -- runs in init.lua's async context
		rows = package.loaded["tree.rows"]
	end

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
			relative_depth = rows.relative_depth,
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
	if not layout.has_base() then
		layout.capture_base()
	end

	-- Save/restore per-tab/per-root expansion state whenever the root changes.
	if not cd_subscribed then
		cd_subscribed = true
		ps.sub("cd", on_cd)
	end

	-- Isolate saved roots by tab, so switching never leaks the previous
	-- hierarchy in.
	if not tab_subscribed then
		tab_subscribed = true
		ps.sub("tab", on_tab)
	end

	-- Setup-installed mutation reconciliation; events.lua defines the policy,
	-- main.lua does the M access.
	if not events then
		require(".events") -- runs in init.lua's async context
		events = package.loaded["tree.events"]
	end
	local mutation = events.bind({
		active_tree = active_tree,
		hovered = hovered,
		rel_of = rows.rel_of,
		cwd = function()
			return cx.active.current.cwd
		end,
		is_tree_parent = is_tree_parent,
		in_any_subtree = roots.in_any_subtree,
		count_keys_tabs = function()
			return rows.count_keys(M.tabs)
		end,
		remap_saved = roots.remap_saved,
		remap_saved_bulk = roots.remap_saved_bulk,
		remap_expanded_prefix = roots.remap_expanded_prefix,
		expanded_keys = roots.expanded_keys,
		root_order = roots.root_order_snapshot,
		prune_saved = roots.prune_saved,
		prune_for_removal = roots.prune_for_removal,
		commit_mutation = commit_mutation,
	})

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

	-- A native Full folder reload drops the injected rows wholesale; reassert the
	-- recorded hierarchy once such a load lands. Registered once.
	if not load_subscribed then
		load_subscribed = true
		ps.sub("load", on_load)
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
		rt.mgr.ratio = layout.effective_ratio(startup_defaults)
	end
end

function M:toggle()
	M.active_tab = M.active_tab or active_id()
	local t = ensure_tab(M.active_tab)
	if not t then
		return
	end
	layout.sync_base()
	if render then
		render.reset_logs()
	end

	if native_search_view() then
		-- Toggling tree mode inside a native provider View only records the tab's
		-- desired mode and reflows the layout; sort pin/restore and root
		-- reconciliation are deferred until the next physical cd applies them,
		-- so the provider Folder is never mutated.
		t.tree = not t.tree
		ya.dbg("[tree-dbg] toggle in search view; tab=", M.active_tab, " recorded tree=", tostring(t.tree))
		stop_poller()
		layout.apply_active()
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
		local had_work = M.injected or M.injecting or t.sort_saved ~= nil or rows.has_descendants()
		-- Preserve this tab/root's hierarchy in its own roots map before the
		-- live state is cleared, so re-enabling tree mode can restore it.
		-- Classic tabs keep live state empty and their roots map frozen.
		t.root = tostring(cx.active.current.cwd)
		roots.save_live(M.active_tab)
		t.tree = false
		M.gen = M.gen + 1
		M.expanded = {}
		M.rows = {}
		M.injected = false
		M.injecting = false
		M.pending_focus = nil
		M.root_order = nil
		M.filter_query = nil
		M.inject_snapshot = nil
		M.inject_has_descendants = nil
		ya.dbg(
			"[tree-dbg] toggle off; tab=",
			M.active_tab,
			" saved_roots=",
			rows.count_keys(t.roots),
			" work=",
			tostring(had_work)
		)
		if had_work then
			rebuild(M.gen, nil, false)
		end
		stop_poller()
		layout.restore_sort_for(t)
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
		layout.pin_sort_for(t)
		roots.load_roots(t, t.root)
		M.pending_focus, M.injected, M.injecting = nil, false, false
		M.inject_snapshot = nil
		M.inject_has_descendants = nil
		ya.dbg("[tree-dbg] toggle on; tab=", M.active_tab, " restored=", rows.count_keys(M.expanded))
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

	layout.apply_active()
end

function M:preview()
	M.active_tab = M.active_tab or active_id()
	local t = ensure_tab(M.active_tab)
	if not t then
		return
	end
	layout.sync_base()
	t.preview = not t.preview
	ya.dbg("[tree-dbg] toggle preview=", tostring(t.preview))
	layout.apply_active()
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
	ya.dbg("[tree-dbg] entry action=", tostring(action), "tree=", tostring(log_tree), "preview=", tostring(log_preview))

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
	elseif action == "bulk_create" then
		M:bulk_create(args)
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
