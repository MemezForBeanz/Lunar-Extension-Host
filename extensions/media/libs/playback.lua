--- Words and numbers for playback, kept pure so specs can cover them.
-- @module libs.playback

local M = {}

--- A position as a clock.
-- @tparam number seconds
-- @treturn string `53:12` or `1:53:12`
function M.clock(seconds)
	seconds = math.floor(seconds or 0)
	local h, m, s = math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60
	if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
	return string.format("%d:%02d", m, s)
end

--- Time left, in the words a person would use.
-- @tparam number seconds
-- @treturn string
function M.remaining(seconds)
	local minutes = math.ceil(seconds / 60)
	if minutes < 60 then return minutes .. " min left" end
	return string.format("%d h %d min left", math.floor(minutes / 60), minutes % 60)
end

--- Time left in a playback state, or nothing when its length is unknown.
-- @tparam table state `position`, `length`
-- @treturn string
function M.left(state)
	local left = (state.length or 0) - (state.position or 0)
	return left > 0 and M.remaining(left) or ""
end

--- A running time, in the words a person would use.
-- @tparam number|nil minutes
-- @treturn string
function M.runtime(minutes)
	if not minutes or minutes < 1 then return "" end
	if minutes < 60 then return minutes .. " min" end
	return string.format("%d h %d min", math.floor(minutes / 60), minutes % 60)
end

--- Rows for Up next. The first is what plays when this ends, and says so.
-- @tparam table items each with `title`, `minutes`
-- @tparam[opt] function art_of `art_of(item)` gives a picture's path, or nil
-- @treturn table rows with `title`, `secondary`, `column1`, `art`
function M.queueRows(items, art_of)
	local rows = {}
	for i, item in ipairs(items or {}) do
		rows[i] = { title = item.title, secondary = M.runtime(item.minutes), column1 = i == 1 and "Next" or "",
			art = art_of and art_of(item) or nil }
	end
	return rows
end

--- The line under a title in the dock.
-- @tparam table state `paused`, `detail`
-- @treturn string
function M.status(state)
	local word = state.paused and "Paused" or "Playing"
	if state.detail and state.detail ~= "" then return word .. " · " .. state.detail end
	return word
end

return M
