--- Finding things in a library: filters, smart collection rules and the jump bar.
-- One rule form does all of it, so a filter on screen can be saved as a collection unchanged.
-- Pure, so specs cover it without a window.
-- @module libs.organize

local M = {}

-- The jump bar only earns its place on a long list with letters to choose between.
M.JUMP_MIN_ITEMS = 75
M.JUMP_MIN_LETTERS = 5

local OTHER = "#"
local TICK = "\226\156\147"

local function has_tag(list, value)
	for _, entry in ipairs(list or {}) do
		if entry == value then return true end
	end
	return false
end

--- A film's watched state.
-- @tparam table item
-- @treturn string `unwatched`, `progress` or `watched`
function M.watchState(item)
	local progress = item.progress or 0
	if progress >= 1 then return "watched" end
	if progress > 0 then return "progress" end
	return "unwatched"
end

--- The decade an item came out in.
-- @tparam table item
-- @treturn number|nil
function M.decade(item)
	local year = item.year
	if not year or year <= 0 then return nil end
	return math.floor(year / 10) * 10
end

local FIELDS = {
	watch = M.watchState,
	decade = M.decade,
	resolution = function(item) return item.resolution end,
	codec = function(item) return item.codec end,
	dynamic = function(item) return item.dynamic end,
	minutes = function(item) return item.minutes end,
	year = function(item) return item.year end,
	genre = function(item) return item.genres end,
	title = function(item) return item.title end,
}

local TESTS = {
	is = function(have, want) return have == want end,
	is_not = function(have, want) return have ~= want end,
	at_least = function(have, want) return type(have) == "number" and have >= want end,
	at_most = function(have, want) return type(have) == "number" and have <= want end,
	contains = function(have, want)
		return type(have) == "string" and have:lower():find(tostring(want):lower(), 1, true) ~= nil
	end,
}

--- Does an item pass one rule?
-- @tparam table item
-- @tparam table rule `{ field, test, value }`
-- @treturn boolean
function M.passes(item, rule)
	local read, test = FIELDS[rule.field], TESTS[rule.test or "is"]
	if not read or not test then return false end
	if rule.field == "genre" then
		local tagged = has_tag(read(item), rule.value)
		if rule.test == "is_not" then return not tagged end
		return tagged
	end
	return test(read(item), rule.value)
end

