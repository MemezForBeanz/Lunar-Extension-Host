--- The Now Playing tab. Controls sit in an opaque bar under the picture, not over it, so
-- nothing covers the film while the window is windowed and no overlay is needed.
-- @module ui.player

local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local RowList = require("core.ui.RowList")
local CellGrid = require("core.ui.CellGrid")
local SeekBar = require("core.ui.SeekBar")
local AnimatedIcon = require("core.ui.AnimatedIcon")
local VideoHost = require("core.ui.VideoHost")

local M = {}

local ART_WIDTH = 240

local function clock(seconds)
	seconds = math.floor(seconds or 0)
	local h, m, s = math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60
	if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
	return string.format("%d:%02d", m, s)
end

--- Build the tab.
-- @tparam table ctx host context
-- @tparam table opts `animate`, `sample` (a film shown as queued when nothing plays), `owner`
function M.new(ctx, opts)
	local iup = ctx.iup
	local api = {}
	local sample = opts.sample
	local duration = (sample.minutes or 0) * 60
	local position = math.floor(duration * (sample.progress or 0))

	local requirements = Kit.requirements(iup, { ready = "Player ready" })
	requirements.set({ VideoHost.requirement() })

	local art = CellGrid.new(iup, { count = opts.art and 1 or 0, cell_width = ART_WIDTH, aspect = "2:3", show_text = false,
		gutter = 0, padding = 0, value = function() return nil end })
	iup.SetAttribute(art.widget, "RASTERSIZE", L.size(ART_WIDTH, ART_WIDTH * 3 / 2))
	iup.SetAttribute(art.widget, "EXPAND", "NO")
	iup.SetAttribute(art.widget, "CANFOCUS", "NO")
	iup.SetAttribute(art.widget, "FLATSCROLLBAR", "NO")
	if opts.cache and opts.art then
		api.tick = CellGrid.posters(art, opts.cache, function() return opts.art end)
	end
	local paused = iup.flatlabel({ TITLE = "Paused at " .. clock(position), THEMEROLE = "empty_title", ALIGNMENT = "ACENTER" })
	local resume = iup.flatlabel({ TITLE = "Press Space to carry on.", THEMEROLE = "empty_hint", ALIGNMENT = "ACENTER" })
	local picture = iup.vbox({
		iup.fill({}), iup.hbox({ iup.fill({}), art.widget, iup.fill({}) }),
		iup.hbox({ iup.fill({}), paused, iup.fill({}) }), iup.hbox({ iup.fill({}), resume, iup.fill({}) }),
		iup.fill({}), GAP = L.gap(3), MARGIN = "0x0", EXPAND = "YES",
	})

	local bar = SeekBar.new(iup, { max = duration, on_seek = function() end })
	iup.SetAttribute(bar.widget, "EXPAND", "HORIZONTAL")
	bar:setValue(position)
	bar:setBuffered({ { 0, position + 240 } })
	bar:setMarks({ { at = 0, to = 95 }, { at = 1320 }, { at = 2700 }, { at = 4140 }, { at = duration - 480, to = duration } })

	local glyph = AnimatedIcon.new(iup, { animate = opts.animate, size = 20, role = "text" })
	local playing = false
	local toggle = iup.flatbutton({ TITLE = "", THEMEROLE = "icon_btn", TIP = "Play or pause (Space)", RASTERSIZE = "40x40" })
	glyph.paint = function(path)
		Kit.bindIcon(iup, toggle, (path:gsub("%.svg$", "")), { size = 20, role = "text" })
	end
	glyph:_draw()
	function toggle:flat_action()
		playing = not playing
		glyph:setPlaying(playing)
		return iup.DEFAULT
	end

	local function tool(icon, tip)
		local button = Kit.button(iup, { icon = icon, tip = tip, role = "icon_btn" })
		iup.SetAttribute(button, "RASTERSIZE", "32x32")
		return button
	end

	local time = iup.flatlabel({ TITLE = clock(position) .. " / " .. clock(duration) })
	local title = iup.flatlabel({ TITLE = sample.title, THEMEROLE = "sectiontitle" })
	local detail = L.hint(iup, string.format("%s · %s · %s", sample.resolution or "", sample.dynamic or "", sample.audio or ""))
	local left = iup.vbox({ title, detail, GAP = L.gap(1), MARGIN = "0x0" })
	local transport = iup.vbox({
		bar.widget,
		iup.hbox({
			tool("skip--back--filled", "Previous"), toggle, tool("skip--forward--filled", "Next"),
			left, iup.fill({}), time,
			tool("settings--adjust", "Audio and subtitles"), tool("fit-to-screen", "Fullscreen (F)"),
			GAP = L.gap(3), ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL",
		}),
		GAP = L.gap(2), MARGIN = L.margin(5, 3), EXPAND = "HORIZONTAL",
	})

	local chapters = {
		{ title = "Opening", column1 = "0:00" }, { title = "The survey", column1 = "22:00" },
		{ title = "Low water", column1 = "45:00" }, { title = "The boundary stone", column1 = "1:09:00" },
		{ title = "Credits", column1 = "2:00:00" },
	}
	local queue = {
		{ title = "Glass Harbour", secondary = "1 h 44 min", column1 = "Next" },
		{ title = "Paper Orchard", secondary = "1 h 52 min" },
		{ title = "Six Bells", secondary = "1 h 35 min" },
	}
	local chapter_list = RowList.new(iup, { rows = chapters, row_height = 32, column_widths = { 72 } })
	local queue_list = RowList.new(iup, { rows = queue, row_height = 44, column_widths = { 56 } })
	iup.SetAttribute(chapter_list.widget, "EXPAND", "YES")
	iup.SetAttribute(queue_list.widget, "EXPAND", "YES")

	local rail = iup.vbox({
		iup.hbox({ RASTERSIZE = L.size(L.SIDE.narrow) }),
		L.sectionTitle(iup, "Up next"), queue_list.widget,
		L.sectionTitle(iup, "Chapters"), chapter_list.widget,
		GAP = L.gap(3), MARGIN = "0x0", EXPAND = "VERTICAL",
	})

	local stage = iup.vbox({ requirements.widget, picture, transport, GAP = L.gap(3), MARGIN = "0x0", EXPAND = "YES" })
	api.widget = iup.hbox({ stage, rail, GAP = L.gap(5), MARGIN = L.margin(5), EXPAND = "YES" })

	function api.fit(width)
		Kit.show(iup, rail, width >= 900, bar.widget)
	end

	function api.close()
		glyph:stop()
	end

	return api
end

return M
