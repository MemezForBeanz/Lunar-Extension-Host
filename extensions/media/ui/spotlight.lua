--- The Home spotlight: one title at a time, on a surface tinted from its art.
-- The art dissolves into that surface, so picture and words read as one thing. Dots step
-- through a short list, and it moves on by itself until someone picks a dot or a card.
-- @module ui.spotlight

local ffi = require("ffi")
local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local CellGrid = require("core.ui.CellGrid")
local tint = require("libs.tint")

local M = {}

M.HEIGHT = 296
local ART_HEIGHT = 284
local ART_WIDTH = math.floor(ART_HEIGHT * 16 / 9)
local RING = 6
local FADE = 0.42             -- the share of the art, from its right edge, that dissolves
local EDGE = 0.05             -- the share that softens on the other three sides
local ROTATE_TICKS = 300      -- about nine seconds of 30 ms ticks
local DOT = 16
local TITLE_FONT = "Segoe UI Semibold, 28"
local TEXT = "255 255 255"
local TEXT_MUTED = "204 204 216"

local function runtime(minutes)
	if not minutes or minutes < 1 then return nil end
	if minutes < 60 then return minutes .. " min" end
	return string.format("%d h %d min", math.floor(minutes / 60), minutes % 60)
end

--- The line under the title.
-- @tparam table item
-- @treturn string
function M.meta(item)
	local parts = {}
	if item.year and item.year > 0 then parts[#parts + 1] = tostring(item.year) end
	if item.kind == "show" then
		parts[#parts + 1] = (item.seasons or 0) .. " season" .. (item.seasons == 1 and "" or "s")
	else
		local length = runtime(item.minutes)
		if length then parts[#parts + 1] = length end
	end
	parts[#parts + 1] = item.resolution
	if item.dynamic and item.dynamic ~= "SDR" then parts[#parts + 1] = item.dynamic end
	return table.concat(parts, " · ")
end

local function smooth(t)
	if t <= 0 then return 0 elseif t >= 1 then return 1 end
	return t * t * (3 - 2 * t)
end

-- Melt every edge of the art into the surface, in a copy because cached pixels are shared. The
-- right edge goes furthest, so the picture runs into the words.
local function dissolve(buffer, pixels, stride, w, h, colour)
	local source = ffi.cast("const uint8_t*", pixels)
	ffi.copy(buffer, source, stride * h)
	local right_start, right_span = w * (1 - FADE), w * FADE
	local side, tall = w * EDGE, h * EDGE
	local sr, sg, sb = colour[1], colour[2], colour[3]
	for y = 0, h - 1 do
		local vertical = smooth(math.min(y, h - 1 - y) / tall)
		local row = y * stride
		for x = 0, w - 1 do
			local keep = vertical * smooth(x / side) * (1 - smooth((x - right_start) / right_span))
			if keep < 1 then
				local rest, at = 1 - keep, row + x * 4
				buffer[at] = buffer[at] * keep + sb * rest
				buffer[at + 1] = buffer[at + 1] * keep + sg * rest
				buffer[at + 2] = buffer[at + 2] * keep + sr * rest
			end
		end
	end
end

--- Build the spotlight.
-- @tparam table ctx host context
-- @tparam table opts `cache`, `art(item)`, `on_play(item)`, `on_info(item)`
-- @treturn table `widget`, `setItems(list)`, `show(item)`, `tick()`
function M.new(ctx, opts)
	local iup = ctx.iup
	local cache = opts.cache
	local api = {}
	local items, index, current = {}, 1, nil
	local ticks, held = 0, false
	local colour = tint.FALLBACK
	local composed = { key = nil, buffer = nil }

	local art = CellGrid.new(iup, { count = 1, cell_width = ART_WIDTH, aspect = "16:9", show_text = false,
		gutter = 0, padding = 0, value = function() return nil end, role = "flatgrid_plain" })
	iup.SetAttribute(art.widget, "RASTERSIZE", L.size(ART_WIDTH + 2 * RING, ART_HEIGHT + 2 * RING))
	iup.SetAttribute(art.widget, "EXPAND", "NO")
	iup.SetAttribute(art.widget, "CANFOCUS", "NO")
	iup.SetAttribute(art.widget, "FLATSCROLLBAR", "NO")
	local drain = cache and CellGrid.posters(art, cache, function()
		return current and opts.art(current) or nil
	end)
	local raw_bits = art.bits

	local eyebrow = iup.flatlabel({ TITLE = "", THEMEROLE = "reading_muted" })
	local title = iup.flatlabel({ TITLE = "", THEMEROLE = "pagetitle" })
	local meta = iup.flatlabel({ TITLE = "", THEMEROLE = "reading_muted" })
	local overview = iup.flatlabel({ TITLE = "", THEMEROLE = "reading", TEXTWRAP = "YES", EXPAND = "HORIZONTAL",
		ALIGNMENT = "ALEFT:ATOP", RASTERSIZE = "x44" })
	local play = Kit.button(iup, { title = "Play", icon = "play--filled--alt", role = "primary_btn",
		action = function() if current then opts.on_play(current) end end })
	iup.SetAttribute(play, "RASTERSIZE", "132x40")
	local info = Kit.button(iup, { title = "More info", role = "actionbutton",
		action = function() if current then opts.on_info(current) end end })
	iup.SetAttribute(info, "RASTERSIZE", "112x40")

	local dots = iup.hbox({ GAP = L.gap(1), MARGIN = "0x0", ALIGNMENT = "ACENTER" })
	local dot_widgets = {}

	local words = iup.vbox({
		iup.fill({}), eyebrow, title, meta, overview,
		iup.hbox({ play, info, GAP = L.gap(2), MARGIN = "0x" .. L.gap(2) }),
		iup.fill({}), dots,
		GAP = L.gap(1), MARGIN = L.gap(3) .. "x" .. L.gap(3), EXPAND = "YES",
	})

	api.widget = iup.flatframe({
		iup.hbox({ art.widget, words, GAP = "0", MARGIN = "0x0", EXPAND = "HORIZONTAL" }),
		TITLE = "", THEMEROLE = "settingscard", MARGIN = "0x0", EXPAND = "HORIZONTAL",
		RASTERSIZE = "x" .. M.HEIGHT,
	})

	local painted = { title, meta, overview, eyebrow, art.widget, dots }

	-- A theme change paints over these, so they are put back on the next tick.
	local function wear()
		local wanted = tint.attr(colour)
		if iup.GetAttribute(api.widget, "BGCOLOR") == wanted and iup.GetAttribute(title, "BGCOLOR") == wanted then return end
		iup.SetAttribute(api.widget, "BGCOLOR", wanted)
		iup.SetAttribute(api.widget, "FRAMECOLOR", wanted)
		iup.SetAttribute(api.widget, "BORDERSHEENCOLOR", wanted)
		for _, widget in ipairs(painted) do iup.SetAttribute(widget, "BGCOLOR", wanted) end
		for _, dot in ipairs(dot_widgets) do iup.SetAttribute(dot, "BGCOLOR", wanted) end
		iup.SetAttribute(title, "FGCOLOR", TEXT)
		iup.SetAttribute(title, "FONT", TITLE_FONT)
		iup.SetAttribute(overview, "FGCOLOR", TEXT)
		iup.SetAttribute(meta, "FGCOLOR", TEXT_MUTED)
		iup.SetAttribute(eyebrow, "FGCOLOR", TEXT_MUTED)
		-- The second action stays quieter than Play in either theme: a lift of the same surface.
		local lift = tint.attr({ math.min(colour[1] + 34, 255), math.min(colour[2] + 34, 255), math.min(colour[3] + 34, 255) })
		iup.SetAttribute(info, "BGCOLOR", lift)
		iup.SetAttribute(info, "FGCOLOR", TEXT)
		iup.SetAttribute(info, "BORDERCOLOR", lift)
		iup.Update(api.widget)
	end

	art.bits = raw_bits and function(pos, w, h)
		local pixels, stride = raw_bits(pos, w, h)
		if not pixels then return nil end
		local key = tostring(current and current.id) .. "@" .. w .. "x" .. h .. "@" .. tostring(opts.art(current))
		if composed.key ~= key then
			colour = tint.ofPixels(pixels, stride, w, h)
			composed.buffer = composed.buffer or ffi.new("uint8_t[?]", stride * h)
			if ffi.sizeof(composed.buffer) < stride * h then composed.buffer = ffi.new("uint8_t[?]", stride * h) end
			dissolve(composed.buffer, pixels, stride, w, h, colour)
			composed.key = key
			wear()
		end
		return composed.buffer, stride
	end or nil

	local function mark_dots()
		for i, dot in ipairs(dot_widgets) do
			Kit.bindIcon(iup, dot, "dot-mark", { size = i == index and 16 or 10, role = "on_accent" })
		end
	end

	--- Show one title.
	-- @tparam table item
	-- @tparam[opt] boolean hold keep it here until the next pick, because someone chose it
	function api.show(item, hold)
		if not item then return end
		current = item
		held = hold == true
		ticks = 0
		for i, candidate in ipairs(items) do
			if candidate == item then index = i end
		end
		local started = (item.progress or 0) > 0 and item.progress < 1
		iup.SetAttribute(eyebrow, "TITLE", started and "Pick up where you left off" or (item.eyebrow or "New in your library"))
		iup.SetAttribute(title, "TITLE", item.title)
		iup.SetAttribute(meta, "TITLE", M.meta(item))
		iup.SetAttribute(overview, "TITLE", item.overview or "")
		Kit.show(iup, overview, (item.overview or "") ~= "", title)
		iup.SetAttribute(play, "TITLE", started and "Resume" or "Play")
		if not opts.art(item) then
			colour = tint.ofTitle(item.title)
			wear()
		end
		mark_dots()
		art:refreshCell(1)
	end

	function api.current() return current end

	--- Set the titles the dots step through.
	function api.setItems(list)
		items = list or {}
		index = 1
		for i = #dot_widgets, 1, -1 do
			iup.Destroy(dot_widgets[i])
			dot_widgets[i] = nil
		end
		for i, item in ipairs(items) do
			local dot = iup.flatbutton({ TITLE = "", TIP = item.title, THEMEROLE = "icon_btn", RASTERSIZE = L.size(DOT, DOT) })
			function dot:flat_action()
				api.show(items[i], true)
				return iup.DEFAULT
			end
			dot_widgets[i] = dot
			iup.Append(dots, dot)
			if iup.GetAttribute(api.widget, "WID") then iup.Map(dot) end
		end
		api.show(items[1])
	end

	function api.tick()
		if drain then drain() end
		wear()
		if held or #items < 2 then return end
		ticks = ticks + 1
		if ticks >= ROTATE_TICKS then api.show(items[index % #items + 1]) end
	end

	return api
end

return M
