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
	local start, _, season, first, rest = lower:find("s(%d%d?%d?)[%s._-]*e(%d%d?%d?%d?)(.*)")
	if season then
		local last = tonumber(first)
		local more = rest:match("^%-?e(%d+)") or rest:match("^%-(%d%d?%d?)[%s._]")
		if more and tonumber(more) >= last then last = tonumber(more) end
		return tonumber(season), tonumber(first), last, start
	end
	start, _, season, first = lower:find("%f[%d](%d%d?)x(%d%d%d?)%f[^%d]")
	if season then return tonumber(season), tonumber(first), tonumber(first), start end
end

local function folder_season(folder)
	local lower = folder:lower()
	if lower == "specials" then return 0 end
	return tonumber(lower:match("^season[%s._-]*(%d+)$") or lower:match("^s(%d+)$"))
end

-- Release directories are containers, not series identities. Keep a year before
-- the season marker (a remake identifier), never a season's release year after it.
local function series_folder(folder)
	local text = clean(folder)
	local lower = text:lower()
	local season = folder_season(text)
	if season then return nil, nil, season end
	local marker = lower:find('%f[%a]season%s*%d') or lower:find('%f[%a]seasons%s*%d')
		or lower:find('%f[%a]s%d%d') or lower:find('s%d%d$')
	local _, _, _, episode_start = episode_numbers(text)
	marker = marker or episode_start
	if marker then text = text:sub(1, marker - 1) end
	text = text:gsub('%s*%-%s*[Tt]he%s+[Cc]omplete%s*$', '')
		:gsub('%s+[Tt]he%s+[Cc]omplete%s+[Ss]eries%s*$', '')
		:gsub('%s+[Cc]omplete%s+[Ss]eries%s*$', '')
		:gsub('%s+[Cc]omplete%s*$', ''):gsub('%s+[Ss]eason%s*$', '')
	text = clean(text):gsub('[%s,%-]+$', '')
	if text == '' then return nil end
	return title_year(text)
end

local CONTAINERS = { tv = true, ['tv shows'] = true, shows = true, television = true,
	anime = true, cartoons = true, episodes = true, extras = true }

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
	local season, first, last, marker = episode_numbers(stem(file))
	local folder = #parts > 1 and parts[#parts - 1] or nil
	local in_season = folder and (folder_season(folder) or tonumber(folder:lower():match('season[%s._-]*(%d+)')))
	if not season and in_season then
		first = tonumber(stem(file):match("^(%d+)") or stem(file):lower():match("^e(%d+)")
			or stem(file):lower():match('^episode[%s._-]*(%d+)'))
		season, last = in_season, first
	end
	if not (season and first) then return nil end
	local title, year
	local candidates = {}
	-- Collect series candidates independently of season/release/episode folders.
	for i = 1, #parts - 1 do
		local candidate, candidate_year = series_folder(parts[i])
		if candidate and not CONTAINERS[candidate:lower()] then
			candidates[#candidates + 1] = {title = candidate, year = candidate_year}
			if not title then title, year = candidate, candidate_year end
		end
	end
	local prefix = marker and clean(stem(file):sub(1, marker - 1)):gsub('[%s%-]+$', '')
	local file_title, file_year
	if prefix and prefix ~= '' then file_title, file_year = series_folder(prefix) end
	-- Prefer a folder corroborated by the episode filename. A franchise folder
	-- can contain several distinct series (for example Yellowstone/1923).
	if file_title then
		local function comparable(text) return text:lower():gsub('[%p%s]', '') end
		local matched
		for _, candidate in ipairs(candidates) do
			if comparable(candidate.title) == comparable(file_title) then matched = candidate; break end
		end
		if matched then title, year = matched.title, matched.year
		else title, year = file_title, file_year end
	end
	if not title or title == '' then return nil end
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
