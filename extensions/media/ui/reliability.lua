--- One quiet route back to a failing source, shared by Home and library views.
local Kit = require("core.ui.Kit")
local M = {}
function M.new(ctx, model, open)
	local iup = ctx.iup
	local notice = Kit.notification(iup, { kind = "error", title = "", action = { title = "Manage sources", action = open } })
	local line = notice.widget
	local api = { widget = line }
	function api.setModel(data)
		local text
		for _, problem in ipairs(data.attention or {}) do
			if problem.kind == "source" then text = problem.title:gsub(": source failed$", "") .. ": " .. problem.wrong; break end
		end
		if not text then
			for _, origin in ipairs(data.origins or {}) do
				if origin.status == "failed" then text = origin.name .. ": " .. (origin.error or "could not connect"); break end
			end
		end
		notice:setTitle(text or "")
		Kit.show(iup, line, text ~= nil)
	end
	api.setModel(model)
	return api
end
return M
