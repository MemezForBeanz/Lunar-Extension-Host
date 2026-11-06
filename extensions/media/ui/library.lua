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

local M = {}

local CELL = 148
local SHELF_CELL = 132
local SHELF_HEIGHT = 262
local INSPECTOR_ART = 168
local SOURCE_WIDTH = 240
local INSPECTOR_WIDTH = L.SIDE.narrow

local function runtime(minutes)
	if not minutes then return nil end
	if minutes < 60 then return minutes .. " min" end
	return string.format("%d h %d min", math.floor(minutes / 60), minutes % 60)
end

local function badge_of(item)
	if item.kind == "show" then return nil end
	if item.dynamic and item.dynamic ~= "SDR" then return item.dynamic == "Dolby Vision" and "DV" or "HDR" end
	if item.resolution == "2160p" then return "4K" end
end

local function subtitle_of(item)
	if item.kind == "show" then
		return string.format("%d · %d seasons", item.year, item.seasons)
	end
	return tostring(item.year)
end

local function cell_value(list)
	return function(pos, field)
		local item = list[pos]
		if not item then return nil end
		if field == "TITLE" then return item.title end
		if field == "SECONDARY" then return subtitle_of(item) end
		if field == "BADGE" then return badge_of(item) end
		if field == "PROGRESS" then
			local p = item.progress or 0
			if p > 0 and p < 1 then return tostring(math.floor(p * 100)) end
			return nil
		end
		if field == "STATE" then
			if (item.progress or 0) == 0 then return "unplayed" end
			return nil
		end
	end
end

local SORTS = {
	{ "Title", function(a, b) return a.title < b.title end },
	{ "Recently added", function(a, b) return a.added > b.added end },
	{ "Year", function(a, b) return (a.year or 0) > (b.year or 0) end },
}

local LEDGER_KEYS = { [0] = "title", "year", "resolution", "codec", "dynamic", "audio", "size_gb" }

local function fact(iup, label)
	local name = L.hint(iup, label)
	iup.SetAttribute(name, "RASTERSIZE", "96x")
	local value = iup.flatlabel({ TITLE = "", EXPAND = "HORIZONTAL" })
	local row = iup.hbox({ name, value, GAP = L.gap(3), ALIGNMENT = "ACENTER" })
	return row, value
end

