--- @since 26.9.1
--- @sync entry
--- Learning spike: toggleable tree-view layout experiment.

local M = {}

local saved_layout
local enabled = false
local announce_layout = false

function M:setup()
	if saved_layout then
		return
	end

	saved_layout = Tab.layout
	ya.dbg("[tree-dbg] setup installed; Tab=", tostring(Tab), "saved_layout=", tostring(saved_layout))

	Tab.layout = function(self, ...)
		saved_layout(self, ...)

		if enabled then
			if announce_layout then
				announce_layout = false
				ya.dbg("[tree-dbg] applying enabled layout")
			end
			local c = self._chunks
			local freed = c[1].w -- collapse the parent column
			self._chunks = {
				ui.Rect { x = c[1].x, y = c[1].y, w = 0, h = c[1].h },
				ui.Rect { x = c[2].x - freed, y = c[2].y, w = c[2].w + freed, h = c[2].h },
				c[3], -- preview pane is preserved
			}
		end
	end
end

function M:toggle()
	enabled = not enabled
	if enabled then
		announce_layout = true
	end
	ya.dbg("[tree-dbg] toggle enabled=", tostring(enabled))
	ui.render()
end

function M:entry(job)
	ya.dbg(
		"[tree-dbg] entry args1=",
		tostring(job and job.args and job.args[1]),
		"Tab=",
		tostring(Tab),
		"enabled=",
		tostring(enabled)
	)
	if job and job.args and job.args[1] == "toggle" then
		M:toggle()
	end
end

return M
