--- The Media tab: sources, a collection and an inspector.
-- A click selects and fills the inspector, so nobody has to leave the collection to read
-- about a film. Enter or a double click plays. The ledger is a peer of the contact sheet.
-- @module ui.library

local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local CellGrid = require("core.ui.CellGrid")
local RowList = require("core.ui.RowList")
local FlatDropdown = require("core.ui.FlatDropdown")
local Adaptive = require("core.ui.Adaptive")
local spotlight = require("ui.spotlight")
local playback = require("libs.playback")

local M = {}

local CELL = 148           -- the size a cell aims for; columns then share the width exactly
local WIDE_CELL = 280      -- Continue watching: landscape cards, which also say how long is left
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
	if not minutes then return nil end
	if minutes < 60 then return minutes .. " min" end
	return string.format("%d h %d min", math.floor(minutes / 60), minutes % 60)
end

local function plural(count, word)
	return count .. " " .. word .. (count == 1 and "" or "s")
end

local function badge_of(item)
	if item.kind == "show" then return nil end
	if item.dynamic and item.dynamic ~= "SDR" then return item.dynamic == "Dolby Vision" and "DV" or "HDR" end
	if item.resolution == "2160p" then return "4K" end
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
		if field == "BADGE" then return badge_of(item) end
		if field == "PROGRESS" then
			local p = item.progress or 0
			if p > 0 and p < 1 then return tostring(math.floor(p * 100)) end
		end
		return nil
	end
end

