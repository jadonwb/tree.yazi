local M = {}

local function target(snapshot)
  if snapshot.hovered and snapshot.hovered_is_dir and not snapshot.hovered_is_link and not snapshot.hovered_is_indirect then
    return snapshot.hovered
  end
  if snapshot.hovered then return snapshot.parent or snapshot.cwd end
  return snapshot.cwd
end

local function create_one(dest, name, is_dir, force, dialogs)
  local url = Url(dest):join(name)
  if is_dir then
    local ok, err = fs.create("dir_all", url)
    if not ok then ya.notify({ title = "Create failed", content = tostring(err), level = "error" }) end
    return ok
  end
  local st = fs.stat(url, false)
  if st and not force then
    if not ya.confirm({ pos = dialogs.overwrite_pos, title = dialogs.overwrite_title or "Overwrite file?", body = dialogs.overwrite_body or "Will overwrite the following file:" }) then return false end
  end
  if st and st.is_link then fs.remove("file", url) end
  local ok, err = fs.write(url, "")
  if not ok then ya.notify({ title = "Create failed", content = tostring(err), level = "error" }) end
  return ok
end

function M.create(action, args, snapshot, dialogs)
  ya.dbg("[tvfs] operations create begin tree=" .. tostring(snapshot.is_tree))
  dialogs = dialogs or {}
  if not snapshot.is_tree then
    if action == "create" then return ya.emit("create", { dir = args.dir == true, force = args.force == true }) end
    return ya.emit("bulk", {})
  end
  local dest = target(snapshot)
  if action == "create" then
    local is_dir = args.dir == true
    local value, event = ya.input({ name = is_dir and "create-dir" or "create-file", title = is_dir and (dialogs.create_dir_title or "Create (dir):") or (dialogs.create_title or "Create:"), history = "shared", pos = dialogs.create_pos })
    ya.dbg("[tvfs] create input target=" .. tostring(dest) .. " value=" .. tostring(value) .. " event=" .. tostring(event))
    if event ~= 1 or not value or value == "" then return end
    local slash = value:sub(-1) == "/" or value:sub(-1) == "\\"
    if slash then value = value:sub(1, -2) end
    create_one(dest, value, is_dir or slash, args.force == true, dialogs)
  else
    local value, event = ya.input({ name = "bulk-create", title = dialogs.bulk_create_title or "Create:", history = "shared", pos = dialogs.bulk_create_pos })
    if event ~= 1 or not value then return end
    for raw in (value .. "\n"):gmatch("(.-)\n") do
      local name = raw
      if name ~= "" then
        local dir = name:sub(-1) == "/" or name:sub(-1) == "\\"
        if dir then name = name:sub(1, -2) end
        create_one(dest, name, dir, args.force == true, dialogs)
      end
    end
  end
  ya.dbg("[tvfs] create target=" .. dest)
  ya.emit("refresh", {})
end

return M
