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
local PLAY = 40

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
		return button
	end

	local toggle = Kit.button(iup, { icon = "pause--filled", tip = "Play or pause", role = "primary_btn",
		action = function() player.toggle() end })
	iup.SetAttribute(toggle, "RASTERSIZE", L.size(PLAY, PLAY))

	local bar
	bar = SeekBar.new(iup, { max = 1, role = "flatseek_plain", on_seek = function(value) player.seek(value) end })
	iup.SetAttribute(bar.widget, "EXPAND", "HORIZONTAL")
	iup.SetAttribute(bar.widget, "THICKNESS", "3")

	local time = iup.flatlabel({ TITLE = "", THEMEROLE = "reading_muted" })
	local volume = SeekBar.new(iup, { max = 100, role = "flatseek_plain",
		on_seek = function(value) player.setVolume(value) end,
		on_changing = function(value) player.setVolume(value) end })
	iup.SetAttribute(volume.widget, "RASTERSIZE", VOLUME_WIDTH .. "x")
	iup.SetAttribute(volume.widget, "EXPAND", "NO")
	iup.SetAttribute(volume.widget, "THICKNESS", "3")
	local mute = tool("volume--up", "Mute", function() player.toggleMute() end)

	local left = iup.hbox({ art.widget,
		iup.vbox({ title, status, GAP = L.gap(1), MARGIN = "0x0" }),
		GAP = L.gap(2), ALIGNMENT = "ACENTER", MARGIN = "0x0", RASTERSIZE = SIDE_WIDTH .. "x" })
	local middle = iup.hbox({
		tool("rewind--10", "Back 10 seconds", function() player.skip(-10) end), toggle,
		tool("forward--30", "Forward 30 seconds", function() player.skip(30) end),
		GAP = L.gap(2), ALIGNMENT = "ACENTER", MARGIN = "0x0" })
	local right = iup.hbox({ iup.fill({}), time, mute, volume.widget,
		tool("launch", "Open Now playing", function() opts.open() end),
		GAP = L.gap(2), ALIGNMENT = "ACENTER", MARGIN = "0x0", RASTERSIZE = SIDE_WIDTH .. "x" })

	local card = iup.flatframe({
		iup.vbox({
			bar.widget,
			iup.hbox({ left, iup.fill({}), middle, iup.fill({}), right,
				ALIGNMENT = "ACENTER", MARGIN = L.gap(3) .. "x0", EXPAND = "HORIZONTAL" }),
			GAP = "0", MARGIN = "0x2", EXPAND = "HORIZONTAL",
		}),
		TITLE = "", THEMEROLE = "settingscard", MARGIN = "0x0", EXPAND = "HORIZONTAL",
	})
	api.widget = iup.hbox({ card, MARGIN = "12x4", EXPAND = "HORIZONTAL" })

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
		iup.SetAttribute(time, "TITLE", playback.clock(state.position) .. " / " .. playback.clock(state.length))
		bar:setMax(math.max(state.length or 0, 1))
		bar:setValue(state.position or 0)
		volume:setValue(state.muted and 0 or (state.volume or 100))
		Kit.bindIcon(iup, toggle, state.paused and "play--filled--alt" or "pause--filled", { size = 20, role = "on_accent" })
		Kit.bindIcon(iup, mute, state.muted and "volume--mute" or "volume--up", { size = 20 })
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
