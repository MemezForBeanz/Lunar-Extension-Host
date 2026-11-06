--- The player dock: what is playing stays in reach from every tab.
-- It floats above the status bar as one card, so a film keeps its transport while you browse
-- a library, a settings page or another extension. Now Playing has its own controls, so the
-- dock steps aside there.
-- @module ui.dock

local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local CellGrid = require("core.ui.CellGrid")
local SeekBar = require("core.ui.SeekBar")
local playback = require("libs.playback")

local M = {}

local ART_WIDTH = 32
local ART_EDGE = 12     -- the grid keeps 6 px each side for selection rings
local SIDE_WIDTH = 300  -- both ends share a width, so the transport stays centred
local VOLUME_WIDTH = 88
local BUTTON = 36
local PLAY = 36
local ICON = 24
local TIME_WIDTH = 104  -- both sides of the seek bar, so the bar and the transport share a centre

--- Build the dock.
-- @tparam table ctx host context
-- @tparam table opts `player` (from `ui.player`), `open()`, `owner`, `cache`, `art_path()`
-- @treturn table `tick()`, `setAway(boolean)`, `refresh()`
function M.new(ctx, opts)
	local iup = ctx.iup
	local player = opts.player
	local api = {}
	local away, shown = false, nil

	local art = CellGrid.new(iup, { count = 1, cell_width = ART_WIDTH, aspect = "2:3", show_text = false,
		gutter = 0, padding = 0, value = function() return nil end, role = "flatgrid_plain" })
	iup.SetAttribute(art.widget, "RASTERSIZE", L.size(ART_WIDTH + ART_EDGE, ART_WIDTH * 3 / 2 + ART_EDGE))
	iup.SetAttribute(art.widget, "EXPAND", "NO")
	iup.SetAttribute(art.widget, "CANFOCUS", "NO")
	iup.SetAttribute(art.widget, "FLATSCROLLBAR", "NO")
	local drain = opts.cache and CellGrid.posters(art, opts.cache, function() return opts.art_path() end)

	local title = iup.flatlabel({ TITLE = "", THEMEROLE = "reading", FONTSTYLE = "Bold", TEXTELLIPSIS = "YES",
		RASTERSIZE = (SIDE_WIDTH - ART_WIDTH - 2 * ART_EDGE) .. "x" })
	local status = iup.flatlabel({ TITLE = "", THEMEROLE = "reading_muted" })

	local function tool(icon, tip, run, size)
		local button = Kit.button(iup, { icon = icon, tip = tip, role = "icon_btn", action = run })
		iup.SetAttribute(button, "RASTERSIZE", L.size(size or BUTTON, size or BUTTON))
		Kit.bindIcon(iup, button, icon, { size = ICON })
		return button
	end

	local toggle = Kit.button(iup, { icon = "pause--filled", tip = "Play or pause", role = "primary_btn",
		action = function() player.toggle() end })
	iup.SetAttribute(toggle, "RASTERSIZE", L.size(PLAY, PLAY))

	local bar
	bar = SeekBar.new(iup, { max = 1, role = "flatseek_plain", on_seek = function(value) player.seek(value) end })
	iup.SetAttribute(bar.widget, "EXPAND", "HORIZONTAL")
	iup.SetAttribute(bar.widget, "THICKNESS", "3")

	local elapsed = iup.flatlabel({ TITLE = "", THEMEROLE = "reading_muted", ALIGNMENT = "ARIGHT:ACENTER",
		RASTERSIZE = TIME_WIDTH .. "x" })
	local left_time = iup.flatlabel({ TITLE = "", THEMEROLE = "reading_muted", RASTERSIZE = TIME_WIDTH .. "x" })
	local volume = SeekBar.new(iup, { max = 100, role = "flatseek_plain",
		on_seek = function(value) player.setVolume(value) end,
		on_changing = function(value) player.setVolume(value) end })
	iup.SetAttribute(volume.widget, "RASTERSIZE", VOLUME_WIDTH .. "x")
	iup.SetAttribute(volume.widget, "EXPAND", "NO")
	iup.SetAttribute(volume.widget, "THICKNESS", "3")
	local mute = tool("volume--up", "Mute", function() player.toggleMute() end)

	local left = iup.hbox({ art.widget,
		iup.vbox({ title, status, GAP = "0", MARGIN = "0x0" }),
		GAP = L.gap(2), ALIGNMENT = "ACENTER", MARGIN = "0x0", RASTERSIZE = SIDE_WIDTH .. "x" })
	local middle = iup.vbox({
		iup.hbox({ iup.fill({}),
			tool("rewind--10", "Back 10 seconds", function() player.skip(-10) end), toggle,
			tool("forward--30", "Forward 30 seconds", function() player.skip(30) end),
			iup.fill({}), GAP = L.gap(2), ALIGNMENT = "ACENTER", MARGIN = "0x0" }),
		iup.hbox({ elapsed, bar.widget, left_time, GAP = L.gap(2), ALIGNMENT = "ACENTER", MARGIN = "0x0" }),
		GAP = "0", MARGIN = "0x0", EXPAND = "HORIZONTAL" })
	local right = iup.hbox({ iup.fill({}), mute, volume.widget,
		tool("launch", "Open Now playing", function() opts.open() end),
		tool("close", "Stop and close", function() player.stop() end),
		GAP = L.gap(2), ALIGNMENT = "ACENTER", MARGIN = "0x0", RASTERSIZE = SIDE_WIDTH .. "x" })

	local card = iup.flatframe({
		iup.hbox({ left, middle, right, GAP = L.gap(5), ALIGNMENT = "ACENTER", MARGIN = L.gap(3) .. "x2",
			EXPAND = "HORIZONTAL" }),
		TITLE = "", THEMEROLE = "settingscard", MARGIN = "0x0", EXPAND = "HORIZONTAL",
	})
	-- The window's frame leaves no room on the right, so the card keeps its own.
	api.widget = iup.hbox({ card, iup.fill({ RASTERSIZE = "8x" }), MARGIN = "0x4", EXPAND = "HORIZONTAL" })

	local handle = ctx:addDock(api.widget, opts.owner)

	local function place()
		local state = player.state()
		local want = state ~= nil and not away
		if want ~= shown then
			shown = want
			handle.setVisible(want)
		end
		return state
	end

	function api.refresh()
		local state = place()
		if not state or not shown then return end
		iup.SetAttribute(title, "TITLE", state.title or "")
		iup.SetAttribute(status, "TITLE", playback.status(state))
		iup.SetAttribute(elapsed, "TITLE", playback.clock(state.position))
		iup.SetAttribute(left_time, "TITLE", playback.left(state))
		bar:setMax(math.max(state.length or 0, 1))
		bar:setMarks(state.marks or {})
		bar:setValue(state.position or 0)
		volume:setValue(state.muted and 0 or (state.volume or 100))
		Kit.bindIcon(iup, toggle, state.paused and "play--filled--alt" or "pause--filled", { size = ICON, role = "on_accent" })
		Kit.bindIcon(iup, mute, state.muted and "volume--mute" or "volume--up", { size = ICON })
	end

	--- Step aside, or come back.
	function api.setAway(value)
		away = value == true
		api.refresh()
	end

	function api.tick()
		if drain then drain() end
	end

	return api
end

return M
