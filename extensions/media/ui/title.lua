--- A title's own page: what it is, how to play it, and for a show, every season and episode.
-- It opens from the collection and goes back to the same place. The spotlight's tinted surface
-- carries over, so a film looks the same from Home to here.
-- @module ui.title

local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local CellGrid = require("core.ui.CellGrid")
local RowList = require("core.ui.RowList")
local FlatDropdown = require("core.ui.FlatDropdown")
local spotlight = require("ui.spotlight")
local organize = require("libs.organize")
local forecast = require("libs.forecast")

local M = {}

local EPISODE_ROW = 56
local RING = 6
local SHELF_CELL = 132
local CELL_TEXT = 62
local SCROLLBAR = 8
local SIMILAR = 12
local FACT_LABEL = 72
local FORECAST_DEVICE = 168
local FORECAST_HEADLINE = 216
local FACTS = { "Genres", "Cast", "Video", "Audio", "Rating" }

local function runtime(minutes)
	if not minutes or minutes < 1 then return "" end
	if minutes < 60 then return minutes .. " min" end
	return string.format("%d h %d min", math.floor(minutes / 60), minutes % 60)
end

local function episode_state(episode)
	local state = organize.watchState(episode)
	if state == "watched" then return "Watched" end
	if state == "progress" then
		return math.ceil((episode.minutes or 0) * (1 - episode.progress)) .. " min left"
	end
	return ""
end

--- Rows for one season.
-- @tparam table season `{ number, episodes }`
-- @tparam[opt] table upcoming the episode Play will start
-- @treturn table
function M.rows(season, upcoming)
	local rows = {}
	for i, episode in ipairs(season.episodes) do
		rows[i] = { title = episode.title, secondary = "Episode " .. (episode.episode or i),
			column1 = runtime(episode.minutes), column2 = episode == upcoming and "Next up" or episode_state(episode) }
	end
	return rows
end

