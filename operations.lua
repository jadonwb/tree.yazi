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

	local dialogs = ctx.dialogs or {}
	local old_stat = fs.stat(old_url, false)

	-- A realtime input returns immediately, so the input layer's own
	-- `input:move` action can place the caret before the extension (the
	-- stock `before_ext` placement) while the popup is already shown.
	local stream = ya.input({
		-- The stock rename names restore the popup's bottom-right icon.
		name = old_stat and old_stat.is_dir and "rename-dir" or "rename-file",
		title = dialogs.rename_title or "Rename:",
		history = "shared",
		value = name,
		pos = dialogs.rename_pos,
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

	local stat = fs.stat(new_url, false)
	if stat then
		ya.dbg("[tree-dbg] nested rename overwrite prompt; new=", new_url_str)
		local ok = ya.confirm({
			pos = dialogs.overwrite_pos,
			title = dialogs.overwrite_title or "Overwrite file?",
			body = dialogs.overwrite_body or "Will overwrite the following file:",
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

-- Create under the captured target without changing cwd; a trailing separator
-- means directory. Any existing path prompts before replacement unless forced;
-- a directory cannot be replaced, so confirming surfaces the write error
-- (matching stock).
function M.create(ctx)
	local force = ctx.force
	local target_str = ctx.target_str
	local cwd_str = ctx.cwd_str
	local create_after = ctx.create_after

	local dialogs = ctx.dialogs or {}

	local value, event = ya.input({
		name = "create-file",
		title = dialogs.create_title or "Create:",
		history = "shared",
		pos = dialogs.create_pos,
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
		if stat then
			if not force then
				local ok = ya.confirm({
					pos = dialogs.overwrite_pos,
					title = dialogs.overwrite_title or "Overwrite file?",
					body = dialogs.overwrite_body or "Will overwrite the following file:",
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

-- Stock BulkCreate::opener: first text/plain [open] rule, then the first
-- blocking opener in its use list.
local function text_opener_run()
	for _, rule in pairs(rt.open.rules:match({ mime = "text/plain" })) do
		for _, name in ipairs(rule.use) do
			local rules = rt.opener[name]
			if rules then
				for _, opener in pairs(rules:match()) do
					if opener.block then
						return opener.run
					end
				end
			end
		end
		return nil
	end
	return nil
end

-- Stock Splatter for one file (ya.quote mirrors its platform quoting): a local
-- temp file's content path and url are equal, so %s is the file and %d its
-- parent (index 1 the same); %h/%y/%t shifts are empty; unknown %X stays
-- literal.
local function splat_single(template, path, parent)
	local quoted_path = ya.quote(path)
	local quoted_parent = ya.quote(parent)
	local n = #template

	local function skip_digits(from)
		local j = from
		while j <= n do
			local d = template:sub(j, j)
			if d < "0" or d > "9" then
				break
			end
			j = j + 1
		end
		return j
	end

	local out = {}
	local i = 1
	while i <= n do
		local c = template:sub(i, i)
		if c ~= "%" then
			out[#out + 1] = c
			i = i + 1
		elseif i == n then
			out[#out + 1] = "%"
			i = i + 1
		else
			local t = template:sub(i + 1, i + 1)
			if t == "%" then
				out[#out + 1] = "%"
				i = i + 2
			elseif t == "s" or t == "S" or t == "d" or t == "D" then
				local j = skip_digits(i + 2)
				local idx = tonumber(template:sub(i + 2, j - 1))
				if idx and idx >= 2 then
					out[#out + 1] = "''"
				elseif t == "s" or t == "S" then
					out[#out + 1] = quoted_path
				else
					out[#out + 1] = quoted_parent
				end
				i = j
			elseif t == "h" or t == "H" then
				out[#out + 1] = "''"
				i = i + 2
			elseif t == "y" or t == "Y" then
				i = skip_digits(i + 2)
			elseif t == "t" or t == "T" then
				-- Consume the following token; the shifted tab has no source.
				i = i + 2
				if i <= n then
					if template:sub(i, i) == "%" and i < n then
						local u = template:sub(i + 1, i + 1)
						if u == "s" or u == "S" or u == "d" or u == "D" or u == "y" or u == "Y" then
							i = skip_digits(i + 2)
						else
							i = i + 2
						end
					else
						i = i + 1
					end
				end
			else
				out[#out + 1] = "%" .. t
				i = i + 2
			end
		end
	end
	return table.concat(out)
end

-- Bulk create under the captured target without changing cwd.
function M.bulk_create(ctx)
	local target_str = ctx.target_str
	local cwd_str = ctx.cwd_str
	local create_after = ctx.create_after

	local run = text_opener_run()
	if not run then
		ya.dbg("[tree-dbg] bulk create has no blocking text opener")
		ya.notify({ title = "Bulk create", content = "No text opener found", level = "warn", timeout = 5 })
		return
	end

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

	-- Stock launches the expanded opener through the platform shell, blocking
	-- with inherited stdio, in the tab cwd.
	local tmp_dir = tmp.parent and tostring(tmp.parent) or ""
	local cmd = splat_single(run, tmp_path, tmp_dir)

	local permit = ui.hide()
	local child, err
	if ya.target_os() == "windows" then
		child, err = Command("cmd.exe")
			:arg({ "/Q", "/S", "/D", "/V:OFF", "/E:ON", "/C", cmd })
			:cwd(cwd_str)
			:stdin(Command.INHERIT)
			:stdout(Command.INHERIT)
			:stderr(Command.INHERIT)
			:spawn()
	else
		child, err = Command("sh")
			:arg({ "-c", cmd })
			:cwd(cwd_str)
			:stdin(Command.INHERIT)
			:stdout(Command.INHERIT)
			:stderr(Command.INHERIT)
			:spawn()
	end
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
