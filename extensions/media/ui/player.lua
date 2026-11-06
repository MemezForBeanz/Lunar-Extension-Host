--- The Now Playing tab. One card wears the colours of the film: the poster, sharp, with the title
-- and transport together beside it. When a film plays the poster and big title step aside and the
-- picture takes their place, with the controls under it, not over it, so nothing covers the film
-- and no overlay is needed. Up next and Chapters sit outside the card, as what comes after.
-- @module ui.player

local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local RowList = require("core.ui.RowList")
local CellGrid = require("core.ui.CellGrid")
local SeekBar = require("core.ui.SeekBar")
local AnimatedIcon = require("core.ui.AnimatedIcon")
local VideoHost = require("core.ui.VideoHost")
local ThemeReactor = require("core.ui.ThemeReactor")
local tint = require("libs.tint")
local playback = require("libs.playback")
local spotlight = require("ui.spotlight")

local M = {}

local ART_WIDTH = 320
local ART_EDGE = 12        -- the grid keeps 6 px each side for selection rings
local ART_TALLEST = 640
local ART_LEAST = 200      -- a poster narrower than this gives its room to the words
local ART_GAP = 32
local CARD_INSET = 24
local COLUMN_GAP = 16
local PAGE_EDGE = 16
local RAIL_GAP = 24
local RAIL_PAGE = 1060     -- the narrowest page that holds the card and the rail side by side
local COLUMN_LEAST = 640   -- what the words and transport want beside the poster
local TITLE_FONT = "Segoe UI Semibold, 28"
local VIDEO_LEAST = "64x36"  -- it fills the screen when shown; left alone it asks for a lot of height
local QUEUE_ROW = 68
local QUEUE_ART = "36x54"
local CHAPTER_ROW = 32

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

local SIDE_WIDTH = 196     -- both ends of the transport, so its middle stays centred
local SIDE_NARROW = 150    -- and in a thin pane, where the volume slider gives way
local ROW_INSET = 12       -- where rows start their text; headings share that edge
local BAR_INSET = 7        -- the seek bar keeps this much for its thumb; words line up with its line

