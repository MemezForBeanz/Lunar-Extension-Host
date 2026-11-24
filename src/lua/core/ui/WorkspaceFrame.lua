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

-- The window class the insets follow (Frame.setWidth): wide from this client width on.
local WIDE_FROM = 1440
local wide = true
-- The left rail's current width (main.lua tells), so the sheet's left edge stays put.
local rail_width = function() return 48 end
-- Frames to refit when the width class or the rail changes (widget -> refit).
local fitters = setmetatable({}, { __mode = "k" })

--- The band height and the sheet's insets ({ band, left, top, right, bottom }), for the
-- active theme and window class. Outside glass sheets: the old bands and no insets.
function Frame.metrics(iup)
	local sheet, p = Frame.sheetMode(iup)
	if not sheet then return { band = RADIUS, left = 0, top = 0, right = 0, bottom = 0 } end
	-- Two rows short of the radius: there the corner's curve is 0.09 px from the edge, so
	-- the children's square fills, which start below the band, never cut into the rounded
	-- corner (five rows short they covered most of a pixel of it, a visible notch).
	local band = math.max(0, (p.radiusSheet or 14) - 2)
	local m = (wide and p.glassSheetWide or p.glassSheetNarrow) or {}
	local side = m.side or p.glassReveal or 8
	-- The sheet starts at `left` from the window edge: the strip beside the rail stays bare.
	local left = math.max(side, (m.left or 0) - (rail_width() or 0))
	-- (narrow, the reveal above and below is 2 px slimmer: the full-height bands took that room)
	return { band = band, left = left, top = m.top or side, right = side, bottom = m.bottom or side }
end

--- Vertical pixels the frame adds around the workspace (both bands and the insets).
function Frame.verticalChrome(iup)
	local m = Frame.metrics(iup)
	return 2 * m.band + m.top + m.bottom
end

local function refit_all()
	for _, fit in pairs(fitters) do fit() end
end

--- The client width decides wide or narrow insets (called on resize).
function Frame.setWidth(w)
	local now = (w or 0) >= WIDE_FROM
	if now ~= wide then wide = now; refit_all() end
end

--- How wide the rail is now; refits when called with a new reader or on `Frame.refit()`.
function Frame.setRail(reader) rail_width = reader or rail_width; refit_all() end
function Frame.refit() refit_all() end

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
	-- Fixed spacers give the sheet its four insets (a box's MARGIN is symmetric).
	local left, right = iup.fill({ RASTERSIZE = "0x" }), iup.fill({ RASTERSIZE = "0x" })
	local top, bottom = iup.fill({ RASTERSIZE = "x0" }), iup.fill({ RASTERSIZE = "x0" })
	local widget = iup.hbox({ left, iup.vbox({ top, sheet, bottom, MARGIN = "0x0", GAP = "0", EXPAND = "YES" }), right,
		MARGIN = "0x0", GAP = "0", EXPAND = "YES" })
	local applied
	local function fit()
		local m = Frame.metrics(iup)
		local key = table.concat({ m.band, m.left, m.top, m.right, m.bottom }, ":")
		if key == applied then return false end
		applied = key
		for _, canvas in ipairs(bands) do iup.SetAttribute(canvas, "RASTERSIZE", "x" .. m.band) end
		iup.SetAttribute(left, "RASTERSIZE", m.left .. "x")
		iup.SetAttribute(right, "RASTERSIZE", m.right .. "x")
		iup.SetAttribute(top, "RASTERSIZE", "x" .. m.top)
		iup.SetAttribute(bottom, "RASTERSIZE", "x" .. m.bottom)
		return true
	end
	fit()
	fitters[widget] = function() if fit() then iup.Refresh(widget) end end
	-- Keep the registered controller alive for exactly as long as its widget.
	local controller = { _onThemeApply = function()
		if fit() then iup.Refresh(widget) end
		for _, canvas in ipairs(bands) do iup.Update(canvas) end
	end }
	Reactor.register(controller)
	function widget:destroy_cb() controller._onThemeApply = nil end
	return widget
end

--- The dock under the sheet (the media player): in glass themes its card floats as a
-- capsule inset from the sheet's sides (`glassTransport`) and above the status strip.
-- Returns the box to lay out; `slot` stays the box docks are added to.
function Frame.dock(iup, slot)
	local left, right = iup.fill({ RASTERSIZE = "0x" }), iup.fill({ RASTERSIZE = "0x" })
	local above, below = iup.fill({ RASTERSIZE = "x4" }), iup.fill({ RASTERSIZE = "x4" })
	local box = iup.vbox({ above, iup.hbox({ left, slot, right, MARGIN = "0x0", GAP = "0" }), below,
		MARGIN = "0x0", GAP = "0", EXPAND = "HORIZONTAL" })
	local applied
	local function fit()
		local sheet, p = Frame.sheetMode(iup)
		local m = Frame.metrics(iup)
		local t = sheet and p.glassTransport or {}
		local inset = (wide and t.wide or t.narrow) or 0
		-- A dock keeps 4 px above and below; a glass capsule sits on the sheet's own inset
		-- and keeps `below` px over the status strip.
		local top_gap, gap = sheet and 0 or 4, sheet and (t.below or 8) or 4
		-- No space at all while no dock shows.
		local shown = false
		local child = iup.GetNextChild(slot, nil)
		while child do
			if iup.GetAttribute(child, "VISIBLE") ~= "NO" and iup.GetAttribute(child, "FLOATING") ~= "YES" then shown = true end
			child = iup.GetNextChild(slot, child)
		end
		if not shown then top_gap, gap = 0, 0 end
		local key = table.concat({ m.left + inset, m.right + inset, top_gap, gap }, ":")
		if key == applied then return false end
		applied = key
		iup.SetAttribute(left, "RASTERSIZE", (sheet and m.left + inset or 0) .. "x")
		iup.SetAttribute(right, "RASTERSIZE", (sheet and m.right + inset or 0) .. "x")
		iup.SetAttribute(above, "RASTERSIZE", "x" .. top_gap)
		iup.SetAttribute(below, "RASTERSIZE", "x" .. gap)
		return true
	end
	fit()
	local refit = function() if fit() then iup.Refresh(box) end end
	fitters[box] = refit
	local controller = { _onThemeApply = refit }
	Reactor.register(controller)
	-- The registry is weak: the callback keeps the controller alive with the box.
	function box:destroy_cb() controller._onThemeApply = nil end
	return box
end

return Frame
