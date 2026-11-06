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

local ART_WIDTH = 320
local ART_EDGE = 12        -- the grid keeps 6 px each side for selection rings
local ART_CAPTION = 84     -- what the title and status need below the poster
local ART_TALLEST = 460    -- a paused film shouldn't tower over its own controls

local SAVE_EVERY = 10     -- seconds between resume points
local FULL_VOLUME = 100
local END_OF_FILE = 0     -- mpv's reason when a file played to its end
local FAILED = 4          -- and when it couldn't be played
local STALL_S = 30        -- no progress for this long while playing counts as failing

local function clock(seconds)
	seconds = math.floor(seconds or 0)
	local h, m, s = math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60
	if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
	return string.format("%d:%02d", m, s)
end

local SIDE_CONTROLS = "440x"   -- both ends of the transport, so its middle stays centred
local ROW_INSET = 12       -- where rows start their text; headings share that edge

local function centred(iup, widget)
	return iup.hbox({ iup.fill({}), widget, iup.fill({}) })
end

--- Build the tab.
-- @tparam table ctx host context
-- @tparam table opts `animate`, `sample` (a film shown paused until a server plays one), `owner`,
--   `cache`, `art`
function M.new(ctx, opts)
	local iup = ctx.iup
	local api = {}
	local sample = opts.sample
	local duration = (sample.minutes or 0) * 60
	local position = math.floor(duration * (sample.progress or 0))

	local requirements = Kit.requirements(iup, { ready = "Player ready" })
	requirements.set({ VideoHost.requirement() })

	local art = CellGrid.new(iup, { count = opts.art and 1 or 0, cell_width = ART_WIDTH, aspect = "2:3", show_text = false,
		gutter = 0, padding = 0, value = function() return nil end, role = "flatgrid_plain" })
	iup.SetAttribute(art.widget, "RASTERSIZE", L.size(ART_WIDTH + ART_EDGE, ART_WIDTH * 3 / 2 + ART_EDGE))
	iup.SetAttribute(art.widget, "EXPAND", "NO")
	iup.SetAttribute(art.widget, "CANFOCUS", "NO")
	iup.SetAttribute(art.widget, "FLATSCROLLBAR", "NO")
	local drain = opts.cache and opts.art and CellGrid.posters(art, opts.cache, function() return opts.art end)

	local glyph = AnimatedIcon.new(iup, { animate = opts.animate, size = 20, role = "on_accent" })
	local playing = false
	local volume, muted = FULL_VOLUME, false
	local MARKS = { { at = 1320 }, { at = 2700 }, { at = 4140 }, { at = 7200 } }
	local now = { title = sample.title, position = position, length = duration, marks = MARKS,
		detail = tostring(sample.year) }
	local loaded = opts.demo == true   -- the dock only appears once something has played
	local function changed()
		if api.on_change then api.on_change() end
	end
	local function toggle_playing()
		playing = not playing
		glyph:setPlaying(playing)
		if api.set_paused then api.set_paused(not playing) end
		if api.resumeClock then api.resumeClock() end
		changed()
	end
	api.toggle = toggle_playing
	local picture = iup.vbox({
		centred(iup, art.widget),
		centred(iup, L.pageTitle(iup, sample.title)),
		centred(iup, L.hint(iup, string.format("Paused · %d · %d h %d min", sample.year,
			math.floor(sample.minutes / 60), sample.minutes % 60))),
		GAP = L.gap(2), MARGIN = "0x0", EXPAND = "YES",
	})

	local bar
	bar = SeekBar.new(iup, { max = duration, role = "flatseek_plain", on_seek = function(value)
		if bar.seek_to then bar.seek_to(value) end
	end })
	iup.SetAttribute(bar.widget, "EXPAND", "HORIZONTAL")
	iup.SetAttribute(bar.widget, "THICKNESS", "4")
	bar:setValue(position)
	bar:setMarks(MARKS)

	local toggle = iup.flatbutton({ TITLE = "", THEMEROLE = "primary_btn", TIP = "Play or pause (Space)", RASTERSIZE = "40x40" })
	glyph.paint = function(path)
		Kit.bindIcon(iup, toggle, (path:gsub("%.svg$", "")), { size = 20, role = "on_accent" })
	end
	glyph:_draw()
	function toggle:flat_action()
		toggle_playing()
		return iup.DEFAULT
	end

	local function tool(icon, tip, run)
		local button = Kit.button(iup, { icon = icon, tip = tip, role = "icon_btn", action = run })
		iup.SetAttribute(button, "RASTERSIZE", "32x32")
		Kit.bindIcon(iup, button, icon, { size = 20 })
		return button
	end

	local volume_bar = SeekBar.new(iup, { max = FULL_VOLUME, role = "flatseek_plain",
		on_seek = function(value) api.setVolume(value) end,
		on_changing = function(value) api.setVolume(value) end })
	iup.SetAttribute(volume_bar.widget, "RASTERSIZE", "88x")
	iup.SetAttribute(volume_bar.widget, "EXPAND", "NO")
	iup.SetAttribute(volume_bar.widget, "THICKNESS", "3")
	volume_bar:setValue(FULL_VOLUME)
	local mute_button = Kit.button(iup, { icon = "volume--up", tip = "Mute", role = "icon_btn",
		action = function() api.toggleMute() end })
	iup.SetAttribute(mute_button, "RASTERSIZE", "32x32")

	local time = iup.flatlabel({ TITLE = clock(position) .. " / " .. clock(duration), THEMEROLE = "reading" })
	local detail = iup.flatlabel({ THEMEROLE = "reading_muted", TITLE = string.format("%s · %s · %s", sample.resolution or "", sample.dynamic or "", sample.audio or "") })
	local transport = iup.vbox({
		bar.widget,
		iup.hbox({
			iup.hbox({ time, iup.fill({}), ALIGNMENT = "ACENTER", RASTERSIZE = SIDE_CONTROLS }),
			iup.fill({}),
			tool("skip--back--filled", "Previous"), tool("rewind--10", "Back 10 seconds", function() api.skip(-10) end),
			toggle, tool("forward--30", "Forward 30 seconds", function() api.skip(30) end),
			tool("skip--forward--filled", "Next"),
			iup.fill({}),
			iup.hbox({ iup.fill({}), detail,
				mute_button, volume_bar.widget,
				tool("settings--adjust", "Audio and subtitles"), tool("fit-to-screen", "Fullscreen (F)"),
				GAP = L.gap(2), ALIGNMENT = "ACENTER", RASTERSIZE = SIDE_CONTROLS }),
			GAP = L.gap(3), ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL", MARGIN = "6x0",
		}),
		GAP = L.gap(3), MARGIN = "0x0", EXPAND = "HORIZONTAL",
	})

	local function aligned(widget)
		return iup.hbox({ widget, MARGIN = ROW_INSET .. "x0" })
	end

	local chapters = {
		{ title = "Opening", column1 = "0:00:00" }, { title = "The survey", column1 = "0:22:00" },
		{ title = "Low water", column1 = "0:45:00" }, { title = "The boundary stone", column1 = "1:09:00" },
		{ title = "Credits", column1 = "2:00:00" },
	}
	local queue = {
		{ title = "Glass Harbour", column1 = "1 h 44 min" },
		{ title = "Paper Orchard", column1 = "1 h 52 min" },
		{ title = "Six Bells", column1 = "1 h 35 min" },
	}
	local chapter_list = RowList.new(iup, { rows = chapters, row_height = 36, column_widths = { 72 }, role = "flatrows_plain" })
	local queue_list = RowList.new(iup, { rows = queue, row_height = 36, column_widths = { 96 }, role = "flatrows_plain" })
	iup.SetAttribute(chapter_list.widget, "RASTERSIZE", "x" .. (36 * #chapters + 8))
	iup.SetAttribute(queue_list.widget, "RASTERSIZE", "x" .. (36 * #queue + 8))
	iup.SetAttribute(chapter_list.widget, "EXPAND", "HORIZONTAL")
	iup.SetAttribute(queue_list.widget, "EXPAND", "HORIZONTAL")
	chapter_list:select(3)

	local rail = iup.vbox({
		iup.hbox({ RASTERSIZE = L.size(L.SIDE.narrow) }),
		L.stack(iup, {
			L.stack(iup, { aligned(L.sectionTitle(iup, "Up next")), queue_list.widget }, 3),
			L.stack(iup, { aligned(L.sectionTitle(iup, "Chapters")), chapter_list.widget }, 3),
		}, 6),
		iup.fill({}),
		MARGIN = "0x0", EXPAND = "VERTICAL",
	})

	local video = VideoHost.new(iup, { bgcolor = "0 0 0" })
	local screen = iup.zbox({ picture, video and video.widget or nil, EXPAND = "YES" })
	local stage = iup.vbox({ requirements.widget, screen, transport, GAP = L.gap(4), MARGIN = "0x0", EXPAND = "YES" })
	api.widget = iup.hbox({ stage, rail, GAP = L.gap(6), MARGIN = L.margin(5), EXPAND = "YES" })
	Kit.show(iup, requirements.widget, requirements.blocker ~= nil, bar.widget)

	function api.fit(width)
		Kit.show(iup, rail, width >= 900, bar.widget)
	end

	-- The poster takes the height the stage really has, measured after layout.
	local art_height
	local function fit_art()
		local height = tonumber((iup.GetAttribute(screen, "RASTERSIZE") or ""):match("x(%d+)$"))
		if not height or height == art_height or height < 200 then return end
		art_height = height
		local tall = math.min(height - ART_CAPTION, ART_TALLEST)
		local wide = math.floor(tall * 2 / 3)
		art:setCellWidth(wide)
		iup.SetAttribute(art.widget, "RASTERSIZE", L.size(wide + ART_EDGE, tall + ART_EDGE))
		iup.Refresh(picture)
	end

	function api.tick()
		fit_art()
		if drain then drain() end
	end

	local mpv, on_position, seconds, length, saved_at = nil, nil, 0, 0, 0
	local stalled_since

	local function on_event(name, info)
		if name == "end-file" then
			if info and info.reason == END_OF_FILE and api.on_finished then api.on_finished() end
			if info and info.reason == FAILED and api.on_failed then api.on_failed() end
			return
		end
		if name ~= "property-change" or not info or info.value == nil then return end
		if info.name == "time-pos" then
			seconds = info.value
			now.position = seconds
			stalled_since = os.time()
			changed()
			bar:setValue(seconds)
			iup.SetAttribute(time, "TITLE", clock(seconds) .. " / " .. clock(length))
			if on_position and math.abs(seconds - saved_at) >= SAVE_EVERY then
				saved_at = seconds
				on_position(seconds, length)
			end
		elseif info.name == "duration" then
			length = info.value
			now.length = length
			bar:setMax(length)
			changed()
		end
	end

	function bar.seek_to(value)
		if mpv then mpv:seek(value) end
	end

	--- What the dock shows, or nil when nothing is loaded.
	function api.state()
		if not loaded then return nil end
		return { title = now.title, position = now.position, length = now.length, paused = not playing,
			volume = volume, muted = muted, detail = now.detail, marks = now.marks }
	end

	function api.seek(value)
		now.position = value
		bar:setValue(value)
		if mpv then mpv:seek(value) end
		changed()
	end

	--- Jump relative to where playback is, inside the film.
	function api.skip(delta)
		api.seek(math.max(0, math.min(now.length or 0, (now.position or 0) + delta)))
	end

	function api.setVolume(value)
		volume, muted = value, false
		volume_bar:setValue(value)
		if mpv then
			mpv:set("mute", "no")
			mpv:set("volume", tostring(math.floor(value)))
		end
		changed()
	end

	function api.toggleMute()
		muted = not muted
		volume_bar:setValue(muted and 0 or volume)
		Kit.bindIcon(iup, mute_button, muted and "volume--mute" or "volume--up", { size = 20 })
		if mpv then mpv:set("mute", muted and "yes" or "no") end
		changed()
	end

	function api.pause()
		if playing then toggle_playing() end
	end

	function api.resumeClock()
		stalled_since = os.time()
	end

	--- Stop playback and let the dock go.
	function api.stop()
		if mpv then mpv:stop() end
		if playing then toggle_playing() end
		loaded = false
		changed()
	end

	--- The sample's paused film is a preview, so it goes when a real library arrives.
	function api.endDemo()
		if not mpv then loaded = false end
		changed()
	end

	function api.set_paused(paused)
		if mpv then mpv:set("pause", paused and "yes" or "no") end
	end

	--- Play a stream.
	-- @tparam table request `url`, `header`, `title`, `detail`, `start` (seconds), `on_position(seconds, length)`
	-- @treturn boolean|nil true, or nil and why not
	function api.play(request)
		if not video then return nil, "this build of Lunar has no video surface" end
		if not mpv then
			local err
			mpv, err = VideoHost.player(video, { on_event = on_event })
			if not mpv then return nil, err end
			mpv:observe("time-pos", "double")
			mpv:observe("duration", "double")
		end
		iup.SetAttribute(screen, "VALUEPOS", "1")
		queue_list:setEmpty("Nothing queued", "")
		chapter_list:setEmpty("No chapters", "")
		queue_list:setRows(request.queue or {})
		iup.SetAttribute(queue_list.widget, "RASTERSIZE", "x" .. (36 * math.max(#(request.queue or {}), 1) + 8))
		chapter_list:setRows({})
		iup.SetAttribute(detail, "TITLE", request.detail or "")
		on_position, saved_at = request.on_position, 0
		now = { title = request.title or now.title, position = request.start or 0, length = 0, detail = request.detail }
		loaded = true
		mpv:set("http-header-fields", request.header or "")
		mpv:set("start", tostring(math.floor(request.start or 0)))
		mpv:load(request.url)
		playing = true
		stalled_since = os.time()
		glyph:setPlaying(true)
		changed()
		return true
	end

	function api.pump()
		if not mpv then return end
		mpv:poll()
		-- A stream that starts and then stops arriving ends in silence, not in an error, so the
		-- next copy has to be fetched on a clock.
		if playing and stalled_since and os.time() - stalled_since >= STALL_S then
			stalled_since = nil
			mpv:stop()
			if api.on_failed then api.on_failed() end
		end
	end

	function api.close()
		glyph:stop()
		if mpv then
			mpv:destroy()
			mpv = nil
		end
	end

	return api
end

return M
