--- One quiet route back to a failing source, shared by Home and library views.
local Kit = require("core.ui.Kit")
local M = {}
function M.new(ctx, model, open)
	local iup = ctx.iup
	local line = iup.flatbutton({ TITLE = "", THEMEROLE = "link_btn", EXPAND = "HORIZONTAL",
		ALIGNMENT = "ALEFT:ACENTER", flat_action = function() if open then open() end end })
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
		iup.SetAttribute(line, "TITLE", text or "")
		Kit.show(iup, line, text ~= nil)
	end
	api.setModel(model)
	return api
end
return M
