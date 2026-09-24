local M = {}
local saved = Current.redraw
local style_name, glyphs = "lines", { branch = " ├─", last = " └─", vertical = " │ ", space = "   " }

function M.configure(opts)
  opts = opts or {}
  style_name = opts.style == "indent" and "indent" or "lines"
  if type(opts.glyphs) == "table" then
    for k, v in pairs(glyphs) do if type(opts.glyphs[k]) == "string" and opts.glyphs[k] ~= "" then glyphs[k] = opts.glyphs[k] end end
  end
end

local function active(folder)
  local spec = folder.cwd.spec
  return spec.is_view and spec.scheme == "tree" and spec.domain == "default"
end

local function connector_style()
  local raw = th.indicator.current:raw()
  local style = ui.Style()
  if raw.fg then style = style:fg("reset") end
  if raw.bg then style = style:bg(App.bg()) end
  local methods = { bold = "bold", dim = "dim", italic = "italic", underline = "underline", blink = "blink", blink_rapid = "blink_rapid", reversed = "reverse", hidden = "hidden", crossed = "crossed" }
  for name, method in pairs(methods) do
    if raw[name] ~= nil then style = style[method](style, raw[name]) end
  end
  return style
end

function M.redraw(self)
  local folder = self._folder
  if not folder or not active(folder) or #folder.window == 0 then return saved(self) end
  local all = folder.files
  local root = tostring(folder.cwd.physical)
  local data = folder.cwd.spec.data or {}
  local tab = require("tree-vfs").tabs[tostring(data.tab)]
  local saved_root = tab and tab.roots[root]
  local expanded = saved_root and saved_root.expanded or {}
  local all_depth = {}
  for i, f in ipairs(all) do
    local p = tostring(f.url.physical)
    local rel = p:sub(#root + 2)
    all_depth[i] = select(2, rel:gsub("/", ""))
  end
  local pos = {}
  for i, f in ipairs(all) do pos[tostring(f.url)] = i end
  local lasts, conts, ancestor_last = {}, {}, {}
  for i = 1, #all do
    local depth, last = all_depth[i] or 0, true
    for j = i + 1, #all do
      if all_depth[j] < depth then break end
      if all_depth[j] == depth then last = false; break end
    end
    local cont = {}
    for level = 1, depth - 1 do cont[level] = not ancestor_last[level] end
    lasts[i], conts[i], ancestor_last[depth] = last, cont, last
  end
  local left, right = {}, {}
  for _, f in ipairs(folder.window) do
    local i = pos[tostring(f.url)] or 1
    local depth = all_depth[i] or 1
    local last, cont = lasts[i] ~= false, conts[i] or {}
    local cells = {}
    if style_name == "indent" then
      for _ = 1, depth do cells[#cells + 1] = glyphs.space end
    else
      for level = 1, depth - 1 do cells[#cells + 1] = cont[level] and glyphs.vertical or glyphs.space end
    end
    if depth > 0 then cells[#cells + 1] = last and glyphs.last or glyphs.branch end
    local prefix = table.concat(cells)
    local entity = Entity:new(f)
    entity.prefix = function() return "" end
    entity.highlights = function(e) return ui.printable(tostring(e._file.name):match("([^/]+)$") or e._file.name) end
    if f.stat and f.stat.is_dir and expanded[tostring(f.url.physical)] then
      entity.icon = function(e)
        local icon = th.icon:match(e._file, { hovered = true })
        return icon and (e._file.is_hovered and icon.text .. " " or ui.Line(icon.text .. " "):style(icon.style)) or ""
      end
    end
    local line = ui.Line({ ui.Span(prefix):style(connector_style()), entity:redraw() }):style(entity:style())
    local r = Linemode:new(f):redraw()
    line:truncate({ max = math.max(0, self._area.w - r:width()), ellipsis = entity:ellipsis(self._area.w) })
    left[#left + 1], right[#right + 1] = line, r
  end
  return { ui.List(left):area(self._area), ui.Text(right):area(self._area):align(ui.Align.RIGHT), table.unpack(Dnd:new(self._area):redraw()) }
end

return M