local function inspector(ctx, cache, art_of, on_play)
	local iup = ctx.iup
	local current
	local poster = CellGrid.new(iup, {
		count = 0, cell_width = INSPECTOR_ART, aspect = "2:3", show_text = false, gutter = 0, padding = 0,
		value = function() return nil end,
	})
	iup.SetAttribute(poster.widget, "RASTERSIZE", L.size(INSPECTOR_ART, INSPECTOR_ART * 3 / 2))
	iup.SetAttribute(poster.widget, "EXPAND", "NO")
	iup.SetAttribute(poster.widget, "CANFOCUS", "NO")
	iup.SetAttribute(poster.widget, "FLATSCROLLBAR", "NO")
	local posters = cache and CellGrid.posters(poster, cache, function() return current and art_of(current) end)

	local title = iup.flatlabel({ TITLE = "", THEMEROLE = "sectiontitle", EXPAND = "HORIZONTAL", WORDWRAP = "YES" })
	local meta = L.hint(iup, "")
	local overview = iup.flatlabel({ TITLE = "", WORDWRAP = "YES", EXPAND = "HORIZONTAL" })
	local play = Kit.button(iup, { title = "Play", icon = "play--filled--alt", role = "primary_btn",
		action = function() if current then on_play(current) end end })
	local queue = Kit.button(iup, { title = "Queue", icon = "add", action = function() end })

	local rows, values = {}, {}
	for i, label in ipairs({ "Resolution", "Video", "Range", "Audio", "Bitrate", "Size", "Added" }) do
		rows[i], values[label] = fact(iup, label)
	end
	local audio = FlatDropdown.new(iup, { items = { "English 5.1" }, value = 1, expand = true })
	local subtitles = FlatDropdown.new(iup, { items = { "Off" }, value = 1, expand = true })
	local audio_row = iup.hbox({ L.hint(iup, "Audio track"), audio.widget, GAP = L.gap(3), ALIGNMENT = "ACENTER" })
	local subtitle_row = iup.hbox({ L.hint(iup, "Subtitles"), subtitles.widget, GAP = L.gap(3), ALIGNMENT = "ACENTER" })
	iup.SetAttribute(iup.GetChild(audio_row, 0), "RASTERSIZE", "96x")
	iup.SetAttribute(iup.GetChild(subtitle_row, 0), "RASTERSIZE", "96x")

	local facts = iup.vbox({ GAP = L.gap(2), MARGIN = "0x0", EXPAND = "HORIZONTAL" })
	for _, row in ipairs(rows) do iup.Append(facts, row) end
	local path = L.hint(iup, "")
	iup.SetAttribute(path, "WORDWRAP", "YES")
	iup.SetAttribute(path, "EXPAND", "HORIZONTAL")

	local body = L.stack(iup, {
		poster.widget,
		L.stack(iup, { title, meta }, 1),
		L.row(iup, { play, queue }),
		overview,
		L.stack(iup, { audio_row, subtitle_row }, 2),
		L.sectionTitle(iup, "File"),
		facts,
		path,
	}, 4)
	iup.SetAttribute(body, "EXPAND", "YES")

	local function show(item)
		current = item
		if not item then return end
		iup.SetAttribute(title, "TITLE", item.title)
		local parts = { tostring(item.year) }
		if item.minutes then parts[#parts + 1] = runtime(item.minutes) end
		if item.seasons then parts[#parts + 1] = item.seasons .. " seasons, " .. item.episodes .. " episodes" end
		iup.SetAttribute(meta, "TITLE", table.concat(parts, " · "))
		iup.SetAttribute(overview, "TITLE", item.overview or "")
		iup.SetAttribute(play, "TITLE", (item.progress or 0) > 0 and (item.progress or 0) < 1 and "Resume" or "Play")
		iup.SetAttribute(values.Resolution, "TITLE", item.resolution or "Mixed")
		iup.SetAttribute(values.Video, "TITLE", item.codec or "By episode")
		iup.SetAttribute(values.Range, "TITLE", item.dynamic or "By episode")
		iup.SetAttribute(values.Audio, "TITLE", item.audio or "By episode")
		iup.SetAttribute(values.Bitrate, "TITLE", item.bitrate and string.format("%.1f Mb/s", item.bitrate) or "By episode")
		iup.SetAttribute(values.Size, "TITLE", item.size_gb and string.format("%.1f GB", item.size_gb) or "By episode")
		iup.SetAttribute(values.Added, "TITLE", item.added or "")
		iup.SetAttribute(path, "TITLE", item.path or "")
		local tracks = { item.audio or "Default" }
		audio:setItems(tracks, 1)
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
-- @treturn table `widget`, `go(state)`, `fit(width)`, `tick()`, `close()`
function M.new(ctx, opts)
	local iup = ctx.iup
	local model, cache, art_of = opts.model, opts.cache, opts.art_of
	local api = {}
	local drains = {}
	local films = {}
	for i, film in ipairs(model.films) do films[i] = film end
	local shows = {}
	for i, show in ipairs(model.shows) do shows[i] = show end
	local active = films
	local source_id = "home"
	local view = "sheet"
	local sort = 1
	local continuing, recent = {}, {}
	for _, film in ipairs(model.films) do
		if (film.progress or 0) > 0 and film.progress < 1 then continuing[#continuing + 1] = film end
	end
	for i, film in ipairs(model.films) do recent[i] = film end
	table.sort(recent, SORTS[2][2])

	local inspector_body, show_item, inspector_posters = inspector(ctx, cache, art_of, opts.on_play)
	drains[#drains + 1] = inspector_posters

	local function poster_source(list)
		return function(pos)
			local item = list[pos]
			return item and art_of(item)
		end
	end

	local function grid_for(list, extra)
		local args = {
			count = #list, value = cell_value(list), cell_width = extra.cell, aspect = "2:3", gutter = 16, padding = 0,
			shelf = extra.shelf,
			on_select = function(pos) if list[pos] then show_item(list[pos]) end end,
			on_activate = function(pos) if list[pos] then opts.on_play(list[pos]) end end,
		}
		local grid = CellGrid.new(iup, args)
		if cache then drains[#drains + 1] = CellGrid.posters(grid, cache, poster_source(list)) end
		return grid
	end

	local continue_shelf = grid_for(continuing, { cell = SHELF_CELL, shelf = true })
	local recent_shelf = grid_for(recent, { cell = SHELF_CELL, shelf = true })
	for _, shelf in ipairs({ continue_shelf, recent_shelf }) do
		iup.SetAttribute(shelf.widget, "RASTERSIZE", "x" .. SHELF_HEIGHT)
		iup.SetAttribute(shelf.widget, "EXPAND", "HORIZONTAL")
	end
	local home = iup.vbox({
		L.sectionTitle(iup, "Continue watching"), continue_shelf.widget,
		L.sectionTitle(iup, "Recently added"), recent_shelf.widget,
		iup.fill({}),
		GAP = L.gap(3), MARGIN = "0x0", EXPAND = "YES",
	})

	local sheet = grid_for(active, { cell = CELL })
	iup.SetAttribute(sheet.widget, "EXPAND", "YES")

	local ledger_rows = {}
	local function fill_ledger(list)
		ledger_rows = {}
		for i, item in ipairs(list) do
			ledger_rows[i] = {
				title = item.title, column1 = tostring(item.year), column2 = item.resolution or "",
				column3 = item.codec or "", column4 = item.dynamic or "", column5 = item.audio or "",
				column6 = item.size_gb and string.format("%.1f GB", item.size_gb) or "",
				progress = (item.progress or 0) > 0 and item.progress < 1 and math.floor(item.progress * 100) or nil,
			}
		end
	end
	fill_ledger(active)
	local ledger
	ledger = RowList.new(iup, {
		rows = ledger_rows, row_height = 32,
		column_widths = { 56, 72, 72, 104, 120, 80 },
		header = { title = "Title", columns = { "Year", "Resolution", "Video", "Range", "Audio", "Size" },
			sorted = { column = 0, descending = false } },
		on_select = function(pos) if active[pos] then show_item(active[pos]) end end,
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
		end,
	})
	iup.SetAttribute(ledger.widget, "EXPAND", "YES")

	local empty_action = { title = "Add Library", run = function() ctx:notify({ title = "Connect a server first" }, opts.owner) end }
	local empty, set_empty = Kit.emptyPane(iup, { content = iup.vbox({}), icon = "media--library",
		title = "No media in this library yet",
		hint = "Add a folder and Lunar will find the films and shows inside it.",
		action = empty_action })
	set_empty(true)

	local stack = iup.zbox({ home, sheet.widget, ledger.widget, empty, EXPAND = "YES" })

	local heading = iup.flatlabel({ TITLE = "Home", THEMEROLE = "pagetitle" })
	local count = L.hint(iup, "")
	local segmented_host
	local function apply_view()
		local index = 0
		if source_id ~= "home" then index = view == "ledger" and 2 or 1 end
		if #active == 0 and source_id ~= "home" then index = 3 end
		iup.SetAttribute(stack, "VALUEPOS", tostring(index))
	end
	segmented_host = RowList.segmented(iup, { labels = { "Sheet", "Ledger" }, value_pos = 0,
		on_change = function(pos)
			view = pos == 1 and "ledger" or "sheet"
			apply_view()
		end })
	local sort_box = FlatDropdown.new(iup, { items = { "Title", "Recently added", "Year" }, value = 1, width = 168,
		on_change = function(index)
			sort = index
			table.sort(active, SORTS[sort][2])
			fill_ledger(active)
			ledger:setRows(ledger_rows)
			sheet:setProvider(#active, cell_value(active))
		end })
	local controls = iup.hbox({ segmented_host, sort_box.widget, GAP = L.gap(3), ALIGNMENT = "ACENTER" })
	local toolbar = iup.hbox({ heading, count, iup.fill({}), controls, GAP = L.gap(3), ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL" })

	local banner = Kit.statusLine(iup, "idle", "Showing a sample library. Connect a server in Settings to see yours.")

	local source_rows = {}
	for i, source in ipairs(model.sources) do
		source_rows[i] = { title = source.title, image = Kit.icon(iup, source.icon, 16, "text"),
			column1 = source.count and tostring(source.count) or "" }
	end
	local go_source
	local sources = RowList.new(iup, { rows = source_rows, row_height = 32, column_widths = { 40 },
		on_select = function(pos) go_source(model.sources[pos].id) end })
	iup.SetAttribute(sources.widget, "EXPAND", "YES")
	local scan_line = Kit.statusLine(iup, "info", "Scanning Shows")
	local source_rail = iup.vbox({ iup.hbox({ RASTERSIZE = L.size(SOURCE_WIDTH) }), sources.widget, scan_line,
		GAP = L.gap(3), MARGIN = "0x0", EXPAND = "VERTICAL" })

	go_source = function(id)
		source_id = id
		if id == "shows" then active = shows elseif id == "films" then active = films end
		local title = "Home"
		for _, source in ipairs(model.sources) do
			if source.id == id then title = source.title end
		end
		iup.SetAttribute(heading, "TITLE", title)
		iup.SetAttribute(count, "TITLE", id == "home" and "" or (#active .. " items"))
		Kit.show(iup, controls, id ~= "home", sources.widget)
		if id ~= "home" then
			table.sort(active, SORTS[sort][2])
			sheet:setProvider(#active, cell_value(active))
			fill_ledger(active)
			ledger:setRows(ledger_rows)
		end
		apply_view()
		iup.Refresh(api.widget)
	end

	local main = iup.vbox({ toolbar, banner, stack, GAP = L.gap(4), MARGIN = "0x0", EXPAND = "YES" })
	local right = iup.vbox({ iup.hbox({ RASTERSIZE = L.size(INSPECTOR_WIDTH) }), inspector_body, MARGIN = "0x0", EXPAND = "VERTICAL" })
	api.widget = iup.hbox({ source_rail, main, right, GAP = L.gap(5), MARGIN = L.margin(5), EXPAND = "YES" })

	show_item(continuing[1] or model.films[1])

	function api.go(state)
		if state == "home" then
			go_source("home")
			sources:select(1)
		elseif state == "sheet" then
			view = "sheet"
			iup.SetAttribute(segmented_host, "VALUEPOS", "0")
			go_source("films")
			sources:select(2)
		elseif state == "ledger" then
			view = "ledger"
			iup.SetAttribute(segmented_host, "VALUEPOS", "1")
			go_source("films")
			sources:select(2)
			show_item(model.films[3])
		elseif state == "shows" then
			view = "sheet"
			iup.SetAttribute(segmented_host, "VALUEPOS", "0")
			go_source("shows")
			sources:select(3)
			show_item(model.shows[1])
		end
	end

	function api.fit(width)
		Kit.show(iup, right, width >= Adaptive.MEDIUM, sources.widget)
		Kit.show(iup, source_rail, width >= Adaptive.NARROW, stack)
	end

	function api.tick()
		for _, drain in ipairs(drains) do drain() end
	end

	go_source("home")
	return api
end

return M