--- Build the tab.
-- @tparam table ctx host context
-- @tparam table opts `animate`, `sample` (a film shown paused until a server plays one), `owner`,
--   `cache`, `art`, `upcoming` (what the sample queues next), `art_of(item)`
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
	local raw_bits = art.bits

	local eyebrow = iup.flatlabel({ TITLE = "Paused", THEMEROLE = "reading_muted" })
	local title = L.pageTitle(iup, sample.title)
	local meta = iup.flatlabel({ TITLE = spotlight.meta(sample) .. " · " .. (sample.audio or ""), THEMEROLE = "reading_muted" })
	local overview = iup.flatlabel({ TITLE = sample.overview or "", THEMEROLE = "reading", TEXTWRAP = "YES",
		EXPAND = "HORIZONTAL", ALIGNMENT = "ALEFT:ATOP", RASTERSIZE = "x44" })

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
		iup.SetAttribute(eyebrow, "TITLE", playing and "Playing" or "Paused")
		if api.set_paused then api.set_paused(not playing) end
		if api.resumeClock then api.resumeClock() end
		changed()
	end
	api.toggle = toggle_playing

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

	local tools = {}
	local function tool(icon, tip, run)
		local button = Kit.button(iup, { icon = icon, tip = tip, role = "icon_btn", action = run })
		iup.SetAttribute(button, "RASTERSIZE", "32x32")
		Kit.bindIcon(iup, button, icon, { size = 20 })
		tools[#tools + 1] = button
		return button
	end

	local volume_bar = SeekBar.new(iup, { max = FULL_VOLUME, role = "flatseek_plain",
		on_seek = function(value) api.setVolume(value) end,
		on_changing = function(value) api.setVolume(value) end })
	iup.SetAttribute(volume_bar.widget, "RASTERSIZE", "72x")
	iup.SetAttribute(volume_bar.widget, "EXPAND", "NO")
	iup.SetAttribute(volume_bar.widget, "THICKNESS", "3")
	volume_bar:setValue(FULL_VOLUME)
	local mute_button = Kit.button(iup, { icon = "volume--up", tip = "Mute", role = "icon_btn",
		action = function() api.toggleMute() end })
	iup.SetAttribute(mute_button, "RASTERSIZE", "32x32")
	tools[#tools + 1] = mute_button

	local time = iup.flatlabel({ TITLE = clock(position) .. " / " .. clock(duration), THEMEROLE = "reading" })
	local left_side = iup.hbox({ time, iup.fill({}), ALIGNMENT = "ACENTER", RASTERSIZE = SIDE_WIDTH .. "x" })
	local right_side = iup.hbox({ iup.fill({}),
		mute_button, volume_bar.widget,
		tool("settings--adjust", "Audio and subtitles"), tool("fit-to-screen", "Fullscreen (F)"),
		GAP = L.gap(2), ALIGNMENT = "ACENTER", RASTERSIZE = SIDE_WIDTH .. "x" })
	local transport = iup.vbox({
		bar.widget,
		iup.hbox({
			left_side,
			iup.fill({}),
			tool("skip--back--filled", "Previous"), tool("rewind--10", "Back 10 seconds", function() api.skip(-10) end),
			toggle, tool("forward--30", "Forward 30 seconds", function() api.skip(30) end),
			tool("skip--forward--filled", "Next"),
			iup.fill({}),
			right_side,
			GAP = L.gap(2), ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL", MARGIN = BAR_INSET .. "x0",
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
	local queue = playback.queueRows(opts.upcoming, opts.art_of)
	local queue_art = {}
	local queue_list
	local chapter_list = RowList.new(iup, { rows = chapters, row_height = CHAPTER_ROW, column_widths = { 72 }, role = "flatrows_plain" })
	-- Up next is a card of posters and Chapters a plain timeline, so neither reads as the other.
	-- Its top row stays marked: that is what plays next, whatever else gets clicked.
	queue_list = RowList.new(iup, { rows = queue, row_height = QUEUE_ROW, column_widths = { 48 }, role = "flatrows",
		image_size = QUEUE_ART, on_select = function() queue_list:select(1) end,
		bits = function(pos, w, h)
			if queue_art.bits then return queue_art.bits(pos, w, h) end
		end })
	function queue_art:refreshCell() iup.Update(queue_list.widget) end
	local drain_queue = opts.cache and CellGrid.posters(queue_art, opts.cache, function(pos)
		return queue[pos] and queue[pos].art
	end)
	iup.SetAttribute(chapter_list.widget, "RASTERSIZE", "x" .. (CHAPTER_ROW * #chapters + 8))
	iup.SetAttribute(queue_list.widget, "RASTERSIZE", "x" .. (QUEUE_ROW * math.max(#queue, 1) + 8))
	iup.SetAttribute(chapter_list.widget, "EXPAND", "HORIZONTAL")
	iup.SetAttribute(queue_list.widget, "EXPAND", "HORIZONTAL")
	chapter_list:select(3)
	if queue[1] then queue_list:select(1) end

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
	if video then iup.SetAttribute(video.widget, "RASTERSIZE", VIDEO_LEAST) end
	-- Until a film plays the screen is empty room, and `below` matches it, measured in `fit_art`, so
	-- the words and transport sit together in the middle of the card.
	local screen = iup.zbox({ iup.vbox({ iup.fill({}), MARGIN = "0x0" }), video and video.widget or nil, EXPAND = "YES" })
	local below = iup.fill({})
	local words = iup.vbox({ eyebrow, title, meta, overview, GAP = L.gap(1), MARGIN = BAR_INSET .. "x0", EXPAND = "HORIZONTAL" })
	local poster = iup.vbox({ iup.fill({}), art.widget, iup.fill({}), MARGIN = "0x0", EXPAND = "VERTICAL" })
	local card = iup.flatframe({
		iup.hbox({ poster,
			iup.vbox({ screen, words, transport, below, GAP = COLUMN_GAP, MARGIN = "0x0", EXPAND = "YES" }),
			GAP = ART_GAP, MARGIN = CARD_INSET .. "x" .. CARD_INSET, EXPAND = "YES" }),
		TITLE = "", THEMEROLE = "settingscard", MARGIN = "0x0", EXPAND = "YES",
	})
	local stage = iup.vbox({ requirements.widget, card, GAP = L.gap(4), MARGIN = "0x0", EXPAND = "YES" })
	api.widget = iup.hbox({ stage, rail, GAP = RAIL_GAP, MARGIN = PAGE_EDGE .. "x" .. PAGE_EDGE, EXPAND = "YES" })
	Kit.show(iup, requirements.widget, requirements.blocker ~= nil, bar.widget)
	Kit.show(iup, overview, (sample.overview or "") ~= "", bar.widget)
	Kit.show(iup, poster, opts.art ~= nil, bar.widget)

	local in_film = false      -- a film is on the screen, so poster and big title have stepped aside
	local card_room            -- the card's inside width, from the page's
	local fitted_height, fitted_room

	function api.fit(width)
		local with_rail = width >= RAIL_PAGE
		Kit.show(iup, rail, with_rail, bar.widget)
		card_room = width - 2 * PAGE_EDGE - 2 * CARD_INSET - (with_rail and L.SIDE.narrow + RAIL_GAP or 0)
		local roomy = card_room >= COLUMN_LEAST
		Kit.show(iup, volume_bar.widget, roomy, bar.widget)
		local side = (roomy and SIDE_WIDTH or SIDE_NARROW) .. "x"
		iup.SetAttribute(left_side, "RASTERSIZE", side)
		iup.SetAttribute(right_side, "RASTERSIZE", side)
	end

	-- The poster takes the height the card really has, measured after layout, and leaves the words
	-- their room. Where it can't do both it goes, because the controls matter more.
	local function fit_art()
		if in_film or not opts.art then return end
		local height = tonumber((iup.GetAttribute(card, "RASTERSIZE") or ""):match("x(%d+)$"))
		if not height or height < 200 or (height == fitted_height and card_room == fitted_room) then return end
		fitted_height, fitted_room = height, card_room
		local function tall_of(widget) return tonumber((iup.GetAttribute(widget, "RASTERSIZE") or ""):match("x(%d+)$")) or 0 end
		local spare = height - 2 * CARD_INSET - tall_of(words) - tall_of(transport) - 3 * COLUMN_GAP
		iup.SetAttribute(below, "RASTERSIZE", "x" .. math.max(0, math.floor(spare / 2)))
		local wide = math.floor(math.min(height - 2 * CARD_INSET - ART_EDGE, ART_TALLEST) * 2 / 3)
		if card_room then wide = math.min(wide, card_room - COLUMN_LEAST - ART_GAP - ART_EDGE) end
		local fits = wide >= ART_LEAST
		Kit.show(iup, poster, fits, bar.widget)
		if fits then
			art:setCellWidth(wide)
			iup.SetAttribute(art.widget, "RASTERSIZE", L.size(wide + ART_EDGE, math.floor(wide * 3 / 2) + ART_EDGE))
		end
		iup.Refresh(api.widget)
	end

	-- The card wears the art's colour, or the title's until there is art to read.
	local light = tint.isLight(ThemeReactor.palette().bg)
	local base
	local colour = tint.ofTitle(sample.title, light)
	local painted = { card, eyebrow, title, meta, overview, time, art.widget, bar.widget, volume_bar.widget }

	local function recolour()
		if base then colour = tint.surface(base[1], base[2], base[3], light)
		else colour = tint.ofTitle(now.title, light) end
	end

	-- A theme change paints over all of this, so it is put back on the next tick.
	local function wear()
		local page_light = tint.isLight(ThemeReactor.palette().bg)
		if page_light ~= light then
			light = page_light
			recolour()
		end
		local scheme = tint.scheme(colour, light)
		local wanted = scheme.surface
		if iup.GetAttribute(card, "BGCOLOR") == wanted and iup.GetAttribute(title, "BGCOLOR") == wanted then return end
		for _, widget in ipairs(painted) do iup.SetAttribute(widget, "BGCOLOR", wanted) end
		iup.SetAttribute(card, "FRAMECOLOR", wanted)
		iup.SetAttribute(card, "BORDERSHEENCOLOR", wanted)
		iup.SetAttribute(title, "FONT", TITLE_FONT)
		iup.SetAttribute(title, "FGCOLOR", scheme.text)
		iup.SetAttribute(overview, "FGCOLOR", scheme.text)
		iup.SetAttribute(time, "FGCOLOR", scheme.text)
		iup.SetAttribute(eyebrow, "FGCOLOR", scheme.muted)
		iup.SetAttribute(meta, "FGCOLOR", scheme.muted)
		for _, seek in ipairs({ bar.widget, volume_bar.widget }) do
			iup.SetAttribute(seek, "TRACKCOLOR", scheme.track)
			iup.SetAttribute(seek, "MARKCOLOR", scheme.muted)
			iup.SetAttribute(seek, "BUFFERCOLOR", scheme.muted)
		end
		for _, button in ipairs(tools) do
			iup.SetAttribute(button, "BGCOLOR", wanted)
			iup.SetAttribute(button, "BORDERCOLOR", wanted)
			iup.SetAttribute(button, "HLCOLOR", scheme.lift)
			iup.SetAttribute(button, "PSCOLOR", scheme.lift)
		end
		iup.Update(api.widget)
	end

	art.bits = raw_bits and function(pos, w, h)
		local pixels, stride = raw_bits(pos, w, h)
		if pixels and not base then
			base = tint.average(pixels, stride, w, h) or { 128, 128, 128 }
			recolour()
			wear()
		end
		return pixels, stride
	end or nil

	function api.tick()
		fit_art()
		if drain then drain() end
		if drain_queue then drain_queue() end
		wear()
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
		in_film = true
		for _, part in ipairs({ poster, below, eyebrow, title, overview }) do Kit.show(iup, part, false) end
		queue_list:setEmpty("Nothing queued", "")
		chapter_list:setEmpty("No chapters", "")
		queue = request.queue or {}
		queue_list:setRows(queue)
		queue_list:select(queue[1] and 1 or 0)
		iup.SetAttribute(queue_list.widget, "RASTERSIZE", "x" .. (QUEUE_ROW * math.max(#queue, 1) + 8))
		chapter_list:setRows({})
		on_position, saved_at = request.on_position, 0
		now = { title = request.title or now.title, position = request.start or 0, length = 0, detail = request.detail }
		local line = (request.detail or "") ~= "" and (now.title .. " · " .. request.detail) or now.title
		iup.SetAttribute(meta, "TITLE", line)
		base = nil
		recolour()
		wear()
		iup.Refresh(api.widget)
		loaded = true
		mpv:set("http-header-fields", request.header or "")
		mpv:set("start", tostring(math.floor(request.start or 0)))
		mpv:load(request.url)
		playing = true
		stalled_since = os.time()
		glyph:setPlaying(true)
		iup.SetAttribute(eyebrow, "TITLE", "Playing")
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
