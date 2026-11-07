--- Pure descriptions of catalog problems, ordered by impact, then stable identity.
local M = {}
function M.list(data)
	local out = {}
	local function add(kind, id, severity, title, wrong, next_step, action)
		out[#out + 1] = { kind = kind, id = kind .. ":" .. id, severity = severity,
			title = title, wrong = wrong, next_step = next_step, action = action }
	end
	for _, row in ipairs(data.offline or {}) do
		add("offline", row.id, 1, row.name .. ": files are offline", row.count .. (row.count == 1 and " file cannot be reached." or " files cannot be reached."),
			"Reconnect the folder or drive, then scan again.", { label = "Rescan library", path = "/v1/libraries/" .. row.id .. "/scan" })
	end
	for _, row in ipairs(data.analysis or {}) do
		add("analysis", row.id, 2, row.title .. ": analysis failed", row.error or "The file could not be analysed.",
			"Check that the file is readable, then retry analysis.", data.analysis_enabled and
			{ label = "Retry analysis", path = "/v1/files/" .. row.id .. "/analyse" } or nil)
	end
	for _, row in ipairs(data.sources or {}) do
		add("source", row.id, 3, row.name .. ": source failed", row.error or "The source did not answer.",
			"Check the source address and connection, then sync again.", { label = "Sync source", path = "/v1/sources/" .. row.id .. "/sync" })
	end
	for _, row in ipairs(data.frames or {}) do
		add("frame", row.id, 4, row.title .. ": frame failed", row.error or "A picture could not be made.",
			"Check that the file is readable and the server's media tools are ready, then retry.", data.frames_enabled and
			{ label = "Retry frame", path = "/v1/items/" .. row.id .. "/frame" } or nil)
	end
	if not data.analysis_enabled then
		add("analysis_off", "setup", 5, "File analysis is waiting for media tools", "The server's contained media tools are not ready.",
			"Open Media server to check tool preparation or download errors.")
	end
	table.sort(out, function(a, b)
		if a.severity ~= b.severity then return a.severity < b.severity end
		return a.id < b.id
	end)
	return out
end
return M
