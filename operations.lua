-- Plugin-initiated filesystem writes (target-aware create, nested rename).

local M = {}

-- Realtime rename of one injected descendant beside its parent. The caret
-- offset reproduces stock `before_ext`; an existing destination prompts before
-- replacement. The resolved old/new URLs go back through ctx.apply_nested_rename
-- so the expansion subtree is re-keyed and one controlled rebuild is coalesced.
function M.nested_rename(ctx)
	local old_url_str = ctx.old_url_str
	local name = ctx.name
	local move = ctx.move
	local apply_nested_rename = ctx.apply_nested_rename

	-- Re-derive URLs from captured strings; the File userdata is scoped to
	-- the sync context and must not be held across the async task.
	local old_url = Url(old_url_str)
	local parent = old_url.parent

	-- A realtime input returns immediately, so the input layer's own
	-- `input:move` action can place the caret before the extension (the
	-- stock `before_ext` placement) while the popup is already shown.
	local stream = ya.input({
		title = "Rename:",
		value = name,
		-- TODO: input geometry is hardcoded; make width/location overridable so a filter-box plugin can support classic and tree view (see notes.txt).
		pos = { "hovered", y = 1, w = 50 },
		realtime = true,
	})
	if move then
		ya.emit("input:move", { move })
	end

	local value, event = stream:recv()
	while event == 3 do
		value, event = stream:recv()
	end
	-- Cancellation is a no-op, matching stock rename.
	if event ~= 1 then
		ya.dbg("[tree-dbg] nested rename cancelled; event=", tostring(event))
		return
	end
	if value == nil or value == "" then
		return
	end

	if not parent then
		ya.dbg("[tree-dbg] nested rename has no parent; old=", old_url_str)
		return
	end
	local new_url = parent:join(value)
	local new_url_str = tostring(new_url)
	if new_url_str == old_url_str then
		return
	end

	-- Ask before replacing an existing sibling. The plugin cannot run the
	-- casefold engine, so the exact same-path check above is the only
	-- implicit no-op; every other existing destination prompts.
	local stat = fs.stat(new_url, false)
	if stat then
		ya.dbg("[tree-dbg] nested rename overwrite prompt; new=", new_url_str)
		local ok = ya.confirm({
			pos = { "center", w = 60, h = 10 },
			title = "Overwrite?",
			body = "`" .. new_url_str .. "` already exists",
		})
		if not ok then
			ya.dbg("[tree-dbg] nested rename overwrite declined; new=", new_url_str)
			return
		end
	end

	local renamed, err = fs.rename(old_url, new_url)
	if not renamed then
		ya.dbg("[tree-dbg] nested rename failed; old=", old_url_str, " err=", tostring(err))
		ya.notify({
			title = "Rename failed",
			content = string.format("Failed to rename `%s`: %s", old_url_str, tostring(err)),
			level = "error",
			timeout = 5,
		})
		return
	end

	ya.dbg("[tree-dbg] nested rename ", old_url_str, " -> ", new_url_str)
	apply_nested_rename(old_url_str, new_url_str)
end

-- Create one file or directory under the captured target without changing cwd.
-- A trailing separator selects directory creation; an existing file asks before
-- being replaced; creating a file where a directory exists is a clean error (an
-- existing directory is accepted when a directory was requested). Completion
-- goes through ctx.create_after so the injected hierarchy is rebuilt in place.
function M.create(ctx)
	local force = ctx.force
	local target_str = ctx.target_str
	local cwd_str = ctx.cwd_str
	local create_after = ctx.create_after

	local value, event = ya.input({
		name = "create-file",
		title = "Create:",
		history = "shared",
		pos = { "top-center", y = 2, w = 50 },
	})
	if event ~= 1 or value == nil or value == "" then
		ya.dbg("[tree-dbg] create cancelled; event=", tostring(event))
		return
	end

	local last = value:sub(-1)
	local is_dir = last == "/" or last == "\\"
	local name = value
	if is_dir then
		name = value:sub(1, -2)
	end
	if name == "" then
		return
	end

	local joined = Url(target_str):join(name)
	local joined_str = tostring(joined)

	if is_dir then
		local ok, err = fs.create("dir_all", joined)
		if not ok then
			ya.dbg("[tree-dbg] create dir failed; url=", joined_str, " err=", tostring(err))
			ya.notify({ title = "Create failed", content = tostring(err), level = "error", timeout = 3 })
			return
		end
	else
		local parent = joined.parent
		if parent then
			fs.create("dir_all", parent)
		end
		local stat = fs.stat(joined, false)
		if stat and stat.is_dir then
			-- A directory can never be replaced by an empty file; fail
			-- cleanly instead of prompting and then hitting EISDIR.
			ya.dbg("[tree-dbg] create dir collision; url=", joined_str)
			ya.notify({
				title = "Create failed",
				content = "`" .. joined_str .. "` already exists as a directory",
				level = "error",
				timeout = 3,
			})
			return
		end
		if stat then
			if not force then
				local ok = ya.confirm({
					pos = { "center", w = 60, h = 10 },
					title = "Overwrite file?",
					body = "`" .. joined_str .. "` already exists",
				})
				if not ok then
					ya.dbg("[tree-dbg] create overwrite declined; url=", joined_str)
					return
				end
			end
			if stat.is_link then
				-- fs.write would follow the link and truncate its target;
				-- unlink the link itself (a hard unlink, never the trash).
				fs.remove("file", joined)
			end
			-- A regular file needs no unlink: fs.write opens with
			-- create+truncate, so overwriting stays in place with no
			-- missing-path window and no lost inode.
		end
		local ok, err = fs.write(joined, "")
		if not ok then
			ya.dbg("[tree-dbg] create write failed; url=", joined_str, " err=", tostring(err))
			ya.notify({ title = "Create failed", content = tostring(err), level = "error", timeout = 3 })
			return
		end
	end

	ya.dbg("[tree-dbg] create done; url=", joined_str, " is_dir=", tostring(is_dir))
	create_after(cwd_str, target_str, joined_str)