--- Build the page.
-- @tparam table ctx host context
-- @tparam table opts `cache`, `art(item)`, `poster(item)`, `on_back()`, `on_play(item, queue)`,
--   `on_mark(item, watched)`, `load_seasons(item, done)`, `pool()` (items to compare with),
--   `on_open(item)`
-- @treturn table `widget`, `open(item)`, `tick()`
function M.new(ctx, opts)
	local iup = ctx.iup
	local api = {}
	local current, seasons, season_index = nil, {}, 1
	local similar = {}

	local back = Kit.button(iup, { title = "Back", icon = "arrow--left", role = "actionbutton",
		action = function() opts.on_back() end })
	iup.SetAttribute(back, "RASTERSIZE", "x32")

	local hero = spotlight.new(ctx, { cache = opts.cache, art = opts.art, compact = true,
		on_play = function()
			if not current then return end
			if current.kind ~= "show" then return opts.on_play(current) end
			local episode = organize.nextEpisode(seasons)
			if episode then opts.on_play(episode, organize.after(seasons, episode)) end
		end,
		secondary = {
			label = function(item)
				local noun = item.kind == "show" and "series " or ""
				return (organize.watchState(item) == "watched" and "Mark " .. noun .. "unwatched" or "Mark " .. noun .. "watched")
			end,
			run = function(item)
				opts.on_mark(item, organize.watchState(item) ~= "watched")
				api.refresh()
			end,
		},
	})

	-- Labelled rows, story first, so a codec is never read as a genre.
	local fact_rows = {}
	local fact_box = iup.vbox({ GAP = L.gap(1), MARGIN = "0x0", EXPAND = "HORIZONTAL" })
	for i, label in ipairs(FACTS) do
		local name = iup.flatlabel({ TITLE = label, THEMEROLE = "reading_muted", RASTERSIZE = FACT_LABEL .. "x" })
		local value = iup.flatlabel({ TITLE = "", THEMEROLE = "reading", EXPAND = "HORIZONTAL", TEXTELLIPSIS = "YES" })
		local row = iup.hbox({ name, value, GAP = L.gap(3), ALIGNMENT = "ACENTER", MARGIN = "0x0", EXPAND = "HORIZONTAL" })
		fact_rows[i] = { row = row, value = value }
		iup.Append(fact_box, row)
	end

	-- One line for each device: will it play, why, and what would change the answer.
	local forecast_rows = {}
	local forecast_box = iup.vbox({ GAP = L.gap(2), MARGIN = "0x0", EXPAND = "HORIZONTAL" })
	for i, profile in ipairs(forecast.PROFILES) do
		local status = Kit.statusLine(iup, "idle", profile.name)
		iup.SetAttribute(status, "EXPAND", "NO")
		iup.SetAttribute(status, "RASTERSIZE", FORECAST_DEVICE .. "x")
		iup.SetAttribute(status, "THEMEROLE", "reading")
		local headline = iup.flatlabel({ TITLE = "", THEMEROLE = "reading", RASTERSIZE = FORECAST_HEADLINE .. "x" })
		local why = iup.flatlabel({ TITLE = "", THEMEROLE = "reading_muted", EXPAND = "HORIZONTAL", TEXTELLIPSIS = "YES" })
		local row = iup.hbox({ status, headline, why, GAP = L.gap(3), ALIGNMENT = "ACENTER", MARGIN = "0x0", EXPAND = "HORIZONTAL" })
		forecast_rows[i] = { row = row, status = status, headline = headline, why = why, profile = profile }
		iup.Append(forecast_box, row)
	end
	local all_clear = Kit.statusLine(iup, "ok", "")
	iup.SetAttribute(all_clear, "THEMEROLE", "reading")
	local forecast_section = L.stack(iup, { L.sectionTitle(iup, "Where it plays"), all_clear, forecast_box }, 2)

	local function show_forecast(row, decision)
		local verdict = forecast.verdict(decision)
		Kit.setStatus(iup, row.status, verdict.tone, row.profile.name)
		iup.SetAttribute(row.headline, "TITLE", verdict.headline)
		iup.SetAttribute(row.why, "TITLE", verdict.fix and (verdict.why .. " " .. verdict.fix) or verdict.why)
	end

	-- Three rows saying the same good news is one line of good news.
	local function settle_forecast(pending, clear)
		if pending > 0 then return end
		Kit.show(iup, all_clear, clear, back)
		Kit.show(iup, forecast_box, not clear, back)
		if clear then Kit.setStatus(iup, all_clear, "ok", "Plays as it is on all " .. #forecast_rows .. " devices") end
		iup.Refresh(api.widget)
	end

	local function load_forecast(item)
		local pending, clear = #forecast_rows, true
		Kit.show(iup, all_clear, false, back)
		Kit.show(iup, forecast_box, true, back)
		for _, row in ipairs(forecast_rows) do
			Kit.setStatus(iup, row.status, "idle", row.profile.name)
			iup.SetAttribute(row.headline, "TITLE", "Checking")
			iup.SetAttribute(row.why, "TITLE", "")
			opts.decide(item, row.profile, function(decision)
				if current ~= item or not decision then return end
				show_forecast(row, decision)
				pending = pending - 1
				clear = clear and decision.mode == "direct"
				settle_forecast(pending, clear)
			end)
		end
	end

	local episodes = RowList.new(iup, { rows = {}, row_height = EPISODE_ROW, column_widths = { 96, 112 },
		role = "flatrows_plain", empty_title = "No episodes yet", empty_hint = "They appear here after a scan.",
		on_activate = function(pos)
			local season = seasons[season_index]
			local episode = season and season.episodes[pos]
			if episode then opts.on_play(episode, organize.after(seasons, episode)) end
		end })
	iup.SetAttribute(episodes.widget, "EXPAND", "HORIZONTAL")

	local function show_season(index)
		season_index = index
		local season = seasons[index]
		local upcoming = organize.nextEpisode(seasons)
		local rows = season and M.rows(season, upcoming) or {}
		episodes:setRows(rows)
		iup.SetAttribute(episodes.widget, "RASTERSIZE", "x" .. (EPISODE_ROW * #rows + 8))
		local mark = 0
		for i, episode in ipairs(season and season.episodes or {}) do
			if episode == upcoming then mark = i end
		end
		episodes:select(mark)
		iup.Refresh(api.widget)
	end

	local season_box = FlatDropdown.new(iup, { items = { "Season 1" }, value = 1, width = 168, role = "dropbutton_quiet",
		on_change = function(index) show_season(index) end })
	local mark_season = Kit.button(iup, { title = "Mark season watched", role = "actionbutton", action = function()
		local season = seasons[season_index]
		if not season then return end
		for _, episode in ipairs(season.episodes) do opts.on_mark(episode, true) end
		show_season(season_index)
	end })
	iup.SetAttribute(mark_season, "RASTERSIZE", "x32")

	local season_bar = iup.hbox({ season_box.widget, iup.fill({}), mark_season, GAP = L.gap(3), ALIGNMENT = "ACENTER",
		EXPAND = "HORIZONTAL", MARGIN = RING .. "x0" })
	local episode_section = L.stack(iup, { season_bar, episodes.widget }, 2)

	local function more_value(pos, field)
		local item = similar[pos]
		if not item then return nil end
		if field == "TITLE" then return item.title end
		if field == "SECONDARY" then return item.year and tostring(item.year) or nil end
		if field == "BADGE" then return organize.badge(item) end
	end
	local more = CellGrid.new(iup, { shelf = true, count = 0, cell_width = SHELF_CELL, aspect = "2:3", gutter = 16,
		padding = 0, role = "flatgrid_plain", value = more_value,
		on_activate = function(pos) if similar[pos] then opts.on_open(similar[pos]) end end,
	})
	iup.SetAttribute(more.widget, "RASTERSIZE", "x" .. (math.floor(SHELF_CELL * 3 / 2) + CELL_TEXT + SCROLLBAR))
	iup.SetAttribute(more.widget, "EXPAND", "HORIZONTAL")
	local drain = opts.cache and CellGrid.posters(more, opts.cache, function(pos)
		return similar[pos] and opts.poster(similar[pos])
	end)

	local function aligned(widget)
		return iup.hbox({ widget, MARGIN = RING .. "x0", EXPAND = "HORIZONTAL" })
	end
	local more_section = L.stack(iup, { aligned(L.sectionTitle(iup, "More like this")), more.widget }, 2)

	-- A scroll box sizes to its content, so the page is told how wide it is.
	local page_width
	local holder = iup.hbox({ RASTERSIZE = "400x" })
	local body = L.stack(iup, {
		holder,
		aligned(back),
		aligned(hero.widget),
		aligned(fact_box),
		aligned(forecast_section),
		episode_section,
		more_section,
		iup.fill({ RASTERSIZE = "x16" }),
	}, 4)
	iup.SetAttribute(body, "EXPAND", "HORIZONTAL")

	api.widget = iup.flatscrollbox({
		iup.flatframe({ body, TITLE = "", THEMEROLE = "settingspanel", MARGIN = "0x0", EXPAND = "HORIZONTAL" }),
		EXPAND = "YES", SCROLLBAR = "VERTICAL", XHIDDEN = "YES", THEMEROLE = "tabscroll" })

	local function fact_values(item)
		local joined = function(list) return list and #list > 0 and table.concat(list, ", ") or "" end
		return { joined(item.genres), joined(item.people), item.codec or "", item.audio or "",
			item.rating and string.format("%.1f", item.rating) or "" }
	end

	--- Take the width the page really has.
	function api.setWidth(width)
		page_width = width - SCROLLBAR
		iup.SetAttribute(holder, "RASTERSIZE", page_width .. "x")
		iup.SetAttribute(hero.widget, "RASTERSIZE", (page_width - 2 * RING) .. "x" .. spotlight.HEIGHT)
		iup.Refresh(api.widget)
	end

	function api.refresh()
		if current then hero.show(current, true) end
	end

	--- Show a title.
	-- @tparam table item
	function api.open(item)
		current = item
		hero.show(item, true)
		for i, value in ipairs(fact_values(item)) do
			iup.SetAttribute(fact_rows[i].value, "TITLE", value)
			Kit.show(iup, fact_rows[i].row, value ~= "", back)
		end
		Kit.show(iup, forecast_section, item.kind ~= "show", back)
		if item.kind ~= "show" then load_forecast(item) end
		similar = organize.similar(item, opts.pool(), SIMILAR)
		more:setProvider(#similar, more_value)
		Kit.show(iup, more_section, #similar > 0, back)
		local is_show = item.kind == "show"
		Kit.show(iup, episode_section, is_show, back)
		if is_show then
			seasons = {}
			opts.load_seasons(item, function(loaded)
				if current ~= item then return end
				seasons = loaded or {}
				local names = {}
				for i, season in ipairs(seasons) do names[i] = season.title or ("Season " .. season.number) end
				season_box:setItems(#names > 0 and names or { "No seasons" }, 1)
				local _, resume = organize.nextEpisode(seasons)
				local start = 1
				for i, season in ipairs(seasons) do
					if season == resume then start = i end
				end
				season_box:setValue(start)
				show_season(start)
				local episode, season = organize.nextEpisode(seasons)
				if episode then
					hero.setPlayLabel(string.format("%s S%d E%d", (episode.progress or 0) > 0 and "Resume" or "Play",
						season.number or 1, episode.episode or 1))
				end
			end)
		end
		iup.Refresh(api.widget)
	end

	function api.tick()
		hero.tick()
		if drain then drain() end
	end

	return api
end

return M
