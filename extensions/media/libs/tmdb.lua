--- TMDB request/mapping logic. API credentials never enter catalog rows or image URLs.
local cjson = require("cjson")
local M = {}
M.API = "https://api.themoviedb.org/3"
M.ATTRIBUTION = "This product uses the TMDB API but is not endorsed or certified by TMDB."

local function text(value, max)
	return type(value) == "string" and value ~= "" and value:sub(1, max or 4096) or nil
end
local function number(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value or nil
end
local function decode(value)
	if type(value) == "table" then return value end
	local ok, result = pcall(cjson.decode, value or "")
	return ok and type(result) == "table" and result or nil
end
local function id(value)
	local n = number(value)
	return n and n >= 1 and n == math.floor(n) and n or nil
end
function M.mediaType(kind) return kind == "show" and "tv" or (kind == "movie" and "movie" or nil) end
function M.escape(value)
	return tostring(value):gsub("[^%w%-_.~]", function(c) return string.format("%%%02X", c:byte()) end)
end
function M.image(path, size)
	if type(path) ~= "string" or not path:match("^/[%w_%-]+%.[%w]+$") then return nil end
	return "https://image.tmdb.org/t/p/" .. (size or "w500") .. path
end
function M.searchUrl(work, query)
	local kind = M.mediaType(work.kind)
	if not kind then return nil, "metadata is only available for movies and shows" end
	local url = M.API .. "/search/" .. kind .. "?include_adult=false&language=en-US&query=" .. M.escape(query or work.title)
	if work.year then url = url .. (kind == "movie" and "&year=" or "&first_air_date_year=") .. tostring(work.year) end
	return url
end
function M.detailUrl(kind, external_id)
	local media = M.mediaType(kind)
	if not media or not id(external_id) then return nil, "a positive TMDB id is required" end
	return M.API .. "/" .. media .. "/" .. external_id .. "?language=en-US&append_to_response=credits,"
		.. (media == "movie" and "release_dates" or "content_ratings")
end
local function year(row)
	local date = text(row.release_date) or text(row.first_air_date)
	return date and tonumber(date:match("^(%d%d%d%d)")) or nil
end
local function normalized(value)
	return tostring(value or ""):lower():gsub("[%s%p]", "")
end
function M.results(raw, kind)
	local data, out = decode(raw), {}
	if not data or type(data.results) ~= "table" then return nil, "TMDB search response is not readable" end
	for _, row in ipairs(data.results) do
		if #out >= 20 then break end
		if type(row) == "table" and id(row.id) and (text(row.title) or text(row.name)) then
			out[#out + 1] = { id = row.id, kind = kind, title = text(row.title) or text(row.name),
				original_title = text(row.original_title) or text(row.original_name), year = year(row),
				overview = text(row.overview, 32768), poster_url = M.image(row.poster_path),
				backdrop_url = M.image(row.backdrop_path, "w1280") }
		end
	end
	return out
end
--- Automatic matching is deliberately exact, and must have only one candidate.
function M.pick(work, results)
	local target = normalized(work.title)
	local found
	if target == "" then return nil, "title is empty" end
	for _, row in ipairs(results or {}) do
		if (normalized(row.title) == target or normalized(row.original_title) == target)
			and (not work.year or row.year == work.year) then
			if found then return nil, "multiple exact matches; choose a result manually" end
			found = row
		end
	end
	return found, found and nil or "no exact title and year match; choose a result manually"
end
local function rating_of(data, kind)
	local section = kind == "movie" and data.release_dates or data.content_ratings
	local groups = type(section) == "table" and section.results
	for _, group in ipairs(type(groups) == "table" and groups or {}) do
		if type(group) == "table" and group.iso_3166_1 == "US" then
			if kind ~= "movie" then return text(group.rating, 32) end
			for _, release in ipairs(type(group.release_dates) == "table" and group.release_dates or {}) do
				if type(release) == "table" and text(release.certification) then return text(release.certification, 32) end
			end
		end
	end
end
function M.details(raw, kind, expected_id)
	local data = decode(raw)
	if not data or not id(data.id) or (expected_id and data.id ~= expected_id) then return nil, "TMDB detail response has the wrong id" end
	local title = text(data.title) or text(data.name)
	if not title then return nil, "TMDB detail response has no title" end
	local people, cast, genres = {}, {}, {}
	for _, row in ipairs(type(data.genres) == "table" and data.genres or {}) do
		if #genres >= 32 then break end
		if type(row) == "table" and text(row.name, 120) then genres[#genres + 1] = text(row.name, 120) end
	end
	local credits = type(data.credits) == "table" and data.credits or {}
	for _, row in ipairs(type(credits.cast) == "table" and credits.cast or {}) do
		if #people >= 32 then break end
		if type(row) == "table" and text(row.name, 160) then
			people[#people + 1] = text(row.name, 160)
			cast[#cast + 1] = { name = text(row.name, 160), role = text(row.character, 240),
				profile_url = M.image(row.profile_path, "w185") }
		end
	end
	local companies = type(data.production_companies) == "table" and data.production_companies or {}
	local studio = companies[1] and text(companies[1].name, 240)
	local rating = number(data.vote_average)
	return { provider = "tmdb", external_id = tostring(data.id),
		source_url = "https://www.themoviedb.org/" .. M.mediaType(kind) .. "/" .. data.id,
		title = title, year = year(data), original_title = text(data.original_title) or text(data.original_name),
		overview = text(data.overview, 32768), tagline = text(data.tagline, 4096),
		rating = rating and rating >= 0 and rating <= 10 and rating or nil,
		content_rating = rating_of(data, kind), studio = studio,
		poster_url = M.image(data.poster_path), backdrop_url = M.image(data.backdrop_path, "w1280"),
		genres = genres, people = people, cast = cast }
end
return M