--- The items a rule set keeps, in their order.
-- @tparam table list
-- @tparam table set `{ match = "all"|"any", rules = {...} }`; an empty set keeps everything
-- @treturn table a new list
function M.apply(list, set)
	local rules = set and set.rules or {}
	if #rules == 0 then
		local copy = {}
		for i, item in ipairs(list) do copy[i] = item end
		return copy
	end
	local any = set.match == "any"
	local out = {}
	for _, item in ipairs(list) do
		local keep = not any
		for _, rule in ipairs(rules) do
			local passed = M.passes(item, rule)
			if any and passed then keep = true break end
			if not any and not passed then keep = false break end
		end
		if keep then out[#out + 1] = item end
	end
	return out
end

--- Turn the filter bar's choices into a rule set.
-- @tparam table state `watch`, `genre`, `decade`, `resolution`; nil means any
-- @treturn table a rule set
function M.rulesFor(state)
	local rules = {}
	for _, field in ipairs({ "watch", "genre", "decade", "resolution" }) do
		if state[field] ~= nil then rules[#rules + 1] = { field = field, test = "is", value = state[field] } end
	end
	if state.title and state.title ~= "" then rules[#rules + 1] = { field = "title", test = "contains", value = state.title } end
	return { match = "all", rules = rules }
end

local function sorted_keys(seen, descending)
	local out = {}
	for key in pairs(seen) do out[#out + 1] = key end
	table.sort(out, function(a, b)
		if descending then return a > b end
		return a < b
	end)
	return out
end

--- What a list can be filtered by, so a menu never offers a choice that finds nothing.
-- @tparam table list
-- @treturn table `genres`, `decades`, `resolutions`
function M.facets(list)
	local genres, decades, resolutions = {}, {}, {}
	for _, item in ipairs(list) do
		for _, genre in ipairs(item.genres or {}) do genres[genre] = true end
		local decade = M.decade(item)
		if decade then decades[decade] = true end
		if item.resolution then resolutions[item.resolution] = true end
	end
	return { genres = sorted_keys(genres), decades = sorted_keys(decades, true), resolutions = sorted_keys(resolutions, true) }
end

--- The letter a title files under, ignoring a leading article.
-- @tparam string title
-- @treturn string a capital letter, or `#`
function M.letter(title)
	local text = (title or ""):lower():gsub("^%s+", "")
	text = text:gsub("^the%s+", ""):gsub("^an%s+", ""):gsub("^a%s+", "")
	local first = text:match("%a")
	if not first or text:sub(1, 1):match("%A") then return OTHER end
	return first:upper()
end

--- The letters a sorted list holds, each with where it starts.
-- @tparam table list sorted by title
-- @treturn table `{ { letter, index }, ... }`
function M.letters(list)
	local out, seen = {}, {}
	for index, item in ipairs(list) do
		local letter = M.letter(item.title)
		if not seen[letter] then
			seen[letter] = true
			out[#out + 1] = { letter = letter, index = index }
		end
	end
	return out
end

--- Should the jump bar show?
-- @tparam table letters from `M.letters`
-- @tparam number count items in the list
-- @treturn boolean
function M.jumpShows(letters, count)
	return #letters >= M.JUMP_MIN_LETTERS and count >= M.JUMP_MIN_ITEMS
end

--- Keep as many letters as fit, evenly spaced, always with the first and last.
-- @tparam table letters
-- @tparam number room how many fit
-- @treturn table
function M.fit(letters, room)
	if #letters <= room or room < 2 then return letters end
	local out = {}
	for slot = 0, room - 1 do
		out[slot + 1] = letters[1 + math.floor(slot * (#letters - 1) / (room - 1) + 0.5)]
	end
	return out
end

--- Sort a list by title the way people file them.
-- @tparam table a
-- @tparam table b
-- @treturn boolean
function M.byTitle(a, b)
	local x = a.title:lower():gsub("^the%s+", ""):gsub("^an%s+", ""):gsub("^a%s+", "")
	local y = b.title:lower():gsub("^the%s+", ""):gsub("^an%s+", ""):gsub("^a%s+", "")
	return x < y
end

--- The episode to start from: the first one not finished.
-- @tparam table seasons
-- @treturn table|nil an episode
-- @treturn table|nil the season it's in
function M.nextEpisode(seasons)
	for _, season in ipairs(seasons) do
		for _, episode in ipairs(season.episodes) do
			if M.watchState(episode) ~= "watched" then return episode, season end
		end
	end
	local first = seasons[1]
	return first and first.episodes[1], first
end

--- What plays after an episode, in order.
-- @tparam table seasons
-- @tparam table episode
-- @treturn table list of episodes
function M.after(seasons, episode)
	local out, found = {}, false
	for _, season in ipairs(seasons) do
		for _, candidate in ipairs(season.episodes) do
			if found then out[#out + 1] = candidate end
			if candidate == episode then found = true end
		end
	end
	return out
end

--- What a poster's corner should say.
-- @tparam table item
-- @treturn string|nil
function M.badge(item)
	if item.kind == "show" then
		return (item.unwatched or 0) > 0 and tostring(item.unwatched) or nil
	end
	local format
	if item.dynamic and item.dynamic ~= "SDR" then format = item.dynamic == "Dolby Vision" and "DV" or "HDR"
	elseif item.resolution == "2160p" then format = "4K" end
	if M.watchState(item) == "watched" then
		return format and (TICK .. " " .. format) or TICK
	end
	return format
end

--- Titles most like this one, from what the library knows: shared genres, then the same decade.
-- @tparam table item
-- @tparam table pool
-- @tparam number limit
-- @treturn table
function M.similar(item, pool, limit)
	local scored = {}
	local mine = {}
	for _, genre in ipairs(item.genres or {}) do mine[genre] = true end
	for position, other in ipairs(pool) do
		if other ~= item then
			local score = 0
			for _, genre in ipairs(other.genres or {}) do
				if mine[genre] then score = score + 3 end
			end
			if M.decade(other) == M.decade(item) then score = score + 1 end
			if score > 0 then scored[#scored + 1] = { item = other, score = score, position = position } end
		end
	end
	table.sort(scored, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return a.position < b.position
	end)
	local out = {}
	for i = 1, math.min(limit, #scored) do out[i] = scored[i].item end
	return out
end

local WORDS = {
	watch = { unwatched = "Unwatched", progress = "In progress", watched = "Watched" },
}

--- A rule set in a few words, for under a collection's title.
-- @tparam table|nil set
-- @treturn string
function M.describe(set)
	local parts = {}
	for _, rule in ipairs(set and set.rules or {}) do
		local value = rule.value
		local words = WORDS[rule.field] and WORDS[rule.field][value]
		if rule.field == "decade" then words = value .. "s"
		elseif rule.field == "minutes" then words = (rule.test == "at_most" and "Up to " or "At least ") .. value .. " min"
		elseif rule.field == "year" then words = (rule.test == "at_most" and "Up to " or "From ") .. value end
		words = words or tostring(value)
		if rule.test == "is_not" then words = "Not " .. words end
		parts[#parts + 1] = words
	end
	return table.concat(parts, set and set.match == "any" and " or " or " · ")
end

return M
