--- One quiet route back to a failing source, shared by Home and library views.
local Kit = require("core.ui.Kit")
local Reactor = require("core.ui.ThemeReactor")
local M = {}
function M.new(ctx, model, open)
	local iup = ctx.iup
	local notice = Kit.notification(iup, { kind = "error", title = "", action = { title = "Manage sources", action = open } })
	local line = notice.widget
	-- One surface behind the message and both actions, including the support rail.
	local rail = (iup.canvas or iup.flatlabel)({ TITLE = "", BORDER = "NO", CANFOCUS = "NO", RASTERSIZE = "3x", EXPAND = "VERTICAL", THEMEROLE = "toast_bar_error" })
	local surface = iup.flatframe and iup.flatframe({ iup.hbox({rail, line, GAP="0", MARGIN="0x0", EXPAND="HORIZONTAL"}), TITLE = "", FRAME = "NO", MARGIN = "0x0", EXPAND = "HORIZONTAL", THEMEROLE = "page_column" }) or line
	local api = { widget = surface }
	if iup.GetChild then
		local dismiss = iup.GetChild(line, 2)
		if dismiss then dismiss.flat_action = function()
			Kit.show(iup, surface, false)
			if iup.Refresh then iup.Refresh(surface) end
			return iup.DEFAULT
		end end
	end
	function api:_afterThemePass()
		local p = Reactor.palette()
		local bg = p.layer03 or p.layer02 or p.bg
		if not bg then return end
		iup.SetAttribute(line, "BGCOLOR", bg)
		iup.SetAttribute(surface, "BGCOLOR", bg)
		iup.SetAttribute(iup.GetChild(surface, 0), "BGCOLOR", bg)
		if iup.GetChild then
			for n = 0, 2 do
				local child = iup.GetChild(line, n)
				if child then iup.SetAttribute(child, "BGCOLOR", bg) end
			end
		end
		iup.SetAttribute(rail, "BGCOLOR", p.error)
	end
	Reactor.register(api)
	function api.setModel(data)
		local text
		local count = 0
		for _, origin in ipairs(data.origins or {}) do
			if origin.status == "failed" then count = count + 1 end
		end
		for _, problem in ipairs(data.attention or {}) do
			if problem.kind == "source" then text = problem.title:gsub(": source failed$", "") .. ": " .. problem.wrong; break end
		end
		if not text then
			for _, origin in ipairs(data.origins or {}) do
				if origin.status == "failed" then text = origin.name .. ": " .. (origin.error or "could not connect"); break end
			end
		end
		notice:setTitle(text or "")
		api.message = text
		count = text and math.max(1, count) or 0
		api.summary = count > 0 and (count .. (count == 1 and " source unavailable" or " sources unavailable")) or nil
		Kit.show(iup, surface, text ~= nil)
		api:_afterThemePass()
	end
	api.tick = function() api:_afterThemePass() end
	api.setModel(model)
	return api
end
return M
