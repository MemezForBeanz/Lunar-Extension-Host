--- Reads titles, years and episode numbers out of media file paths.
-- Pure: no file access, so every rule is covered by spec/media_naming_spec.lua.
-- @module libs.naming

local M = {}

local NOISE = {
	["480p"] = true, ["576p"] = true, ["720p"] = true, ["1080p"] = true, ["2160p"] = true, ["4k"] = true,
	bluray = true, brrip = true, bdrip = true, webrip = true, ["web-dl"] = true, webdl = true, hdtv = true,
	dvdrip = true, remux = true, x264 = true, x265 = true, h264 = true, h265 = true, hevc = true, av1 = true,
	aac = true, ac3 = true, dts = true, hdr = true, proper = true, repack = true, extended = true,
}

M.VIDEO = { mkv = true, mp4 = true, m4v = true, avi = true, mov = true, webm = true, ts = true, wmv = true }

local function split(path)
	local parts = {}
	for part in path:gmatch("[^/\\]+") do parts[#parts + 1] = part end
	return parts
end

local function stem(name)
	return (name:gsub("%.[%w]+$", ""))
end

local function extension(name)
	return (name:match("%.([%w]+)$") or ""):lower()
end

local function clean(text)
	text = text:gsub("[._]", " "):gsub("%[[^%]]*%]", " "):gsub("%s+%-%s*$", " ")
	text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	return text
end

-- A year counts only after the title has started, so "2001 A Space Odyssey" keeps its name.
local function title_year(text)
	local words, year, cut = {}, nil, nil
	for word in text:gsub("[._]", " "):gmatch("%S+") do
		local bare = word:gsub("[%(%)%[%]]", "")
		local value = tonumber(bare)
		if #words > 0 and #bare == 4 and value and value >= 1900 and value <= 2100 then
			year, cut = value, #words
		elseif NOISE[bare:lower()] then
			cut = cut or #words
			break
		end
		words[#words + 1] = word
	end
	local kept = {}
	for i = 1, cut or #words do kept[i] = words[i] end
	return clean(table.concat(kept, " ")), year
end

local function episode_numbers(name)
	local lower = name:lower()
	local season, first, rest = lower:match("s(%d%d?%d?)[%s._-]*e(%d%d?%d?%d?)(.*)")
	if season then
		local last = tonumber(first)
		local more = rest:match("^%-?e(%d+)") or rest:match("^%-(%d%d?%d?)[%s._]")
		if more and tonumber(more) >= last then last = tonumber(more) end
		return tonumber(season), tonumber(first), last
	end
	season, first = lower:match("[%s._%-%(](%d%d?)x(%d%d%d?)[%s._%-%)]")
	if not season then season, first = lower:match("^(%d%d?)x(%d%d%d?)[%s._%-]") end
	if season then return tonumber(season), tonumber(first), tonumber(first) end
end

local function folder_season(folder)
	local lower = folder:lower()
	if lower == "specials" then return 0 end
	return tonumber(lower:match("^season[%s._-]*(%d+)$") or lower:match("^s(%d+)$"))
end

--- A normalised key for sorting: lower case, leading articles ignored, numbers ordered by value.
function M.sortKey(title)
	local key = title:lower():gsub("^the%s+", ""):gsub("^a%s+", ""):gsub("^an%s+", "")
	return (key:gsub("%d+", function(n) return string.format("%08d", tonumber(n)) end))
end

local function movie(parts)
	local file = parts[#parts]
	local title, year = title_year(stem(file))
	if not year and #parts > 1 then
		local folder_title, folder_year = title_year(parts[#parts - 1])
		if folder_year then title, year = folder_title, folder_year end
	end
	return { kind = "movie", title = title, year = year }
end

local function episode(parts)
	local file = parts[#parts]
	local season, first, last = episode_numbers(stem(file))
	local folder = #parts > 1 and parts[#parts - 1] or nil
	local in_season = folder and folder_season(folder)
	if not season and in_season then
		first = tonumber(stem(file):match("^(%d+)") or stem(file):lower():match("^e(%d+)"))
		season, last = in_season, first
	end
	if not (season and first) then return nil end
	local show
	if in_season and #parts > 2 then
		show = parts[#parts - 2]
	elseif folder and not in_season then
		show = folder
	else
		show = stem(file):match("^(.-)[%s._-]*[sS]%d") or stem(file)
	end
	local title, year = title_year(show)
	return { kind = "episode", show = title, show_year = year, season = season,
		episode = first, last_episode = last }
end

--- Parse a path relative to a library root.
-- @tparam string path relative path, either separator
-- @tparam string kind the library kind: `movie` or `show`
-- @treturn table|nil the parsed fields, or nil when the file is not media or can't be read as that kind
function M.parse(path, kind)
	local parts = split(path)
	if #parts == 0 then return nil end
	if not M.VIDEO[extension(parts[#parts])] then return nil end
	if stem(parts[#parts]):lower():find("sample", 1, true) then return nil end
	if kind == "show" then return episode(parts) end
	return movie(parts)
end

return M
