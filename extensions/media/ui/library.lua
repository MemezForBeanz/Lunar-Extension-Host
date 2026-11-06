--- The Media tab: sources, a collection and an inspector.
-- A click selects and fills the inspector, so nobody has to leave the collection to read
-- about a film. Enter or a double click plays. The ledger is a peer of the contact sheet.
-- @module ui.library

local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local CellGrid = require("core.ui.CellGrid")
local RowList = require("core.ui.RowList")
local SeekBar = require("core.ui.SeekBar")
local FlatDropdown = require("core.ui.FlatDropdown")
local Adaptive = require("core.ui.Adaptive")
local spotlight = require("ui.spotlight")
local title_page = require("ui.title")
local FlatField = require("core.ui.FlatField")
local playback = require("libs.playback")
local tonight = require("libs.tonight")
local organize = require("libs.organize")
local NameDialog = require("core.ui.NameDialog")

local M = {}

local CELL = 148           -- the size a cell aims for; columns then share the width exactly
local WIDE_CELL = 280      -- Continue watching: landscape cards, which also say how long is left
local JUMP_SLOTS = 27      -- A to Z and #
local PLAN_ROW = 48
local JUMP_ROW = 22
local JUMP_WIDTH = 24
local FILTER_WIDTH = 108
local RAIL_SOURCES = 3
local DENSITY_LEAST = 104  -- the smallest poster the size slider gives
local DENSITY_RANGE = 120
local SPOTLIGHT_COUNT = 5
local RING = 6             -- the grid's room for selection rings; text outside grids lines up with it
local GUTTER = 16
local SCROLLBAR = 8
local CELL_TEXT = 62
local UNKNOWN = "Not analysed"
local INSPECTOR_ART = 132
local HEAD_TEXT = 162      -- what is left beside the poster in the inspector
local LABEL_WIDTH = 138    -- values and controls start under the actions, not at their own edge
local VALUE_WIDTH = 168    -- fixed, so a long file name can't push the whole inspector
local ACTION_HEIGHT = 36
local TITLE_LINE = 22      -- characters of page title that fit on one line across the rail
local SOURCE_WIDTH = 184
local INSPECTOR_WIDTH = L.SIDE.narrow

local function runtime(minutes)
	if not minutes or minutes < 1 then return nil end
	if minutes < 60 then return minutes .. " min" end
	return string.format("%d h %d min", math.floor(minutes / 60), minutes % 60)
end

-- A film's size in the unit a person would say.
local function size_text(gigabytes)
	if not gigabytes then return nil end
	if gigabytes < 1 then return string.format("%d MB", math.max(1, math.floor(gigabytes * 1024))) end
	return string.format("%.1f GB", gigabytes)
end

local function plural(count, word)
	return count .. " " .. word .. (count == 1 and "" or "s")
end

local function subtitle_of(item)
	if item.kind == "show" then
		return string.format("%d · %s", item.year, plural(item.seasons, "season"))
	end
	return tostring(item.year)
end

local function time_left(item)
	local minutes = item.minutes or 0
	return playback.remaining(minutes * 60 * (1 - (item.progress or 0)))
end

local function cell_value(list, secondary)
	return function(pos, field)
		local item = list[pos]
		if not item then return nil end
		if field == "TITLE" then return item.title end
		if field == "SECONDARY" then return (secondary or subtitle_of)(item) end
		if field == "BADGE" then return organize.badge(item) end
		if field == "PROGRESS" then
			local p = item.progress or 0
			if p > 0 and p < 1 then return tostring(math.floor(p * 100)) end
		end
		return nil
	end
end

local SORTS = {
	{ "Title", organize.byTitle },
	{ "Recently added", function(a, b) return a.added > b.added end },
	{ "Year", function(a, b) return (a.year or 0) > (b.year or 0) end },
}

local LEDGER_KEYS = { [0] = "title", "year", "resolution", "codec", "dynamic", "audio", "size_gb" }

--- Cells that fill `width` exactly: no part-cell at the edge, and no spare pixels in the gutters.
local function fitted_cell(width, ideal)
	local columns = math.max(1, math.floor((width + GUTTER) / (ideal + GUTTER)))
	return math.floor((width - (columns - 1) * GUTTER) / columns)
end

local function muted(iup, text)
	return iup.flatlabel({ TITLE = text or "", THEMEROLE = "reading_muted" })
end

local function fact(iup)
	local name = muted(iup, "")
	iup.SetAttribute(name, "RASTERSIZE", LABEL_WIDTH .. "x")
	local value = iup.flatlabel({ TITLE = "", THEMEROLE = "reading_muted", RASTERSIZE = VALUE_WIDTH .. "x",
		TEXTELLIPSIS = "YES" })
	return { row = iup.hbox({ name, value, GAP = L.gap(3), ALIGNMENT = "ACENTER" }), name = name, value = value }
end

local function labelled(iup, label, control)
	local name = muted(iup, label)
	iup.SetAttribute(name, "RASTERSIZE", LABEL_WIDTH .. "x")
	return iup.hbox({ name, control, GAP = L.gap(3), ALIGNMENT = "ACENTER" })
end

