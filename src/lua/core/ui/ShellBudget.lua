--- Height budget for the shell's root tabs.
--
-- The root tabs get whatever the window's client area leaves after the fixed
-- bands (shell header, accent strip, status bar) and the gaps between them, so
-- the status bar stays on screen when the window is maximized. Pure: all
-- measurements are client-area pixels passed in by the caller.
--
-- @module core.ui.ShellBudget
local ShellBudget = {}

--- The largest height the root tabs may take.
-- @tparam number client_h the window's client-area height
-- @tparam table heights the measured band heights (a map or an array; missing
--   or non-numeric entries count as 0)
-- @tparam number gap the gap between bands
-- @tparam number n_bands how many bands are stacked (gaps = n_bands - 1)
-- @treturn number the cap, never below 320 so a tiny window keeps usable tabs
function ShellBudget.cap(client_h, heights, gap, n_bands)
	local used = 0
	-- pairs also handles missing entries in an array of measured bands.
	for _, height in pairs(heights or {}) do
		used = used + (tonumber(height) or 0)
	end
	return math.max(320, (tonumber(client_h) or 0) - used
		- (tonumber(gap) or 0) * math.max(0, (tonumber(n_bands) or 0) - 1))
end

return ShellBudget
