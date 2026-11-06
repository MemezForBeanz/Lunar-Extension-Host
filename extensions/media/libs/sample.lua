--- A made-up library, shown until a server is connected, so every page can be read and
-- judged before the first scan. Titles, people and numbers are invented.
-- @module libs.sample

local M = {}

local FILMS = {
	{ "The Salt Line", 2021, "2160p", "HEVC", "HDR10", "E-AC3 5.1", 62.4, 128, 0.42 },
	{ "Glass Harbour", 2019, "1080p", "H.264", "SDR", "AAC 2.0", 7.8, 104, 0 },
	{ "Northern Static", 2023, "2160p", "AV1", "HDR10", "Opus 5.1", 18.2, 141, 1 },
	{ "A Quiet Meridian", 2017, "1080p", "HEVC", "SDR", "DTS 5.1", 11.6, 97, 0 },
	{ "Paper Orchard", 2022, "1080p", "H.264", "SDR", "AAC 5.1", 9.1, 112, 0.76 },
	{ "Low Tide Radio", 2018, "720p", "H.264", "SDR", "AAC 2.0", 3.2, 89, 1 },
	{ "The Long Commute", 2020, "1080p", "HEVC", "SDR", "AC3 5.1", 6.4, 118, 0 },
	{ "Ember Protocol", 2024, "2160p", "HEVC", "Dolby Vision", "TrueHD 7.1", 71.0, 153, 0.13 },
	{ "Hollow Season", 2016, "1080p", "H.264", "SDR", "DTS 5.1", 12.3, 101, 1 },
	{ "Six Bells", 2021, "1080p", "HEVC", "SDR", "AAC 5.1", 5.9, 95, 0 },
	{ "Cartographer", 2015, "2160p", "HEVC", "HDR10", "E-AC3 5.1", 44.1, 137, 0 },
	{ "Winter Index", 2023, "1080p", "AV1", "SDR", "Opus 2.0", 4.8, 108, 0.31 },
	{ "The Understudy", 2014, "1080p", "H.264", "SDR", "AC3 5.1", 8.8, 122, 1 },
	{ "Blue Hour Motel", 2022, "2160p", "HEVC", "HDR10", "DTS-HD 5.1", 53.7, 116, 0 },
	{ "Second Signal", 2019, "1080p", "HEVC", "SDR", "AAC 5.1", 6.7, 99, 0 },
	{ "Marrow", 2020, "1080p", "H.264", "SDR", "AAC 2.0", 5.2, 87, 0 },
	{ "Kite Weather", 2018, "720p", "H.264", "SDR", "AAC 2.0", 2.9, 92, 1 },
	{ "Terminal Garden", 2024, "2160p", "AV1", "HDR10", "Opus 5.1", 21.5, 131, 0 },
	{ "Vesper Street", 2017, "1080p", "HEVC", "SDR", "DTS 5.1", 10.4, 106, 0.58 },
	{ "The Ninth Lantern", 2021, "2160p", "HEVC", "HDR10", "TrueHD 7.1", 66.3, 164, 0 },
	{ "Iron Lullaby", 2016, "1080p", "H.264", "SDR", "AC3 5.1", 7.1, 113, 0 },
	{ "Small Hours", 2023, "1080p", "HEVC", "SDR", "AAC 5.1", 6.0, 94, 0 },
	{ "Atlas of Rain", 2022, "2160p", "HEVC", "HDR10", "E-AC3 5.1", 38.9, 125, 0 },
	{ "Foxglove", 2019, "1080p", "H.264", "SDR", "AAC 2.0", 4.4, 90, 1 },
}

-- More of the same, so the long-list tools have a long list to work on.
local FIRST = { "Amber", "Broken", "Cold", "Distant", "Early", "Faded", "Golden", "Hidden", "Inland", "Jade",
	"Kindred", "Last", "Mirror", "Nearer", "Open", "Pale", "Quarter", "Rusted", "Silent", "Tidal", "Upper", "Violet" }
local SECOND = { "Acre", "Bridge", "Canal", "Dunes", "Echo", "Ferry", "Garden", "Harvest", "Island", "Junction" }
local GENRES = { { "Drama" }, { "Thriller", "Mystery" }, { "Science fiction" }, { "Drama", "Romance" }, { "Comedy" },
	{ "Documentary" }, { "Thriller" }, { "Adventure" } }
local QUALITY = { { "1080p", "H.264", "SDR", "AAC 5.1", 8.2 }, { "2160p", "HEVC", "HDR10", "E-AC3 5.1", 40.5 },
	{ "1080p", "HEVC", "SDR", "AC3 5.1", 6.1 }, { "720p", "H.264", "SDR", "AAC 2.0", 3.0 } }