local function inspector(ctx, cache, art_of, on_play, on_open)
	local iup = ctx.iup
	local current
	local poster = CellGrid.new(iup, {
		count = 0, cell_width = INSPECTOR_ART, aspect = "2:3", show_text = false, gutter = 0, padding = 0,
		value = function() return nil end, role = "flatgrid_plain",
	})
	iup.SetAttribute(poster.widget, "RASTERSIZE", L.size(INSPECTOR_ART + 2 * RING, INSPECTOR_ART * 3 / 2 + 2 * RING))
	iup.SetAttribute(poster.widget, "EXPAND", "NO")
	iup.SetAttribute(poster.widget, "CANFOCUS", "NO")
	iup.SetAttribute(poster.widget, "FLATSCROLLBAR", "NO")
	local posters = cache and CellGrid.posters(poster, cache, function() return current and art_of(current) end)

	local title = L.pageTitle(iup, "")
	iup.SetAttribute(title, "TEXTWRAP", "YES")
	iup.SetAttribute(title, "ALIGNMENT", "ALEFT:ATOP")
	iup.SetAttribute(title, "RASTERSIZE", L.size(INSPECTOR_WIDTH - 2 * RING, 36))
	local meta = muted(iup, "")
	local overview = iup.flatlabel({ TITLE = "", THEMEROLE = "reading", TEXTWRAP = "YES",
		RASTERSIZE = L.size(INSPECTOR_WIDTH - 2 * RING, 48), ALIGNMENT = "ALEFT:ATOP" })
	local play = Kit.button(iup, { title = "Play", icon = "play--filled--alt", role = "primary_btn",
		action = function()
			if not current then return end
			if current.kind == "show" or on_details_only then on_open(current) else on_play(current) end
		end })
	iup.SetAttribute(play, "RASTERSIZE", L.size(HEAD_TEXT, ACTION_HEIGHT))
	local queue = Kit.button(iup, { title = "Details", action = function()
		if current then on_open(current) end
	end })
	iup.SetAttribute(queue, "RASTERSIZE", L.size(HEAD_TEXT, ACTION_HEIGHT))

	local audio = FlatDropdown.new(iup, { items = { "Default" }, value = 1, expand = true, role = "dropbutton_quiet" })
	local subtitles = FlatDropdown.new(iup, { items = { "Off" }, value = 1, expand = true, role = "dropbutton_quiet" })
	local tracks = L.stack(iup, { labelled(iup, "Audio", audio.widget), labelled(iup, "Subtitles", subtitles.widget) }, 2)

	local facts = {}
	local fact_box = iup.vbox({ GAP = L.gap(2), MARGIN = "0x0", EXPAND = "HORIZONTAL" })
	for i = 1, 8 do
		facts[i] = fact(iup)
		iup.Append(fact_box, facts[i].row)
	end
	local details_open = false
	local details = iup.flatbutton({ TITLE = "Show file details", THEMEROLE = "link_btn", CANFOCUS = "YES" })
	function details:flat_action()
		details_open = not details_open
		iup.SetAttribute(details, "TITLE", details_open and "Hide file details" or "Show file details")
		Kit.show(iup, fact_box, details_open, details)
		iup.Refresh(fact_box)
		return iup.DEFAULT
	end
	Kit.show(iup, fact_box, false)

	local head = iup.hbox({
		poster.widget,
		iup.vbox({ meta, play, queue, GAP = L.gap(2), MARGIN = "0x" .. RING, EXPAND = "VERTICAL" }),
		GAP = L.gap(3), MARGIN = "0x0", EXPAND = "HORIZONTAL",
	})
	local body = L.stack(iup, {
		iup.hbox({ title, MARGIN = RING .. "x0" }),
		head,
		iup.vbox({
			L.stack(iup, { overview, tracks }, 4),
			L.stack(iup, { iup.hbox({ details, MARGIN = "0x0" }), fact_box }, 3),
			GAP = L.gap(6), MARGIN = RING .. "x0", EXPAND = "HORIZONTAL",
		}),
	}, 2)
	iup.SetAttribute(body, "EXPAND", "YES")

	local function fill(rows)
		for i, entry in ipairs(facts) do
			local data = rows[i]
			Kit.show(iup, entry.row, data ~= nil, details_open and details or nil)
			if data then
				iup.SetAttribute(entry.name, "TITLE", data[1])
				iup.SetAttribute(entry.value, "TITLE", data[2])
			end
		end
	end

	local function show(item)
		current = item
		if not item then return end
		iup.SetAttribute(title, "TITLE", item.title)
		iup.SetAttribute(title, "RASTERSIZE", L.size(INSPECTOR_WIDTH - 2 * RING, #item.title > TITLE_LINE and 72 or 36))
		iup.SetAttribute(overview, "TITLE", item.overview or "")
		Kit.show(iup, overview, (item.overview or "") ~= "", details)
		local words = item.kind == "show" and "Episodes" or ((item.progress or 0) > 0 and item.progress < 1 and "Resume" or "Play")
		iup.SetAttribute(play, "TITLE", words)
		local is_show = item.kind == "show"
		if is_show then
			iup.SetAttribute(meta, "TITLE", string.format("%d · %s", item.year, plural(item.seasons or 0, "season")))
			fill({ { "Seasons", tostring(item.seasons or 0) }, { "Episodes", tostring(item.episodes or 0) },
				{ "Resolution", item.resolution or "Mixed" }, { "Added", item.added or "" } })
		else
			local length = runtime(item.minutes)
			iup.SetAttribute(meta, "TITLE", length and (item.year .. " · " .. length) or tostring(item.year))
			fill({ { "Resolution", item.resolution or UNKNOWN }, { "Video", item.codec or UNKNOWN },
				{ "Range", item.dynamic or UNKNOWN },
				{ "Bitrate", item.bitrate and string.format("%.1f Mb/s", item.bitrate) or UNKNOWN },
				{ "Size", size_text(item.size_gb) or UNKNOWN },
				{ "Added", item.added or UNKNOWN },
				item.path and { "File", item.path:match("[^/\\]+$") } or nil })
		end
		Kit.show(iup, tracks, not is_show, details)
		audio:setItems({ item.audio or "Default" }, 1)
		local subs = { "Off" }
		for name in (item.subtitles or ""):gmatch("[^,%s]+") do subs[#subs + 1] = name end
		subtitles:setItems(subs, 1)
		poster:setProvider(art_of(item) and 1 or 0, function() return nil end)
		poster:refreshCell(1)
		iup.Refresh(body)
	end
	return body, show, posters
end

--- Build the tab.
-- @tparam table ctx host context
-- @tparam table opts `model`, `cache` (a PosterCache or nil), `art_of(item)`, `on_play(item)`
-- @treturn table `widget`, `go(state)`, `fit(width)`, `tick()`
function M.new(ctx, opts)
	local iup = ctx.iup
	local model, cache, art_of = opts.model, opts.cache, opts.art_of
	local api = {}
	local drains = {}
	local films, shows = {}, {}
	for i, film in ipairs(model.films) do films[i] = film end
	for i, show in ipairs(model.shows) do shows[i] = show end
	local base = films        -- what the rail chose
	local active = films      -- what the filters left of it
	local filters = {}
	local collection          -- the collection on show, if any
	local source_id = "home"
	local ideal_cell = CELL
	local view = "sheet"
	local sort = 1
	local chosen
	local continuing, recent = {}, {}
	for _, film in ipairs(model.films) do
		if (film.progress or 0) > 0 and film.progress < 1 then continuing[#continuing + 1] = film end
	end
	for i, film in ipairs(model.films) do recent[i] = film end
	table.sort(recent, SORTS[2][2])

	local inspector_body, show_item, inspector_posters = inspector(ctx, cache, art_of, opts.on_play,
		function(item) api.open(item) end)
	drains[#drains + 1] = inspector_posters

	local shelves, sheet, ledger, hero
	local sources_anchor

	local function position_in(list, item)
		for i, candidate in ipairs(list) do
			if candidate == item then return i end
		end
		return 0
	end

	-- Whatever fills the inspector is marked wherever it appears, so the two zones read as one.
	local function mark_chosen()
		-- Home has no inspector, so a resting mark there would point at nothing.
		for _, shelf in ipairs(shelves) do shelf.grid:select(source_id == "home" and 0 or position_in(shelf.list, chosen)) end
		sheet:select(position_in(active, chosen))
		ledger:select(position_in(active, chosen))
	end

	local function choose(item)
		if not item then return end
		chosen = item
		show_item(item)
		mark_chosen()
		if source_id == "home" and hero then hero.show(item, true) end
		if opts.enrich then
			opts.enrich(item, function()
				if chosen == item then show_item(item) end
			end)
		end
	end

	-- `list_of` is a function because the sheet shows whichever list is active.
	local function grid_for(list_of, extra)
		local art = extra.art or art_of
		local grid = CellGrid.new(iup, {
			count = #list_of(), value = cell_value(list_of(), extra.secondary), cell_width = extra.cell or CELL,
			aspect = extra.aspect or "2:3", gutter = GUTTER, padding = 0,
			shelf = extra.shelf, empty_title = extra.empty, empty_hint = extra.hint, role = "flatgrid_plain",
			on_select = function(pos) choose(list_of()[pos]) end,
			on_activate = function(pos)
				local item = list_of()[pos]
				if not item then return end
				if item.kind == "show" then api.open(item) else opts.on_play(item) end
			end,
		})
		if cache then
			drains[#drains + 1] = CellGrid.posters(grid, cache, function(pos)
				local item = list_of()[pos]
				return item and art(item)
			end)
		end
		return grid
	end

	local function wide_art(item)
		return opts.backdrop_of and opts.backdrop_of(item) or art_of(item)
	end

	local continue_shelf = grid_for(function() return continuing end, { shelf = true, cell = WIDE_CELL,
		aspect = "16:9", art = wide_art, secondary = time_left,
		empty = "Nothing in progress", hint = "Films you start appear here." })
	local plan = {}
	local plan_list = RowList.new(iup, { rows = {}, row_height = PLAN_ROW, column_widths = { 200 }, role = "flatrows_plain",
		column_align = { [1] = "RIGHT" },
		empty_title = "Nothing fits that yet", empty_hint = "Try a longer evening.",
		on_select = function(pos) if plan[pos] then choose(plan[pos].item) end end,
		on_activate = function(pos)
			local pick = plan[pos]
			if not pick then return end
			local rest = {}
			for i = pos + 1, #plan do rest[#rest + 1] = plan[i].item end
			opts.on_play(pick.item, rest)
		end })
	iup.SetAttribute(plan_list.widget, "EXPAND", "HORIZONTAL")
	local recent_shelf = grid_for(function() return recent end, { shelf = true,
		empty = "Nothing here yet", hint = "New films appear here after a scan." })
	shelves = { { grid = continue_shelf, list = continuing }, { grid = recent_shelf, list = recent } }
	local function size_shelves(cell, wide)
		iup.SetAttribute(recent_shelf.widget, "RASTERSIZE", "x" .. (math.floor(cell * 3 / 2) + CELL_TEXT + SCROLLBAR))
		iup.SetAttribute(continue_shelf.widget, "RASTERSIZE", "x" .. (math.floor(wide * 9 / 16) + CELL_TEXT + SCROLLBAR))
	end
	size_shelves(CELL, WIDE_CELL)
	for _, shelf in ipairs(shelves) do iup.SetAttribute(shelf.grid.widget, "EXPAND", "HORIZONTAL") end

	local function aligned(widget)
		return iup.hbox({ widget, MARGIN = RING .. "x0" })
	end
	hero = spotlight.new(ctx, { cache = cache, art = wide_art, on_play = opts.on_play,
		on_info = function(item) api.open(item) end })
	drains[#drains + 1] = hero.tick
	-- Fits Tonight: a time, and a plan with clock times that ends by then.
	local plan_seed, plan_limit = 1, tonight.TIMES[5][1]
	local plan_starts = tonight.starts(os.time())
	local plan_start_at = plan_starts[1][2]
	local plan_summary = L.sectionTitle(iup, "")
	local function refill_plan()
		plan = tonight.plan(films, plan_limit, plan_start_at, plan_seed)
		local rows = {}
		for i, pick in ipairs(plan) do
			local following = plan[i + 1] and (" · then a " .. tonight.BREAK_MINUTES .. " minute break") or ""
			rows[i] = { title = pick.item.title, secondary = pick.why .. following,
				column1 = tonight.clock(pick.starts) .. " to " .. tonight.clock(pick.ends) }
		end
		plan_list:setRows(rows)
		iup.SetAttribute(plan_list.widget, "RASTERSIZE", "x" .. (PLAN_ROW * math.max(#rows, 1) + 8))
		iup.SetAttribute(plan_summary, "TITLE", tonight.summary(plan))
	end
	local time_labels = {}
	for i, entry in ipairs(tonight.TIMES) do time_labels[i] = entry[2] end
	local plan_time = FlatDropdown.new(iup, { items = time_labels, value = 5, width = 120, role = "dropbutton_quiet",
		on_change = function(index)
			plan_limit = tonight.TIMES[index][1]
			refill_plan()
		end })
	local start_labels = {}
	for i, entry in ipairs(plan_starts) do start_labels[i] = entry[1] end
	local plan_from = FlatDropdown.new(iup, { items = start_labels, value = 1, width = 136, role = "dropbutton_quiet",
		on_change = function(index)
			plan_start_at = plan_starts[index][2]
			refill_plan()
		end })
	local plan_again = Kit.button(iup, { title = "Another idea", role = "actionbutton", action = function()
		plan_seed = plan_seed + 1
		refill_plan()
	end })
	iup.SetAttribute(plan_again, "RASTERSIZE", "x32")
	local plan_play = Kit.button(iup, { title = "Play all", icon = "play--filled--alt", role = "actionbutton", action = function()
		if not plan[1] then return end
		local rest = {}
		for i = 2, #plan do rest[#rest + 1] = plan[i].item end
		opts.on_play(plan[1].item, rest)
	end })
	iup.SetAttribute(plan_play, "RASTERSIZE", "x32")
	local plan_section = L.stack(iup, {
		iup.hbox({ L.sectionTitle(iup, "Fits tonight"), plan_summary, iup.fill({}), plan_from.widget, plan_time.widget,
			plan_again, plan_play, GAP = L.gap(3), ALIGNMENT = "ACENTER", MARGIN = RING .. "x0", EXPAND = "HORIZONTAL" }),
		plan_list.widget,
	}, 2)

	local continue_section = L.stack(iup, { aligned(L.sectionTitle(iup, "Continue watching")), continue_shelf.widget }, 2)
	local home_body = L.stack(iup, {
		iup.hbox({ hero.widget, MARGIN = RING .. "x0", EXPAND = "HORIZONTAL" }),
		continue_section,
		plan_section,
		L.stack(iup, { aligned(L.sectionTitle(iup, "Recently added")), recent_shelf.widget }, 2),
		iup.fill({ RASTERSIZE = "x" .. GUTTER }),
	}, 5)
	iup.SetAttribute(home_body, "EXPAND", "HORIZONTAL")
	-- The frame paints the page colour: labels in a scroll box have no parent colour to take.
	local home = iup.flatscrollbox({
		iup.flatframe({ home_body, TITLE = "", THEMEROLE = "settingspanel", MARGIN = "0x0", EXPAND = "HORIZONTAL" }),
		EXPAND = "YES", SCROLLBAR = "VERTICAL", XHIDDEN = "YES", THEMEROLE = "tabscroll" })

	sheet = grid_for(function() return active end, {})
	iup.SetAttribute(sheet.widget, "EXPAND", "YES")

	local ledger_rows = {}
	local function fill_ledger(list)
		ledger_rows = {}
		for i, item in ipairs(list) do
			ledger_rows[i] = {
				title = item.title, column1 = tostring(item.year), column2 = item.resolution or "",
				column3 = item.codec or "", column4 = item.dynamic or "", column5 = item.audio or "",
				column6 = item.web and "Stream" or size_text(item.size_gb) or "",
			}
		end
	end
	fill_ledger(active)
	ledger = RowList.new(iup, {
		rows = ledger_rows, row_height = 36,
		column_widths = { 72, 112, 88, 128, 128, 80 }, column_align = { [1] = "LEFT", [2] = "LEFT", [3] = "LEFT", [4] = "LEFT", [5] = "LEFT" },
		role = "flatrows_plain",
		header = { title = "Title", columns = { "Year", "Resolution", "Video", "Range", "Audio", "Size" },
			sorted = { column = 0, descending = false } },
		on_select = function(pos) choose(active[pos]) end,
		on_activate = function(pos)
			local item = active[pos]
			if not item then return end
			if item.kind == "show" then api.open(item) else opts.on_play(item) end
		end,
		on_sort = function(column, descending)
			local key = LEDGER_KEYS[column]
			table.sort(active, function(a, b)
				local x, y = a[key] or "", b[key] or ""
				if type(x) ~= type(y) then x, y = tostring(x), tostring(y) end
				if descending then return x > y end
				return x < y
			end)
			fill_ledger(active)
			ledger:setRows(ledger_rows)
			mark_chosen()
		end,
	})
	iup.SetAttribute(ledger.widget, "EXPAND", "YES")

	local empty, set_empty = Kit.emptyPane(iup, { content = iup.vbox({}), icon = "media--library",
		title = "No media in this library yet",
		hint = "Add a folder and Lunar will find the films and shows inside it.",
		action = { title = "Add library", run = function() ctx:notify({ title = "Connect a server first" }, opts.owner) end } })
	set_empty(true)

	-- A title opens over the collection and goes back to it, so nothing is lost by looking.
	local opened
	local details = title_page.new(ctx, { cache = cache, art = wide_art, poster = art_of,
		on_back = function()
			opened = nil
			api.closeTitle()
		end,
		on_play = opts.on_play, on_mark = function(item, watched)
			item.progress = watched and 1 or 0
			if opts.on_mark then opts.on_mark(item, watched) end
			api.repaintArt()
		end,
		load_seasons = opts.load_seasons, decide = opts.decide,
		pool = function()
			local all = {}
			for _, film in ipairs(films) do all[#all + 1] = film end
			for _, show in ipairs(shows) do all[#all + 1] = show end
			return all
		end,
		on_open = function(item) api.open(item) end })
	drains[#drains + 1] = details.tick

	local stack = iup.zbox({ home, sheet.widget, ledger.widget, empty, details.widget, EXPAND = "YES" })

	-- The jump bar: letters that scroll the sheet. Slots stay for good; a list only retitles them.
	local jump_slots = {}
	local jump_box = iup.vbox({ GAP = "0", MARGIN = "0x0", ALIGNMENT = "ACENTER" })
	for i = 1, JUMP_SLOTS do
		local slot = iup.flatbutton({ TITLE = "", THEMEROLE = "settings_nav", RASTERSIZE = L.size(JUMP_WIDTH, JUMP_ROW), PADDING = "0x0" })
		function slot:flat_action()
			if jump_slots[i].index then sheet:scrollTo(jump_slots[i].index) end
			return iup.DEFAULT
		end
		jump_slots[i] = { button = slot }
		iup.Append(jump_box, slot)
	end
	local jump_room = JUMP_SLOTS
	local function fill_jump()
		local letters = organize.letters(active)
		local shows = not opened and source_id ~= "home" and view == "sheet" and sort == 1
			and organize.jumpShows(letters, #active)
		Kit.show(iup, jump_box, shows, sources_anchor())
		if not shows then return end
		local fitted = organize.fit(letters, jump_room)
		for i, slot in ipairs(jump_slots) do
			local entry = fitted[i]
			slot.index = entry and entry.index or nil
			iup.SetAttribute(slot.button, "TITLE", entry and entry.letter or "")
			Kit.show(iup, slot.button, entry ~= nil, sources_anchor())
		end
		iup.Refresh(jump_box)
	end

	local heading = L.pageTitle and L.pageTitle(iup, "Home") or iup.flatlabel({ TITLE = "Home", THEMEROLE = "pagetitle" })
	local count = L.hint(iup, "")

	local function apply_view()
		local index = 0
		if source_id ~= "home" then index = view == "ledger" and 2 or 1 end
		if #active == 0 and source_id ~= "home" then index = 3 end
		if opened then index = 4 end
		iup.SetAttribute(stack, "VALUEPOS", tostring(index))
		fill_jump()
	end
	local density_box
	local segmented = RowList.segmented(iup, { labels = { "Grid", "List" }, value_pos = 0,
		on_change = function(pos)
			view = pos == 1 and "ledger" or "sheet"
			apply_view()
			Kit.show(iup, density_box, view == "sheet", sources_anchor())
			iup.Refresh(api.widget)
		end })
	-- A filter in use looks in use, so the bar says at a glance what is hiding things.
	local function set_active(state)
		for field, box in pairs(api.filter_boxes or {}) do
			local wanted = state[field] ~= nil and "dropbutton" or "dropbutton_quiet"
			if iup.GetAttribute(box.widget, "THEMEROLE") ~= wanted then
				iup.SetAttribute(box.widget, "THEMEROLE", wanted)
				ctx:notifyTreeChange(box.widget)
			end
		end
	end

	-- Filters narrow what the rail chose. `active` is rebuilt, and the grid told, in one place.
	local function refilter()
		active = organize.apply(base, organize.rulesFor(filters))
		table.sort(active, SORTS[sort][2])
		sheet:setProvider(#active, cell_value(active))
		fill_ledger(active)
		ledger:setRows(ledger_rows)
		local total, shown = #base, #active
		local counted = shown == total and plural(total, "item") or (shown .. " of " .. total)
		local rule = collection and organize.describe(collection.rules) or ""
		iup.SetAttribute(count, "TITLE", rule ~= "" and (counted .. " · " .. rule) or counted)
		set_active(filters)
		apply_view()
		-- The inspector always describes something on the page.
		if position_in(active, chosen) == 0 and active[1] then choose(active[1]) else mark_chosen() end
	end

	local sort_box = FlatDropdown.new(iup, { items = { "Sort by title", "Sort by date added", "Sort by year" },
		value = 1, width = 192, role = "dropbutton_quiet",
		on_change = function(index)
			sort = index
			refilter()
		end })
	local controls = iup.hbox({ segmented, sort_box.widget, GAP = L.gap(3), ALIGNMENT = "ACENTER" })
	local toolbar = iup.hbox({ heading, count, iup.fill({}), controls, GAP = L.gap(3), ALIGNMENT = "ACENTER",
		EXPAND = "HORIZONTAL", MARGIN = RING .. "x0" })

	local WATCH_VALUES = { false, "unwatched", "progress", "watched" }
	local genre_values, decade_values, quality_values = { false }, { false }, { false }
	local clear_button, save_button
	local function filter_changed()
		local any = next(filters) ~= nil
		Kit.show(iup, clear_button, any, sources_anchor())
		Kit.show(iup, save_button, any, sources_anchor())
		refilter()
		iup.Refresh(api.widget)
	end
	local function picker(field, values, label, width)
		return FlatDropdown.new(iup, { items = { label }, value = 1, width = width, role = "dropbutton_quiet",
			on_change = function(index)
				local chosen_value = values()[index]
				filters[field] = chosen_value or nil
				filter_changed()
			end })
	end
	local watch_box = picker("watch", function() return WATCH_VALUES end, "All", FILTER_WIDTH)
	watch_box:setItems({ "Any status", "Unwatched", "In progress", "Watched" }, 1)
	local genre_box = picker("genre", function() return genre_values end, "Any genre", FILTER_WIDTH)
	local decade_box = picker("decade", function() return decade_values end, "Any decade", FILTER_WIDTH)
	local quality_box = picker("resolution", function() return quality_values end, "Any quality", FILTER_WIDTH)

	api.filter_boxes = { watch = watch_box, genre = genre_box, decade = decade_box, resolution = quality_box }

	local function fill_pickers()
		local facets = organize.facets(base)
		local function fill(box, values, all, entries, text)
			local labels = { all }
			for i = #values, 2, -1 do values[i] = nil end
			for _, entry in ipairs(entries) do
				values[#values + 1] = entry
				labels[#labels + 1] = text and text(entry) or tostring(entry)
			end
			box:setItems(labels, 1)
		end
		fill(genre_box, genre_values, "Any genre", facets.genres)
		fill(decade_box, decade_values, "Any decade", facets.decades, function(decade) return decade .. "s" end)
		fill(quality_box, quality_values, "Any quality", facets.resolutions)
		watch_box:setItems({ "Any status", "Unwatched", "In progress", "Watched" }, 1)
	end

	clear_button = iup.flatbutton({ TITLE = "Clear", THEMEROLE = "link_btn", CANFOCUS = "YES", flat_action = function()
		filters = {}
	fill_pickers()
	search:setValue("")
	filter_changed()
	return iup.DEFAULT
	end })
	save_button = Kit.button(iup, { icon = "bookmark", tip = "Save as collection", role = "icon_btn",
		action = function()
			local name = NameDialog.show({ iup = iup, title = "Save as collection", label = "Collection name:", ok = "Save" })
			if name and name ~= "" and opts.on_save_collection then
				opts.on_save_collection({ name = name, icon = "filter", rules = organize.rulesFor(filters) })
			end
		end })
	iup.SetAttribute(save_button, "RASTERSIZE", "32x32")

	local density = SeekBar.new(iup, { max = DENSITY_RANGE, role = "flatseek_plain",
		on_seek = function(value)
			ideal_cell = DENSITY_LEAST + value
			api.refit()
		end,
		on_changing = function(value)
			ideal_cell = DENSITY_LEAST + value
			api.refit()
		end })
	density:setValue(CELL - DENSITY_LEAST)
	iup.SetAttribute(density.widget, "RASTERSIZE", "64x")
	iup.SetAttribute(density.widget, "EXPAND", "NO")
	iup.SetAttribute(density.widget, "THICKNESS", "3")
	iup.SetAttribute(density.widget, "TIP", "Poster size")

	density_box = iup.hbox({ L.hint(iup, "Size"), density.widget, GAP = L.gap(2), MARGIN = "0x0", ALIGNMENT = "ACENTER" })
	local search = FlatField.new(iup, { cue = "Find a title", width = 148, on_change = function(text)
		filters.title = text ~= "" and text or nil
		filter_changed()
	end })
	api.search_field = search
	local filter_bar = iup.hbox({ search.widget, watch_box.widget, genre_box.widget, decade_box.widget, quality_box.widget,
		clear_button, iup.fill({}), save_button, density_box,
		GAP = L.gap(2), ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL", MARGIN = RING .. "x0" })

	-- Icons are asked for at paint time, so they follow the theme instead of the colours that
	-- were current when the extension loaded.
	local function source_value(pos, field)
		local source = model.sources[pos]
		if not source then return nil end
		if field == "TITLE" then return source.title end
		if field == "IMAGE" then return Kit.icon(iup, source.icon, 16, "text") end
		if field == "COLUMN1" then return source.count and tostring(source.count) or nil end
	end
	local go_source
	local shelf_list, origin_list
	local sources = RowList.new(iup, { value = source_value, count = #model.sources, row_height = 32,
		column_widths = { 40 }, role = "flatrows_plain",
		on_select = function(pos)
			shelf_list:select(0)
			origin_list:select(0)
			go_source(model.sources[pos].id)
		end })
	iup.SetAttribute(sources.widget, "RASTERSIZE", "x" .. (32 * RAIL_SOURCES + 8))
	iup.SetAttribute(sources.widget, "EXPAND", "HORIZONTAL")
	iup.SetAttribute(sources.widget, "FLATSCROLLBAR", "NO")
	sources_anchor = function() return sources.widget end

	-- Collections sit under the libraries. A smart one says so with its icon.
	local function collection_value(pos, field)
		local entry = (model.collections or {})[pos]
		if not entry then return nil end
		if field == "TITLE" then return entry.name end
		if field == "IMAGE" then return Kit.icon(iup, entry.icon or "bookmark", 16, "text") end
		if field == "COLUMN1" then return entry.count and tostring(entry.count) or nil end
	end
	shelf_list = RowList.new(iup, { value = collection_value, count = #(model.collections or {}), row_height = 32,
		column_widths = { 40 }, role = "flatrows_plain",
		empty_title = "No collections yet", empty_hint = "Filter a library, then save it.",
		on_select = function(pos)
			sources:select(0)
			origin_list:select(0)
			go_source("collection", (model.collections or {})[pos])
		end })
	iup.SetAttribute(shelf_list.widget, "EXPAND", "HORIZONTAL")
	iup.SetAttribute(shelf_list.widget, "FLATSCROLLBAR", "NO")

	-- Sources: where things come from, each a filter on the one combined library.
	local function origin_value(pos, field)
		local entry = (model.origins or {})[pos]
		if not entry then return nil end
		if field == "TITLE" then return entry.name end
		if field == "IMAGE" then return Kit.icon(iup, entry.icon or "globe", 16, "text") end
		if field == "COLUMN1" then
			local items = entry.items and tostring(entry.items) or ""
			return entry.status == "failed" and ("! " .. items) or items
		end
	end
	origin_list = RowList.new(iup, { value = origin_value, count = #(model.origins or {}), row_height = 32,
		column_widths = { 40 }, role = "flatrows_plain",
		on_select = function(pos)
			sources:select(0)
			shelf_list:select(0)
			go_source("collection", (model.origins or {})[pos])
		end })
	iup.SetAttribute(origin_list.widget, "EXPAND", "YES")
	iup.SetAttribute(origin_list.widget, "FLATSCROLLBAR", "NO")
	local function size_rail()
		iup.SetAttribute(shelf_list.widget, "RASTERSIZE", "x" .. (32 * math.max(#(model.collections or {}), 1) + 8))
	end
	size_rail()
	local rail_group = function(text)
		return iup.hbox({ iup.flatlabel({ TITLE = text, THEMEROLE = "reading_muted" }), MARGIN = "12x0" })
	end
	local scanning = Kit.statusLine(iup, "info", "")
	Kit.show(iup, scanning, false, sources.widget)
	local sample_note = iup.vbox({
		L.hint(iup, "This is a sample library."),
		iup.flatbutton({ TITLE = "Connect a server", THEMEROLE = "link_btn", CANFOCUS = "YES", flat_action = function()
			if opts.on_connect then opts.on_connect() end
			return iup.DEFAULT
		end }),
		GAP = L.gap(1), MARGIN = "0x0", ALIGNMENT = "ALEFT",
	})
	local source_rail = iup.vbox({ iup.hbox({ RASTERSIZE = L.size(SOURCE_WIDTH) }),
		rail_group("Libraries"), sources.widget,
		rail_group("Collections"), shelf_list.widget,
		rail_group("Sources"), origin_list.widget,
		L.stack(iup, { scanning, sample_note }, 2), GAP = L.gap(2), MARGIN = "0x0", EXPAND = "VERTICAL" })

	-- Everything the library holds, for a collection to draw from.
	local function everything()
		local all = {}
		for _, film in ipairs(films) do all[#all + 1] = film end
		for _, show in ipairs(shows) do all[#all + 1] = show end
		return all
	end

	local function members(entry)
		if entry.rules then return organize.apply(everything(), entry.rules) end
		local wanted, out = {}, {}
		for _, id in ipairs(entry.items or {}) do wanted[id] = true end
		for _, item in ipairs(everything()) do
			if wanted[item.id] then out[#out + 1] = item end
		end
		return out
	end

	local function count_collections()
		for _, entry in ipairs(model.collections or {}) do entry.count = #members(entry) end
	end

	go_source = function(id, entry)
		if id == "collection" and not entry then id = "home" end
		source_id = id
		collection = entry
		if id == "shows" then base = shows elseif id == "films" then base = films end
		if id == "collection" then base = members(entry) end
		filters = {}
		local title = entry and entry.name or "Home"
		for _, source in ipairs(model.sources) do
			if source.id == id then title = source.title end
		end
		iup.SetAttribute(heading, "TITLE", title)
		if api.fit and api.last_width then api.fit(api.last_width) end
		Kit.show(iup, toolbar, id ~= "home", sources.widget)
		Kit.show(iup, filter_bar, id ~= "home", sources.widget)
		Kit.show(iup, clear_button, false, sources.widget)
		Kit.show(iup, save_button, false, sources.widget)
		if id ~= "home" then
			fill_pickers()
			refilter()
		else
			iup.SetAttribute(count, "TITLE", "")
			apply_view()
			mark_chosen()
		end
		local place = position_in(active, chosen)
		if place > 0 then sheet:scrollTo(place) end
		iup.Refresh(api.widget)
	end

	local reliability = require("ui.reliability").new(ctx, model, opts.on_sources)
	local main = iup.vbox({ reliability.widget, toolbar, filter_bar, iup.hbox({ stack, jump_box, GAP = "0", MARGIN = "0x0", EXPAND = "YES" }),
		GAP = L.gap(3), MARGIN = "0x0", EXPAND = "YES" })
	local right = iup.vbox({ iup.hbox({ RASTERSIZE = L.size(INSPECTOR_WIDTH) }), inspector_body, MARGIN = "0x0", EXPAND = "VERTICAL" })
	-- Collections run to the bottom of the panel, so nothing is cut short of its edge.
	api.widget = iup.vbox({
		iup.fill({ RASTERSIZE = "1x16" }),
		iup.hbox({ source_rail, main, right, GAP = L.gap(5), MARGIN = "0x0", EXPAND = "YES" }),
		MARGIN = "16x0", EXPAND = "YES",
	})

	local fill_spotlight
	choose(continuing[1] or model.films[1])

	local function pick_view(name, position)
		view = name
		shelf_list:select(0)
		origin_list:select(0)
		iup.SetAttribute(segmented, "VALUEPOS", name == "ledger" and "1" or "0")
		sources:select(position)
	end

	function api.go(state, item)
		if state == "title" then
			pick_view("sheet", 2)
			go_source("films")
			api.open(model.films[6] or model.films[1])
			return
		elseif state == "show" then
			pick_view("sheet", 3)
			go_source("shows")
			api.open(model.shows[1])
			return
		end
		opened = nil
		if state == "source" then
			shelf_list:select(0)
			sources:select(0)
			origin_list:select(3)
			go_source("collection", (model.origins or {})[3])
			return
		end
		if state == "filtered" then
			pick_view("sheet", 2)
			go_source("films")
			Kit.show(iup, density_box, true, sources_anchor())
			filters = { watch = "unwatched" }
			fill_pickers()
			watch_box:setItems({ "Any status", "Unwatched", "In progress", "Watched" }, 2)
			filter_changed()
			return
		elseif state == "collection" then
			shelf_list:select(1)
			sources:select(0)
			go_source("collection", (model.collections or {})[1])
			return
		end
		if state == "home" then
			sources:select(1)
			go_source("home")
		elseif state == "sheet" then
			pick_view("sheet", 2)
			go_source("films")
			choose(active[2])
			sheet:scrollTo(2)
		elseif state == "info" then
			pick_view(view, item.kind == "show" and 3 or 2)
			go_source(item.kind == "show" and "shows" or "films")
			choose(item)
			sheet:scrollTo(position_in(active, item))
		elseif state == "ledger" then
			pick_view("ledger", 2)
			go_source("films")
			choose(model.films[3])
		elseif state == "shows" then
			pick_view("sheet", 3)
			go_source("shows")
			choose(model.shows[1])
		end
	end

	function api.fit(width)
		api.last_width = width
		-- Anchored on the rail, which shows exactly when this tab does: the inspector must never
		-- come back while another tab is in front.
		Kit.show(iup, right, width >= Adaptive.MEDIUM and source_id ~= "home" and not opened, sources.widget)
		Kit.show(iup, source_rail, width >= Adaptive.NARROW, stack)
	end

	-- Cells follow the width the collection really got, measured after layout.
	local last_width
	local function fit_cells()
		local width = tonumber((iup.GetAttribute(stack, "RASTERSIZE") or ""):match("^(%d+)"))
		if not width or width == last_width or width < CELL then return end
		last_width = width
		details.setWidth(width)
		sheet:setCellWidth(fitted_cell(width - 2 * RING - SCROLLBAR, ideal_cell))
		local shelf_cell = fitted_cell(width - 3 * RING - SCROLLBAR, ideal_cell)
		local wide_cell = fitted_cell(width - 3 * RING - SCROLLBAR, WIDE_CELL)
		recent_shelf:setCellWidth(shelf_cell)
		continue_shelf:setCellWidth(wide_cell)
		size_shelves(shelf_cell, wide_cell)
		iup.Refresh(api.widget)
	end

	function api.refit()
		last_width = nil
		fit_cells()
	end

	--- Show a new collection in the rail, and open it.
	function api.addCollection(entry)
		model.collections = model.collections or {}
		model.collections[#model.collections + 1] = entry
		entry.count = #members(entry)
		shelf_list:setProvider(#model.collections, collection_value)
		shelf_list:select(#model.collections)
		size_rail()
		sources:select(0)
		go_source("collection", entry)
	end

	local function refill(target, source)
		for i = #target, 1, -1 do target[i] = nil end
		for i, value in ipairs(source) do target[i] = value end
	end

	-- New and unwatched first, because the spotlight's job is to offer something, not to repeat
	-- Continue watching just below it.
	function fill_spotlight()
		local picks = {}
		for _, item in ipairs(recent) do
			if #picks < SPOTLIGHT_COUNT and (item.progress or 0) == 0 then picks[#picks + 1] = item end
		end
		hero.setItems(picks)
	end

	--- Show another library. Lists are refilled in place, because the grids stay for good.
	function api.setModel(next_model)
		model = next_model
		reliability.setModel(model)
		refill(films, model.films)
		refill(shows, model.shows)
		refill(continuing, model.continuing or {})
		refill(recent, model.films)
		table.sort(recent, SORTS[2][2])
		continue_shelf:setProvider(#continuing, cell_value(continuing, time_left))
		recent_shelf:setProvider(#recent, cell_value(recent))
		-- An empty shelf isn't news on a first visit, so it takes no room until there's something.
		Kit.show(iup, continue_section, #continuing > 0, recent_shelf.widget)
		sources:setProvider(#model.sources, source_value)
		shelf_list:setProvider(#(model.collections or {}), collection_value)
		origin_list:setProvider(#(model.origins or {}), origin_value)
		size_rail()
		Kit.setStatus(iup, scanning, "info", model.scanning and ("Scanning " .. model.scanning) or "")
		Kit.show(iup, scanning, model.scanning ~= nil, sources.widget)
		Kit.show(iup, sample_note, model.sample == true, sources.widget)
		sources:select(1)
		count_collections()
		shelf_list:setProvider(#(model.collections or {}), collection_value)
		go_source("home")
		fill_spotlight()
		refill_plan()
		choose(continuing[1] or recent[1] or shows[1])
	end

	local function set_chrome()
		local browsing = source_id ~= "home" and not opened
		Kit.show(iup, toolbar, browsing, sources.widget)
		Kit.show(iup, filter_bar, browsing, sources.widget)
		if api.last_width then api.fit(api.last_width) end
		apply_view()
		iup.Refresh(api.widget)
	end

	--- Open a title's page.
	-- @tparam table item
	function api.open(item)
		if not item then return end
		opened = item
		details.open(item)
		set_chrome()
	end

	function api.closeTitle()
		opened = nil
		set_chrome()
		mark_chosen()
	end

	--- A picture arrived: repaint whatever is showing, and pick the spotlight up too.
	function api.repaintArt()
		continue_shelf:setProvider(#continuing, cell_value(continuing, time_left))
		recent_shelf:setProvider(#recent, cell_value(recent))
		sheet:setProvider(#active, cell_value(active))
		if chosen then show_item(chosen) end
		hero.show(hero.current())
	end

	--- Find a film by its title.
	function api.find(title)
		for _, film in ipairs(films) do
			if film.title == title then return film end
		end
	end

	function api.first()
		return continuing[1] or recent[1]
	end

	function api.tick()
		fit_cells()
		for _, drain in ipairs(drains) do drain() end
	end

	count_collections()
	shelf_list:setProvider(#(model.collections or {}), collection_value)
	go_source("home")
	fill_spotlight()
	refill_plan()
	return api
end

return M
