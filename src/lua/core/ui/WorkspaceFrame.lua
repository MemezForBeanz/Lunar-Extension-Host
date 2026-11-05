--- Rounded workspace junctions against the top, left and bottom toolbars.
-- Small native canvas bands keep child windows out of the rounded corners.
-- @module core.ui.WorkspaceFrame
local Reactor = require("core.ui.ThemeReactor")
local Frame = {}

function Frame.wrap(iup, child)
	local radius, bands = 12, {}
	local function band(bottom)
		local canvas = iup.canvas({ BORDER = "NO", CANFOCUS = "NO", EXPAND = "HORIZONTAL",
			RASTERSIZE = "x" .. radius })
		function canvas:action()
			local manager = Reactor.themeManager()
			local theme = manager and manager:activeTheme()
			local rules = theme and theme:rules() or {}
			local p = Reactor.palette()
			local outside = (rules.dialog or {}).bg or p.bg or "30 30 30"
			local inside = (rules.flattabs or {}).bg or p.surface or outside
			iup.DrawBegin(canvas)
			local width = iup.DrawGetSize(canvas)
			iup.SetAttribute(canvas, "DRAWSTYLE", "FILL")
			iup.SetAttribute(canvas, "DRAWCOLOR", outside)
			iup.DrawRectangle(canvas, 0, 0, width - 1, radius - 1)
			for row = 0, radius - 1 do
				local dy = radius - row - 0.5
				local inset = radius - math.sqrt(radius * radius - dy * dy)
				local y = bottom and radius - row - 1 or row
				iup.SetAttribute(canvas, "DRAWCOLOR", inside)
				iup.DrawLine(canvas, math.ceil(inset), y, width - 1, y)
				local coverage = math.ceil(inset) - inset
				local a, b, mixed = {}, {}, {}
				for v in outside:gmatch("%d+") do a[#a + 1] = tonumber(v) end
				for v in inside:gmatch("%d+") do b[#b + 1] = tonumber(v) end
				for i = 1, 3 do mixed[i] = math.floor(a[i] + (b[i] - a[i]) * coverage + 0.5) end
				iup.SetAttribute(canvas, "DRAWCOLOR", table.concat(mixed, " "))
				iup.DrawLine(canvas, math.floor(inset), y, math.floor(inset), y)
			end
			iup.DrawEnd(canvas)
			return iup.DEFAULT
		end
		bands[#bands + 1] = canvas
		return canvas
	end
	local widget = iup.vbox({ band(false), child, band(true), MARGIN = "0x0", GAP = "0", EXPAND = "YES" })
	-- Keep the registered controller alive for exactly as long as its widget.
	local controller = { _onThemeApply = function() for _, canvas in ipairs(bands) do iup.Update(canvas) end end }
	Reactor.register(controller)
	function widget:destroy_cb() controller._onThemeApply = nil end
	return widget
end

return Frame