local SORTS = {
	{ "Title", function(a, b) return a.title < b.title end },
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

local function inspector(ctx, cache, art_of, on_play)
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
		action = function() if current then on_play(current) end end })
	iup.SetAttribute(play, "RASTERSIZE", L.size(HEAD_TEXT, ACTION_HEIGHT))
	local queue = Kit.button(iup, { title = "Queue", icon = "add", action = function() end })
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
	local section = L.sectionTitle(iup, "File")

	local head = iup.hbox({
		poster.widget,
		iup.vbox({ iup.fill({}), meta, play, queue, GAP = L.gap(2), MARGIN = "0x" .. RING, EXPAND = "VERTICAL" }),
		GAP = L.gap(3), MARGIN = "0x0", EXPAND = "HORIZONTAL",
	})
	local body = L.stack(iup, {
		iup.hbox({ title, MARGIN = RING .. "x0" }),
		head,
		iup.vbox({
			L.stack(iup, { overview, tracks }, 4),
			L.stack(iup, { section, fact_box }, 3),
			GAP = L.gap(6), MARGIN = RING .. "x0", EXPAND = "HORIZONTAL",
		}),
	}, 2)
	iup.SetAttribute(body, "EXPAND", "YES")

	local function fill(rows)
		for i, entry in ipairs(facts) do
			local data = rows[i]
			Kit.show(iup, entry.row, data ~= nil, section)
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
		iup.SetAttribute(play, "TITLE", (item.progress or 0) > 0 and item.progress < 1 and "Resume" or "Play")
		local is_show = item.kind == "show"
		if is_show then
			iup.SetAttribute(meta, "TITLE", string.format("%d · %s", item.year, plural(item.seasons or 0, "season")))
			iup.SetAttribute(section, "TITLE", "Series")
			fill({ { "Seasons", tostring(item.seasons or 0) }, { "Episodes", tostring(item.episodes or 0) },
				{ "Resolution", item.resolution or "Mixed" }, { "Added", item.added or "" } })
		else
			local length = runtime(item.minutes)
			iup.SetAttribute(meta, "TITLE", length and (item.year .. " · " .. length) or tostring(item.year))
			iup.SetAttribute(section, "TITLE", "File")
			fill({ { "Resolution", item.resolution or UNKNOWN }, { "Video", item.codec or UNKNOWN },
				{ "Range", item.dynamic or UNKNOWN }, { "Audio", item.audio or UNKNOWN },
				{ "Bitrate", item.bitrate and string.format("%.1f Mb/s", item.bitrate) or UNKNOWN },
				{ "Size", item.size_gb and string.format("%.1f GB", item.size_gb) or UNKNOWN },
				{ "Added", item.added or UNKNOWN },
				item.path and { "File", item.path:match("[^/\\]+$") } or nil })
		end
		Kit.show(iup, tracks, not is_show, section)
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
	local active = films
	local source_id = "home"
	local view = "sheet"
	local sort = 1
	local chosen
	local continuing, recent = {}, {}
	for _, film in ipairs(model.films) do
		if (film.progress or 0) > 0 and film.progress < 1 then continuing[#continuing + 1] = film end
	end
	for i, film in ipairs(model.films) do recent[i] = film end
	table.sort(recent, SORTS[2][2])

	local inspector_body, show_item, inspector_posters = inspector(ctx, cache, art_of, opts.on_play)
	drains[#drains + 1] = inspector_posters

	local shelves, sheet, ledger, hero

	local function position_in(list, item)
		for i, candidate in ipairs(list) do
			if candidate == item then return i end
		end
		return 0
	end

	-- Whatever fills the inspector is marked wherever it appears, so the two zones read as one.
	local function mark_chosen()
		for _, shelf in ipairs(shelves) do shelf.grid:select(position_in(shelf.list, chosen)) end
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
				if item then opts.on_play(item) end
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
		on_info = function(item) api.go("info", item) end })
	drains[#drains + 1] = hero.tick
	local home_body = L.stack(iup, {
		iup.hbox({ hero.widget, MARGIN = RING .. "x0" }),
		L.stack(iup, { aligned(L.sectionTitle(iup, "Continue watching")), continue_shelf.widget }, 2),
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
				column6 = item.size_gb and string.format("%.1f GB", item.size_gb) or "",
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
		on_activate = function(pos) if active[pos] then opts.on_play(active[pos]) end end,
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

	local stack = iup.zbox({ home, sheet.widget, ledger.widget, empty, EXPAND = "YES" })

	local heading = L.pageTitle and L.pageTitle(iup, "Home") or iup.flatlabel({ TITLE = "Home", THEMEROLE = "pagetitle" })
	local count = L.hint(iup, "")

	local function apply_view()
		local index = 0
		if source_id ~= "home" then index = view == "ledger" and 2 or 1 end
		if #active == 0 and source_id ~= "home" then index = 3 end
		iup.SetAttribute(stack, "VALUEPOS", tostring(index))
	end
	local segmented = RowList.segmented(iup, { labels = { "Grid", "List" }, value_pos = 0,
		on_change = function(pos)
			view = pos == 1 and "ledger" or "sheet"
			apply_view()
		end })
	local sort_box = FlatDropdown.new(iup, { items = { "Sort by title", "Sort by date added", "Sort by year" },
		value = 1, width = 192, role = "dropbutton_quiet",
		on_change = function(index)
			sort = index
			table.sort(active, SORTS[sort][2])
			fill_ledger(active)
			ledger:setRows(ledger_rows)
			sheet:setProvider(#active, cell_value(active))
			mark_chosen()
		end })
	local controls = iup.hbox({ segmented, sort_box.widget, GAP = L.gap(3), ALIGNMENT = "ACENTER" })
	local toolbar = iup.hbox({ heading, count, iup.fill({}), controls, GAP = L.gap(3), ALIGNMENT = "ACENTER",
		EXPAND = "HORIZONTAL", MARGIN = RING .. "x0" })

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
	local sources = RowList.new(iup, { value = source_value, count = #model.sources, row_height = 32,
		column_widths = { 40 }, role = "flatrows_plain",
		on_select = function(pos) go_source(model.sources[pos].id) end })
	iup.SetAttribute(sources.widget, "EXPAND", "YES")
	iup.SetAttribute(sources.widget, "FLATSCROLLBAR", "NO")
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
	local source_rail = iup.vbox({ iup.hbox({ RASTERSIZE = L.size(SOURCE_WIDTH) }), sources.widget,
		L.stack(iup, { scanning, sample_note }, 2), GAP = L.gap(3), MARGIN = "0x0", EXPAND = "VERTICAL" })

	go_source = function(id)
		source_id = id
		if id == "shows" then active = shows elseif id == "films" then active = films end
		local title = "Home"
		for _, source in ipairs(model.sources) do
			if source.id == id then title = source.title end
		end
		iup.SetAttribute(heading, "TITLE", title)
		if api.fit and api.last_width then api.fit(api.last_width) end
		iup.SetAttribute(count, "TITLE", id == "home" and "" or plural(#active, "item"))
		Kit.show(iup, toolbar, id ~= "home", sources.widget)
		if id ~= "home" then
			table.sort(active, SORTS[sort][2])
			sheet:setProvider(#active, cell_value(active))
			fill_ledger(active)
			ledger:setRows(ledger_rows)
		end
		apply_view()
		mark_chosen()
		local place = position_in(active, chosen)
		if place > 0 then sheet:scrollTo(place) end
		iup.Refresh(api.widget)
	end

	local main = iup.vbox({ toolbar, stack, GAP = L.gap(5), MARGIN = "0x0", EXPAND = "YES" })
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
		iup.SetAttribute(segmented, "VALUEPOS", name == "ledger" and "1" or "0")
		sources:select(position)
	end

	function api.go(state, item)
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
		Kit.show(iup, right, width >= Adaptive.MEDIUM and source_id ~= "home", stack)
		Kit.show(iup, source_rail, width >= Adaptive.NARROW, stack)
	end

	-- Cells follow the width the collection really got, measured after layout.
	local last_width
	local function fit_cells()
		local width = tonumber((iup.GetAttribute(stack, "RASTERSIZE") or ""):match("^(%d+)"))
		if not width or width == last_width or width < CELL then return end
		last_width = width
		sheet:setCellWidth(fitted_cell(width - 2 * RING - SCROLLBAR, CELL))
		local shelf_cell = fitted_cell(width - 2 * RING - SCROLLBAR, CELL)
		local wide_cell = fitted_cell(width - 2 * RING - SCROLLBAR, WIDE_CELL)
		recent_shelf:setCellWidth(shelf_cell)
		continue_shelf:setCellWidth(wide_cell)
		size_shelves(shelf_cell, wide_cell)
		iup.Refresh(api.widget)
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
		refill(films, model.films)
		refill(shows, model.shows)
		refill(continuing, model.continuing or {})
		refill(recent, model.films)
		table.sort(recent, SORTS[2][2])
		continue_shelf:setProvider(#continuing, cell_value(continuing, time_left))
		recent_shelf:setProvider(#recent, cell_value(recent))
		sources:setProvider(#model.sources, source_value)
		Kit.setStatus(iup, scanning, "info", model.scanning and ("Scanning " .. model.scanning) or "")
		Kit.show(iup, scanning, model.scanning ~= nil, sources.widget)
		Kit.show(iup, sample_note, model.sample == true, sources.widget)
		sources:select(1)
		go_source("home")
		fill_spotlight()
		choose(continuing[1] or recent[1] or shows[1])
	end

	function api.first()
		return continuing[1] or recent[1]
	end

	function api.tick()
		fit_cells()
		for _, drain in ipairs(drains) do drain() end
	end

	go_source("home")
	fill_spotlight()
	return api
end

return M