local function more_films()
	local rows = {}
	for i = 1, 72 do
		local quality = QUALITY[i % #QUALITY + 1]
		rows[i] = { FIRST[i % #FIRST + 1] .. " " .. SECOND[i % #SECOND + 1], 1985 + (i * 7) % 40, quality[1], quality[2],
			quality[3], quality[4], quality[5], 84 + (i * 13) % 80, i % 5 == 0 and 1 or 0 }
	end
	return rows
end

local SHOWS = {
	{ "Harbour Lights", 2021, 3, 24, "1080p" }, { "The Assessors", 2019, 5, 50, "1080p" },
	{ "Kestrel Station", 2023, 2, 16, "2160p" }, { "Fieldnotes", 2018, 4, 38, "1080p" },
	{ "Night Ferry", 2022, 1, 8, "2160p" }, { "Ledger", 2020, 2, 20, "1080p" },
	{ "Old Country", 2017, 6, 60, "720p" }, { "The Relay", 2024, 1, 10, "2160p" },
}

local TAGLINES = {
	"A surveyor returns to the coast town that erased her family's land from the map.",
	"Two rival engineers keep a failing harbour alive through one long winter.",
	"A radio operator hears a broadcast that should have stopped forty years ago.",
}

local function film(index, row)
	return {
		id = index, kind = "movie", title = row[1], year = row[2], resolution = row[3], codec = row[4],
		dynamic = row[5], audio = row[6], bitrate = row[7], minutes = row[8], progress = row[9],
		art = (index - 1) % 32 + 1, overview = TAGLINES[(index - 1) % #TAGLINES + 1],
		genres = GENRES[index % #GENRES + 1], people = { "Ana Reyes", "Tom Okafor", "Iris Lindqvist" },
		size_gb = math.floor(row[7] * row[8] * 60 / 8000 * 10 + 0.5) / 10,
		added = string.format("2026-%02d-%02d", (index % 9) + 1, (index * 7) % 27 + 1),
		subtitles = index % 2 == 0 and "English, Spanish" or "English",
		path = "Films/" .. row[1] .. " (" .. row[2] .. ").mkv",
	}
end

local function show(index, row)
	return {
		id = 100 + index, kind = "show", title = row[1], year = row[2], seasons = row[3], episodes = row[4],
		resolution = row[5], art = (24 + index - 1) % 32 + 1, progress = 0, unwatched = (index * 3) % 7 * 2,
		genres = GENRES[index % #GENRES + 1],
		overview = TAGLINES[(index - 1) % #TAGLINES + 1],
		added = string.format("2026-%02d-%02d", (index % 9) + 1, (index * 5) % 27 + 1),
	}
end

local EPISODE_NAMES = { "Slack Water", "The Long Way Round", "Small Craft Warning", "Pilot Light", "Dead Reckoning",
	"Spring Tide", "The Mooring", "Fog Signal", "Low Ceiling", "Harbour Master", "Night Watch", "Landfall" }

--- The seasons of a sample show.
-- @tparam table show
-- @treturn table
function M.seasons(show)
	local out, id = {}, show.id * 1000
	local per_season = math.max(1, math.floor((show.episodes or 8) / (show.seasons or 1)))
	for number = 1, show.seasons or 1 do
		local episodes = {}
		for i = 1, per_season do
			id = id + 1
			local finished = number < (show.seasons or 1) or i <= per_season / 2
			episodes[i] = { id = id, kind = "episode", show = show.title, season = number, episode = i,
				title = EPISODE_NAMES[(i + number * 3) % #EPISODE_NAMES + 1], minutes = 40 + (i * 7) % 18,
				progress = finished and 1 or 0 }
		end
		out[number] = { number = number, episodes = episodes }
	end
	return out
end

local ARCHIVE = { { "The Lighthouse Keeper's Week", 1934 }, { "Coal Face Serenade", 1935 }, { "Rain Over Rotterdam", 1929 },
	{ "A Railway Morning", 1936 }, { "The Grain Elevator", 1941 }, { "Harvest of the Sea", 1948 },
	{ "Night Shift at the Mill", 1927 }, { "Under the Elevated", 1932 }, { "Three Bridges", 1925 } }

local ORIGINS = {
	{ id = "o1", name = "This server", icon = "data--base", kind = "local", status = "ok", provider_name = "Folders on this computer" },
	{ id = "o2", name = "Living room NAS", icon = "network--4", kind = "jellyfin", status = "ok", provider_name = "Jellyfin or Emby server" },
	{ id = "o3", name = "Internet Archive", icon = "globe", kind = "archive", status = "ok", provider_name = "Internet Archive: Feature Films" },
	{ id = "o4", name = "Film club feed", icon = "catalog", kind = "feed", status = "failed", provider_name = "Video feed",
		error = "It answered 503" },
}

-- Where each made-up film lives. Some have a second copy, which is what the combined view is for.
local function place(films)
	for i, film in ipairs(films) do
		film.sources = { "This server" }
		local copy = { source = "This server", quality = (film.resolution or "") .. " " .. (film.codec or ""), health = "ok" }
		film.copy_list = { copy }
		if i % 6 == 0 then
			film.sources[2] = "Living room NAS"
			film.copy_list[2] = { source = "Living room NAS", quality = "1080p H.264", health = "ok" }
		end
	end
	for i, row in ipairs(ARCHIVE) do
		local index = #films + 1
		films[index] = { id = 5000 + i, kind = "movie", title = row[1], year = row[2], resolution = "720p", codec = "H.264",
			dynamic = "SDR", audio = "AAC 2.0", minutes = 60 + i * 7, progress = 0, art = (i * 5) % 32 + 1,
			overview = "A public-domain film, streamed from the archive.", genres = { "Documentary" },
			added = "2026-07-01", sources = { "Internet Archive" }, web = true,
			copy_list = { { source = "Internet Archive", quality = "720p H.264", health = "ok", web = true } } }
	end
end

local function origins(films, shows)
	local out = {}
	for i, origin in ipairs(ORIGINS) do
		local count = 0
		for _, film in ipairs(films) do
			for _, source in ipairs(film.sources or {}) do
				if source == origin.name then count = count + 1 end
			end
		end
		if i == 1 then count = count + #shows end
		if origin.status == "failed" then count = 14 end
		out[i] = { id = origin.id, name = origin.name, icon = origin.icon, kind = origin.kind, status = origin.status,
			error = origin.error, provider_name = origin.provider_name, items = count,
			rules = { rules = { { field = "source", value = origin.name } } } }
	end
	return out
end

M.PROVIDERS = {
	{ id = "jellyfin", name = "Jellyfin or Emby server", summary = "Another media server you run, on this network or elsewhere.",
		fields = { { id = "url", label = "Server address", cue = "https://media.example.org" }, { id = "key", label = "API key" } } },
	{ id = "archive-feature-films", name = "Internet Archive: Feature Films", summary = "Public-domain and openly licensed feature films.", fields = {} },
	{ id = "archive-prelinger", name = "Internet Archive: Prelinger Archives", summary = "Advertising, educational and home films from the Prelinger collection.", fields = {} },
	{ id = "m3u", name = "M3U playlist", summary = "A playlist of streams at an address you give it.",
		fields = { { id = "url", label = "Playlist address", cue = "https://example.org/list.m3u" } } },
	{ id = "feed", name = "Video feed", summary = "A podcast or RSS feed with video enclosures.",
		fields = { { id = "url", label = "Feed address", cue = "https://example.org/feed.xml" } } },
	{ id = "web-folder", name = "Web folder", summary = "A folder of video files shared over the web.",
		fields = { { id = "url", label = "Folder address", cue = "https://nas.example.org/films/" } } },
	{ id = "torrent", name = "Torrent links", off_by_default = true,
		summary = "Links you add yourself. Playing one uploads to other people and shows them your address, so add only what you have the right to share.",
		fields = { { id = "links", label = "Magnet link" } } },
}

--- The whole sample library.
function M.library()
	local films, shows = {}, {}
	for i, row in ipairs(FILMS) do films[i] = film(i, row) end
	for _, row in ipairs(more_films()) do films[#films + 1] = film(#films + 1, row) end
	place(films)
	for i, row in ipairs(SHOWS) do shows[i] = show(i, row) end
	return {
		sample = true,
		sources = {
			{ id = "home", title = "Home", icon = "home" },
			{ id = "films", title = "Films", icon = "video", count = #films },
			{ id = "shows", title = "Shows", icon = "screen", count = #shows, scanning = true },
		},
		films = films,
		shows = shows,
		origins = origins(films, shows),
		collections = {
			{ id = "c1", name = "4K HDR", icon = "filter", rules = { match = "all", rules = {
				{ field = "resolution", value = "2160p" }, { field = "dynamic", test = "is_not", value = "SDR" } } } },
			{ id = "c2", name = "Under two hours", icon = "filter", rules = { match = "all", rules = {
				{ field = "minutes", test = "at_most", value = 120 }, { field = "watch", value = "unwatched" } } } },
			{ id = "c3", name = "Nineties", icon = "filter", rules = { match = "all", rules = { { field = "decade", value = 1990 } } } },
			{ id = "c4", name = "Rainy day", icon = "bookmark", items = { 2, 4, 6, 10, 15 } },
		},
		server = {
			name = "Sample library", version = "0.1.0", analysis = "on", files = 1240, missing = 3, analysing = 18, failed = 1,
			sessions = {
				{ user = "Alice", title = "The Salt Line", device = "Living room", mode = "Direct",
					video = "Original HEVC HDR10, client decodes it", audio = "Original E-AC3 5.1, client decodes it",
					subtitles = "Off", position = "53:45", duration = "2:08:00", bitrate = "62 Mb/s" },
				{ user = "Ben", title = "Harbour Lights S2 E4", device = "Laptop", mode = "Remux",
					video = "Copied, client decodes H.264", audio = "Copied, client decodes AAC",
					subtitles = "English, rendered by the client", position = "12:40", duration = "48:00", bitrate = "9 Mb/s" },
			},
		},
	}
end

return M
