--- Pure root-tabs height budget. All measurements are client-area pixels.
local ShellBudget = {}

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
