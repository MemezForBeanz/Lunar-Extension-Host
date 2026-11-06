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

--- The line under a title in the dock.
-- @tparam table state `paused`, `position`, `length`
-- @treturn string
function M.status(state)
	local left = (state.length or 0) - (state.position or 0)
	local parts = {}
	if state.paused then parts[#parts + 1] = "Paused" end
	if left > 0 then parts[#parts + 1] = M.remaining(left) end
	return table.concat(parts, " · ")
end

return M
