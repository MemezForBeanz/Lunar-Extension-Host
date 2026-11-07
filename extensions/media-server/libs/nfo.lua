--- Reads the .nfo files that media tools leave beside films: a film's plot, genres, cast and
-- rating, with no outside service. Only the few plain elements below are read, so a damaged or
-- hostile file can't do more than fail to say anything.
-- @module libs.nfo

local M = {}

M.MAX_BYTES = 256 * 1024
M.MAX_LIST = 32

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function text_of(raw)
	if not raw then return nil end
	local text = raw:gsub("^%s*<!%[CDATA%[(.-)%]%]>%s*$", "%1")
	text = text:gsub("&(%a+);", ENTITIES)
	text = text:gsub("&#(%d+);", function(code)
		local n = tonumber(code)
		return n and n < 128 and string.char(n) or ""
	end)
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then return nil end
	return text
end

local function one(xml, tag)
	return text_of(xml:match("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">"))
end

local function many(xml, tag, limit)
	local out = {}
	for raw in xml:gmatch("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">") do
		local text = text_of(raw)
		if text then out[#out + 1] = text end
		if #out >= limit then break end
	end
	return out
end

--- Read one .nfo file's text.
-- @tparam string xml
-- @treturn table|nil `title`, `overview`, `year`, `rating`, `content_rating`, `studio`,
--   `minutes`, `genres`, `people`; nil when the text isn't an .nfo at all
function M.parse(xml)
	if type(xml) ~= "string" or #xml > M.MAX_BYTES then return nil end
	if not xml:find("<movie", 1, true) and not xml:find("<tvshow", 1, true) and not xml:find("<episodedetails", 1, true) then
		return nil
	end
	local people = {}
	for block in xml:gmatch("<actor[^>]*>(.-)</actor>") do
		local name = one(block, "name")
		if name then people[#people + 1] = name end
		if #people >= M.MAX_LIST then break end
	end
	local rating = tonumber(one(xml, "rating") or one(xml, "value"))
	local year = tonumber(one(xml, "year") or (one(xml, "premiered") or ""):match("^(%d%d%d%d)"))
	local minutes = tonumber(one(xml, "runtime"))
	return {
		title = one(xml, "title"), overview = one(xml, "plot") or one(xml, "outline"),
		year = year and math.floor(year) or nil, rating = rating and rating <= 10 and rating or nil,
		content_rating = one(xml, "mpaa"), studio = one(xml, "studio"),
		minutes = minutes and math.floor(minutes) or nil,
		genres = many(xml, "genre", M.MAX_LIST), people = people,
	}
end

--- Which file holds a video's .nfo.
-- @tparam string relative the video's path
-- @tparam table folders `folders[folder][lowercase name] = name`
-- @tparam string kind `movie` or `show`
-- @treturn string|nil a path inside the library
function M.find(relative, folders, kind)
	local folder = relative:match("^(.*)/[^/]+$") or ""
	local function join(place, name)
		if place == "" then return name end
		return place .. "/" .. name
	end
	if kind == "show" then
		local top = folder:match("^(.*)/[^/]+$") or folder
		local names = folders[top]
		return names and names["tvshow.nfo"] and join(top, names["tvshow.nfo"]) or nil
	end
	local names = folders[folder]
	if not names then return nil end
	local stem = (relative:match("([^/]+)%.[^.]*$") or ""):lower()
	local hit = names[stem .. ".nfo"] or names["movie.nfo"]
	return hit and join(folder, hit) or nil
end

--- What embedded tags can add, from ffprobe's format tags.
-- @tparam table tags names in any case
-- @treturn table `overview`, `genres`
function M.fromTags(tags)
	local lower = {}
	for key, value in pairs(tags or {}) do
		if type(value) == "string" then lower[key:lower()] = value end
	end
	local genres = {}
	for genre in (lower.genre or ""):gmatch("[^,;/]+") do
		local clean = genre:gsub("^%s+", ""):gsub("%s+$", "")
		if clean ~= "" then genres[#genres + 1] = clean end
	end
	return { overview = text_of(lower.synopsis or lower.description or lower.summary or lower.comment), genres = genres }
end

return M
