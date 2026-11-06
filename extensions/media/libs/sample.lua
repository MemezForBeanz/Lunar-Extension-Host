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
		art = index, overview = TAGLINES[(index - 1) % #TAGLINES + 1],
		size_gb = math.floor(row[7] * row[8] * 60 / 8000 * 10 + 0.5) / 10,
		added = string.format("2026-%02d-%02d", (index % 9) + 1, (index * 7) % 27 + 1),
		subtitles = index % 2 == 0 and "English, Spanish" or "English",
		path = "Films/" .. row[1] .. " (" .. row[2] .. ").mkv",
	}
end

local function show(index, row)
	return {
		id = 100 + index, kind = "show", title = row[1], year = row[2], seasons = row[3], episodes = row[4],
		resolution = row[5], art = #FILMS + index, progress = 0,
		overview = TAGLINES[(index - 1) % #TAGLINES + 1],
		added = string.format("2026-%02d-%02d", (index % 9) + 1, (index * 5) % 27 + 1),
	}
end

--- The whole sample library.
function M.library()
	local films, shows = {}, {}
	for i, row in ipairs(FILMS) do films[i] = film(i, row) end
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
		server = {
			name = "Sample library", version = "0.1.0", analysis = "on", files = 1240, missing = 3, analysing = 18, failed = 1,
			sessions = {
				{ user = "Alice", title = "The Salt Line", device = "Living room", mode = "Direct",
					video = "Original HEVC HDR10, client decodes it", audio = "Original E-AC3 5.1, client decodes it",
					subtitles = "Off", position = "53:12", duration = "2:08:00", bitrate = "62 Mb/s" },
				{ user = "Ben", title = "Harbour Lights S2 E4", device = "Laptop", mode = "Remux",
					video = "Copied, client decodes H.264", audio = "Copied, client decodes AAC",
					subtitles = "English, rendered by the client", position = "12:40", duration = "48:00", bitrate = "9 Mb/s" },
			},
		},
	}
end

return M
