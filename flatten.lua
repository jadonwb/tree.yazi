-- Pure ordering/matching helpers for the async rebuild flatten pass.

local M = {}

-- Byte-level natural comparison: a Lua port of Yazi's in-tree strnatcmp
-- (`yazi-shared/src/natsort.rs`, itself a port of Martin Pool's strnatcmp.c).
-- The comparands are file-name component bytes; `insensitive` folds ASCII case
-- only. Returns -1, 0, or 1.
local function is_ascii_digit(b)
	return b ~= nil and b >= 48 and b <= 57
end

-- Rust's u8::is_ascii_whitespace: space, tab, LF, FF, CR (not vertical tab).
local function is_ascii_whitespace(b)
	return b ~= nil and (b == 32 or b == 9 or b == 10 or b == 12 or b == 13)
end

-- Leading-zero / fixed-width digit run: compare digit by digit.
local function compare_left(left, right, li, ri)
	while true do
		local lb = string.byte(left, li + 1)
		local rb = string.byte(right, ri + 1)
		local ld, rd = is_ascii_digit(lb), is_ascii_digit(rb)
		if ld and rd then
			if lb ~= rb then
				return (lb < rb and -1 or 1), li, ri
			end
		elseif ld then
			return 1, li, ri
		elseif rd then
			return -1, li, ri
		else
			return 0, li, ri
		end
		li = li + 1
		ri = ri + 1
	end
end

-- Numeric magnitude run: fewer digits first, otherwise the first differing
-- digit decides.
local function compare_right(left, right, li, ri)
	local bias = 0
	while true do
		local lb = string.byte(left, li + 1)
		local rb = string.byte(right, ri + 1)
		local ld, rd = is_ascii_digit(lb), is_ascii_digit(rb)
		if ld and rd then
			if bias == 0 and lb ~= rb then
				bias = lb < rb and -1 or 1
			end
		elseif ld then
			return 1, li, ri
		elseif rd then
			return -1, li, ri
		else
			return bias, li, ri
		end
		li = li + 1
		ri = ri + 1
	end
end

local function natsort(left, right, insensitive)
	local li, ri = 0, 0
	local l = string.byte(left, 1)
	local r = string.byte(right, 1)
	while true do
		while is_ascii_whitespace(l) do
			li = li + 1
			l = string.byte(left, li + 1)
		end
		while is_ascii_whitespace(r) do
			ri = ri + 1
			r = string.byte(right, ri + 1)
		end
		if l ~= nil and r ~= nil then
			if is_ascii_digit(l) and is_ascii_digit(r) then
				local ord
				if l == 48 or r == 48 then
					ord, li, ri = compare_left(left, right, li, ri)
				else
					ord, li, ri = compare_right(left, right, li, ri)
				end
				if ord ~= 0 then
					return ord
				end
				l = string.byte(left, li + 1)
				r = string.byte(right, ri + 1)
			else
				if insensitive then
					local ll = l
					local rr = r
					if ll >= 65 and ll <= 90 then
						ll = ll + 32
					end
					if rr >= 65 and rr <= 90 then
						rr = rr + 32
					end
					if ll ~= rr then
						return ll < rr and -1 or 1
					end
				elseif l ~= r then
					return l < r and -1 or 1
				end
				li = li + 1
				ri = ri + 1
				l = string.byte(left, li + 1)
				r = string.byte(right, ri + 1)
			end
		elseif l ~= nil then
			return 1
		elseif r ~= nil then
			return -1
		else
			return 0
		end
	end
end

-- Deterministic FNV-1a hash of a per-tab random seed and an entry's URL, so
-- the emulated random order is frozen for a given seed (no `math.random` in
-- the comparator) and a new seed reshuffles it.
local function random_key(seed, url)
	local s = tostring(seed) .. "\1" .. url
	local h = 2166136261
	for i = 1, #s do
		h = h ~ s:byte(i)
		h = (h * 16777619) & 0xFFFFFFFF
	end
	return h
end

-- Locale-independent byte comparison: the first differing byte decides, and a
-- proper prefix sorts first. Lua's native `<` compiles to `strcoll`, which is
-- locale-sensitive; stock Yazi sorts on encoded bytes instead.
local function bytes_lt(a, b)
	local la, lb = #a, #b
	local n = la < lb and la or lb
	for i = 1, n do
		local x, y = string.byte(a, i), string.byte(b, i)
		if x ~= y then
			return x < y
		end
	end
	return la < lb
end

local function bytes_le(a, b)
	return not bytes_lt(b, a)
end

local function bytes_cmp(a, b)
	if bytes_lt(a, b) then
		return -1
	elseif bytes_le(a, b) then
		return 0
	end
	return 1
end

-- ASCII-only lowercase fold (bytes 65-90 -> 97-122). Lua's `:lower()` is
-- ctype/locale dependent; stock Yazi folds ASCII only (`to_ascii_lowercase`).
local function ascii_lower(s)
	local out = {}
	for i = 1, #s do
		local b = string.byte(s, i)
		if b >= 65 and b <= 90 then
			b = b + 32
		end
		out[i] = string.char(b)
	end
	return table.concat(out)
end

-- pref is the tab's copied SortForm (or nil); unsupported by (nil/none/custom)
-- becomes alphabetical, dir_first defaults true and is never reversed, a primary
-- tie is broken by fallback (natural or basename bytes), and a final url compare
-- keeps the order deterministic.
function M.sort_children(files, pref)
	local by = pref and pref.by
	if
		by ~= "mtime"
		and by ~= "btime"
		and by ~= "extension"
		and by ~= "size"
		and by ~= "natural"
		and by ~= "random"
	then
		by = "alphabetical"
	end
	local reverse = (pref and pref.reverse) and true or false
	local dir_first = pref and pref.dir_first
	if dir_first == nil then
		dir_first = true
	end
	local sensitive = (pref and pref.sensitive) and true or false
	local fallback = pref and pref.fallback
	local seed = pref and pref.random_seed

	-- Numeric primaries (size/mtime/btime) keep numeric compare; string
	-- primaries (name/extension) compare by bytes, like stock Yazi.
	local numeric = by == "mtime" or by == "btime" or by == "size"
	local function key_cmp(x, y)
		if not numeric then
			return bytes_cmp(x, y)
		end
		if x < y then
			return -1
		elseif x > y then
			return 1
		end
		return 0
	end

	-- Lazy sibling require (not a top-level one), resolved once per flatten.
	local translit
	if by == "natural" and pref and pref.translit then
		translit = package.loaded["tree.translit"]
		if not translit then
			translit = require("tree.translit")
		end
	end

	local function name_key(f)
		local n = tostring(f.name)
		if not sensitive then
			n = ascii_lower(n)
		end
		return n
	end

	local function ext_key(f)
		if f.stat and f.stat.is_dir then
			return ""
		end
		local n = tostring(f.name)
		local dot = n:match(".*()%.")
		local e = dot and n:sub(dot + 1) or ""
		if not sensitive then
			e = ascii_lower(e)
		end
		return e
	end

	local function primary(f)
		if by == "mtime" then
			return (f.stat and f.stat.mtime) or 0
		elseif by == "btime" then
			return (f.stat and f.stat.btime) or 0
		elseif by == "extension" then
			return ext_key(f)
		elseif by == "size" then
			return (f.stat and f.stat.len) or 0
		end
		return name_key(f)
	end

	table.sort(files, function(a, b)
		local ad = (a.stat and a.stat.is_dir) and true or false
		local bd = (b.stat and b.stat.is_dir) and true or false
		if dir_first and ad ~= bd then
			return ad
		end
		local ord
		if by == "natural" then
			local na, nb = tostring(a.name), tostring(b.name)
			if translit then
				na, nb = translit.apply(na), translit.apply(nb)
			end
			ord = natsort(na, nb, not sensitive)
			if reverse then
				ord = -ord
			end
		elseif by == "random" then
			local pa = random_key(seed or 0, tostring(a.url))
			local pb = random_key(seed or 0, tostring(b.url))
			if pa ~= pb then
				if reverse then
					ord = pa > pb and -1 or 1
				else
					ord = pa < pb and -1 or 1
				end
			else
				ord = 0
			end
		else
			ord = key_cmp(primary(a), primary(b))
			if reverse then
				ord = -ord
			end
		end
		if ord ~= 0 then
			return ord < 0
		end
		local na, nb = tostring(a.name), tostring(b.name)
		if fallback == "natural" then
			ord = natsort(na, nb, false)
		elseif na ~= nb then
			ord = bytes_lt(na, nb) and -1 or 1
		else
			ord = 0
		end
		if reverse then
			ord = -ord
		end
		if ord ~= 0 then
			return ord < 0
		end
		local ua, ub = tostring(a.url), tostring(b.url)
		if reverse then
			return bytes_lt(ub, ua)
		end
		return bytes_lt(ua, ub)
	end)
end

-- Smart-case, literal (non-regex) basename substring match. A query holding an
-- ASCII uppercase character is case-sensitive, otherwise matching is
-- case-folded (case detection uses `%u`, unlike Yazi's Unicode `is_uppercase()`).
function M.match_name(name, query)
	if not query or query == "" then
		return true
	end
	if query:find("%u") then
		return name:find(query, 1, true) ~= nil
	end
	return name:lower():find(query:lower(), 1, true) ~= nil
end

return M