end

-- Stock Entry::parse: strip one trailing separator to mark a directory, drop
-- empty lines.
local function parse_entries(content)
	local entries = {}
	for raw in (content .. "\n"):gmatch("(.-)\n") do
		local line = raw
		if line:sub(-1) == "\r" then
			line = line:sub(1, -2)
		end
		if line ~= "" then
			local is_dir = false
			local last = line:sub(-1)
			if last == "/" or last == "\\" then
				is_dir = true
				line = line:sub(1, -2)
			end
			if line ~= "" then
				entries[#entries + 1] = { path = line, is_dir = is_dir }
			end
		end
	end
	return entries
end

-- Bulk create under the captured target without changing cwd. File entries use
-- create_new, so an existing path is never overwritten.
function M.bulk_create(ctx)
	local target_str = ctx.target_str
	local cwd_str = ctx.cwd_str
	local create_after = ctx.create_after

	local editor = os.getenv("EDITOR") or "vi"

	local tmp_path = os.tmpname()
	local tmp = Url(tmp_path)
	if not fs.write(tmp, "") then
		ya.dbg("[tree-dbg] bulk create temp write failed; path=", tmp_path)
		ya.notify({
			title = "Bulk create failed",
			content = "Failed to create temporary file `" .. tmp_path .. "`",
			level = "error",
			timeout = 5,
		})
		return
	end

	local permit = ui.hide()
	local child, err = Command("sh")
		:arg({ "-c", editor .. " " .. ya.quote(tmp_path) })
		:stdin(Command.INHERIT)
		:stdout(Command.INHERIT)
		:stderr(Command.INHERIT)
		:spawn()
	if child then
		child:wait()
	end
	permit:drop()

	if not child then
		ya.dbg("[tree-dbg] bulk create editor spawn failed; err=", tostring(err))
		ya.notify({ title = "Bulk create failed", content = tostring(err), level = "error", timeout = 5 })
		fs.remove("file", tmp)
		return
	end

	local fd, open_err = fs.access():read(true):open(tmp)
	if not fd then
		ya.dbg("[tree-dbg] bulk create temp open failed; path=", tmp_path, " err=", tostring(open_err))
		ya.notify({
			title = "Bulk create failed",
			content = tostring(open_err),
			level = "error",
			timeout = 5,
		})
		fs.remove("file", tmp)
		return
	end

	local chunks = {}
	while true do
		local chunk = fd:read(4096)
		if not chunk or chunk == "" then
			break
		end
		chunks[#chunks + 1] = chunk
	end
	ya.drop(fd)
	fs.remove("file", tmp)

	local entries = parse_entries(table.concat(chunks))
	if #entries == 0 then
		ya.dbg("[tree-dbg] bulk create empty; nothing to do")
		return
	end

	local preview = {}
	for _, entry in ipairs(entries) do
		preview[#preview + 1] = entry.is_dir and (entry.path .. "/") or entry.path
	end
	local ok = ya.confirm({
		pos = { "center", w = 60, h = 10 },
		title = "Continue to create?",
		body = table.concat(preview, "\n"),
	})
	if not ok then
		ya.dbg("[tree-dbg] bulk create declined")
		return
	end

	local target = Url(target_str)
	local failed = {}
	local first_created
	for _, entry in ipairs(entries) do
		local joined = target:join(entry.path)
		local joined_str = tostring(joined)
		local created = false
		if entry.is_dir then
			local dir_ok, dir_err = fs.create("dir_all", joined)
			if dir_ok then
				created = true
			else
				failed[#failed + 1] = joined_str .. ": " .. tostring(dir_err)
			end
		else
			local parent_url = joined.parent
			if parent_url then
				fs.create("dir_all", parent_url)
			end
			local file, file_err = fs.access():write(true):create_new(true):open(joined)
			if file then
				ya.drop(file)
				created = true
			else
				failed[#failed + 1] = joined_str .. ": " .. tostring(file_err)
			end
		end
		if created and not first_created then
			first_created = joined_str
		end
	end

	if #failed > 0 then
		ya.dbg("[tree-dbg] bulk create failures=", tostring(#failed))
		ya.notify({
			title = "Bulk create failed",
			content = "Failed to create:\n" .. table.concat(failed, "\n"),
			level = "error",
			timeout = 5,
		})
	end

	ya.dbg("[tree-dbg] bulk create done; target=", target_str, " first=", tostring(first_created))
	create_after(cwd_str, target_str, first_created)
end

return M
