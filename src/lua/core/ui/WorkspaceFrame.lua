--- Rounded workspace junctions against the top, left and bottom toolbars.
-- Small native canvas bands keep child windows out of the rounded corners.
--
-- Lunar's glass palettes (ImGui host) make the workspace a matte sheet lying on the
-- backdrop: the sheet (role `workspace_sheet`) paints itself as a rounded card, an outer
-- margin (`glassReveal`) lets the backdrop show around it, and the bands only hold the
-- children out of the corners and draw nothing, so the corners show the backdrop and the
-- chrome behind them continuously. Other themes keep the bands' painted corners.
-- @module core.ui.WorkspaceFrame
local Reactor = require("core.ui.ThemeReactor")
local Frame = {}

local RADIUS = 12

--- Is the active theme a glass sheet on this host? (Glass off keeps the same layout.)
function Frame.sheetMode(iup)
	local p = Reactor.palette() or {}
	return rawget(iup, "_IMGUI") ~= nil and p.glass == true, p
end

--- The band height and the reveal around the sheet, for the active theme.
function Frame.metrics(iup)
	local sheet, p = Frame.sheetMode(iup)
	if not sheet then return RADIUS, 0 end
	-- Five rows short of the radius: below that the corner's curve is within a pixel of
	-- the edge, so the children can start there and the page keeps its room.
	return math.max(0, (p.radiusSheet or 14) - 5), p.glassReveal or 8
end

--- Vertical pixels the frame adds around the workspace (both bands and the reveal).
function Frame.verticalChrome(iup)
	local band, reveal = Frame.metrics(iup)
	return 2 * band + 2 * reveal
end

function Frame.wrap(iup, child)
	local bands = {}
	local function band(bottom)
		local canvas = iup.canvas({ BORDER = "NO", CANFOCUS = "NO", EXPAND = "HORIZONTAL",
			RASTERSIZE = "x" .. RADIUS, THEMEROLE = "workspace_band" })
		function canvas:action()
			-- The sheet paints the rounded corner; the band is a spacer.
			if Frame.sheetMode(iup) then return iup.DEFAULT end
			local radius = RADIUS
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
	local sheet = iup.vbox({ band(false), child, band(true), MARGIN = "0x0", GAP = "0", EXPAND = "YES",
		THEMEROLE = "workspace_sheet" })
	local widget = iup.vbox({ sheet, MARGIN = "0x0", GAP = "0", EXPAND = "YES" })
	local applied
	local function fit()
		local band_h, reveal = Frame.metrics(iup)
		local key = band_h .. ":" .. reveal
		if key == applied then return false end
		applied = key
		for _, canvas in ipairs(bands) do iup.SetAttribute(canvas, "RASTERSIZE", "x" .. band_h) end
		iup.SetAttribute(widget, "MARGIN", reveal .. "x" .. reveal)
		return true
	end
	fit()
	-- Keep the registered controller alive for exactly as long as its widget.
	local controller = { _onThemeApply = function()
		if fit() then iup.Refresh(widget) end
		for _, canvas in ipairs(bands) do iup.Update(canvas) end
	end }
	Reactor.register(controller)
	function widget:destroy_cb() controller._onThemeApply = nil end
	return widget
end

--- The dock under the sheet (the media player): inset from the sides like the sheet, so
-- its card floats as a capsule over the backdrop in glass themes.
function Frame.dock(iup, slot)
	local applied
	local controller = { _onThemeApply = function()
		local _, reveal = Frame.metrics(iup)
		-- Sides only: the player card keeps its own space above and below.
		local margin = reveal .. "x0"
		if margin ~= applied then
			applied = margin
			iup.SetAttribute(slot, "MARGIN", margin)
			iup.Refresh(slot)
		end
	end }
	Reactor.register(controller)
	-- The registry is weak: the callback keeps the controller alive with the slot.
	function slot:destroy_cb() controller._onThemeApply = nil end
	return slot
end

return Frame
