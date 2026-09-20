-- Pure ordering/matching helpers for the async rebuild flatten pass.

local M = {}

-- Alphabetical, directories first.
function M.sort_children(files)
	table.sort(files, function(a, b)
		local ad = (a.cha and a.cha.is_dir) and true or false
		local bd = (b.cha and b.cha.is_dir) and true or false
		if ad ~= bd then
			return ad
		end
		return tostring(a.name) < tostring(b.name)
	end)
end

-- Smart-case, literal (non-regex) basename substring match. A query holding an
-- uppercase character is case-sensitive, otherwise matching is case-folded.
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
