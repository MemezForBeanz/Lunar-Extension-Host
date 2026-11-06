--- Fits Tonight: say how long you have, and get a plan that ends on time.
-- It finishes what you started first, then fills the time from what you haven't seen, leaving a
-- little room rather than running over. Pure, and a seed gives another idea on demand.
-- @module libs.tonight

local M = {}

M.MAX_PICKS = 3         -- an evening, not a marathon
M.BREAK_MINUTES = 5     -- between titles, for the kettle
M.POOL = 40             -- how many unwatched titles it weighs
M.SLACK = 25            -- minutes short of the limit that still counts as a full evening
M.TIMES = { { 45, "45 min" }, { 60, "1 hour" }, { 90, "1 h 30" }, { 120, "2 hours" }, { 180, "3 hours" }, { 240, "4 hours" } }

local function left_of(item)
	return math.ceil((item.minutes or 0) * (1 - (item.progress or 0)))
end

-- A steady shuffle, so the same seed always gives the same plan.
local function shuffled(list, seed)
	local out = {}
	for i, item in ipairs(list) do out[i] = item end
	local state = (seed * 2654435761 + 1) % 4294967296
	for i = #out, 2, -1 do
		state = (state * 1103515245 + 12345) % 2147483648
		local j = state % i + 1
		out[i], out[j] = out[j], out[i]
	end
	return out
end

local function used(picks)
	local total = 0
	for i, pick in ipairs(picks) do
		total = total + pick.minutes + (i > 1 and M.BREAK_MINUTES or 0)
	end
	return total
end

-- A set from `pool` that fits. Any plan within SLACK minutes of the limit is good enough, and the
-- first one found wins, so the shuffle decides which: that is what makes a new seed a new idea.
local function best_fit(chosen, pool, limit)
	local best, best_used = nil, -1
	local enough = limit - M.SLACK
	local function consider(picks)
		local total = used(picks)
		if total <= limit and total > best_used and best_used < enough then
			best, best_used = {}, total
			for i, pick in ipairs(picks) do best[i] = pick end
		end
	end
	local function walk(start, picks)
		consider(picks)
		if best_used >= enough or #picks >= M.MAX_PICKS then return end
		for i = start, #pool do
			if used(picks) + pool[i].minutes <= limit then
				picks[#picks + 1] = pool[i]
				walk(i + 1, picks)
				picks[#picks] = nil
			end
		end
	end
	walk(1, chosen)
	return best or chosen
end

--- Plan an evening.
-- @tparam table items films, each with `minutes` and `progress`
-- @tparam number limit minutes available
-- @tparam number now seconds since the epoch
-- @tparam[opt] number seed another seed gives another idea
-- @treturn table picks in order, each `{ item, minutes, starts, ends, why }`
function M.plan(items, limit, now, seed)
	local chosen, pool = {}, {}
	for _, item in ipairs(items) do
		local left = left_of(item)
		if left > 0 and item.kind ~= "show" then
			local progress = item.progress or 0
			if progress > 0 and progress < 1 then
				if #chosen == 0 and left <= limit then
					chosen[1] = { item = item, minutes = left, why = "Finish what you started" }
				end
			elseif progress == 0 then
				pool[#pool + 1] = { item = item, minutes = left, why = "Not seen yet" }
			end
		end
	end
	pool = shuffled(pool, seed or 1)
	for i = #pool, M.POOL + 1, -1 do pool[i] = nil end
	local picks = best_fit(chosen, pool, limit)
	local clock = now
	for _, pick in ipairs(picks) do
		pick.starts = clock
		pick.ends = clock + pick.minutes * 60
		clock = pick.ends + M.BREAK_MINUTES * 60
	end
	return picks
end

--- A time on the clock.
-- @tparam number seconds since the epoch
-- @treturn string such as `9:05 PM`
function M.clock(seconds)
	local text = os.date("%I:%M %p", seconds)
	return (text:gsub("^0", ""))
end

--- When a plan ends, in words.
-- @tparam table picks
-- @treturn string
function M.summary(picks)
	if #picks == 0 then return "Nothing fits that yet" end
	return "Ends by " .. M.clock(picks[#picks].ends)
end

return M
