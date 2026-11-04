--- Every diagnostic the language servers have published, keyed by file.
--
-- One store for the whole app: the code view draws a file's entries, the
-- Problems tab lists all of them, and the status bar shows the counts. A server
-- replaces its own entries for a file each time it publishes, so entries are
-- kept per (file, server) and two servers reporting on one file do not erase
-- each other.
--
-- Positions are stored as the server sent them (protocol line and character);
-- the code view converts them against the open document when it draws.
--
-- @classmod core.lsp.Diagnostics
local Uri = require("core.lsp.Uri")

local Diagnostics = {}
Diagnostics.__index = Diagnostics

--- Severity names, by protocol number. A diagnostic without one is an error.
Diagnostics.SEVERITY = { "error", "warning", "info", "hint" }

function Diagnostics.new()
	return setmetatable({
		_files = {},       -- key -> { uri, servers = { [server_id] = { entry, ... } } }
		_listeners = {},
	}, Diagnostics)
end

local function number(value, default)
	value = tonumber(value)
	if not value or value < 0 then return default end
	return math.floor(value)
end

local function normalize(uri, server_id, raw)
	if type(raw) ~= "table" then return nil end
	local range = type(raw.range) == "table" and raw.range or {}
	local from = type(range.start) == "table" and range.start or {}
	local to = type(range["end"]) == "table" and range["end"] or from
	local severity = number(raw.severity, 1)
	if severity < 1 or severity > 4 then severity = 1 end
	local code = raw.code
	if type(code) == "table" then code = code.value end
	local line = number(from.line, 0)
	local character = number(from.character, 0)
	return {
		uri = uri,
		server = server_id,
		severity = severity,
		kind = Diagnostics.SEVERITY[severity],
		message = type(raw.message) == "string" and raw.message or tostring(raw.message or ""),
		source = type(raw.source) == "string" and raw.source or nil,
		code = (type(code) == "string" or type(code) == "number") and tostring(code) or nil,
		line = line,
		character = character,
		end_line = number(to.line, line),
		end_character = number(to.character, character),
	}
end

local function by_position(a, b)
	if a.line ~= b.line then return a.line < b.line end
	if a.character ~= b.character then return a.character < b.character end
	if a.severity ~= b.severity then return a.severity < b.severity end
	return a.message < b.message
end

function Diagnostics:_fire(uri)
	for _, fn in ipairs(self._listeners) do pcall(fn, uri) end
end

--- Replace one server's diagnostics for a file.
-- @tparam string uri
-- @tparam string server_id
-- @tparam table list the `diagnostics` array of `textDocument/publishDiagnostics`
function Diagnostics:set(uri, server_id, list)
	local key = Uri.key(uri)
	local entries = {}
	for _, raw in ipairs(type(list) == "table" and list or {}) do
		local entry = normalize(uri, server_id, raw)
		if entry then entries[#entries + 1] = entry end
	end
	table.sort(entries, by_position)

	local file = self._files[key]
	if #entries == 0 then
		if not (file and file.servers[server_id]) then return end
		file.servers[server_id] = nil
		if next(file.servers) == nil then self._files[key] = nil end
	else
		if not file then
			file = { uri = uri, servers = {} }
			self._files[key] = file
		end
		file.servers[server_id] = entries
	end
	self:_fire(uri)
end

--- Drop everything one server reported (it stopped, or its extension unloaded).
function Diagnostics:clearServer(server_id)
	local changed = {}
	for key, file in pairs(self._files) do
		if file.servers[server_id] then
			file.servers[server_id] = nil
			changed[#changed + 1] = file.uri
			if next(file.servers) == nil then self._files[key] = nil end
		end
	end
	for _, uri in ipairs(changed) do self:_fire(uri) end
end

--- A file's diagnostics, in document order.
-- @treturn {table,...}
function Diagnostics:forUri(uri)
	local file = self._files[Uri.key(uri)]
	local out = {}
	if not file then return out end
	for _, entries in pairs(file.servers) do
		for _, entry in ipairs(entries) do out[#out + 1] = entry end
	end
	table.sort(out, by_position)
	return out
end

--- How many there are of each severity.
-- @treturn table `{ error, warning, info, hint, total, files }`
function Diagnostics:counts()
	local counts = { error = 0, warning = 0, info = 0, hint = 0, total = 0, files = 0 }
	for _, file in pairs(self._files) do
		counts.files = counts.files + 1
		for _, entries in pairs(file.servers) do
			for _, entry in ipairs(entries) do
				counts[entry.kind] = counts[entry.kind] + 1
				counts.total = counts.total + 1
			end
		end
	end
	return counts
end

--- Everything, for the Problems list: errors first, then by file and position.
-- @treturn {table,...}
function Diagnostics:list()
	local out = {}
	for _, file in pairs(self._files) do
		for _, entries in pairs(file.servers) do
			for _, entry in ipairs(entries) do out[#out + 1] = entry end
		end
	end
	table.sort(out, function(a, b)
		if a.severity ~= b.severity then return a.severity < b.severity end
		if a.uri ~= b.uri then return a.uri < b.uri end
		return by_position(a, b)
	end)
	return out
end

--- Be told when a file's diagnostics change. `fn(uri)`.
-- @treturn function call it to stop listening
function Diagnostics:onChange(fn)
	self._listeners[#self._listeners + 1] = fn
	return function()
		for i, listener in ipairs(self._listeners) do
			if listener == fn then
				table.remove(self._listeners, i)
				return
			end
		end
	end
end

--- One line describing the counts, for a status element or a tooltip.
-- @treturn string e.g. `"2 errors, 1 warning"`, or `"No problems"`
function Diagnostics.summary(counts)
	local parts = {}
	local function add(n, singular)
		if n > 0 then parts[#parts + 1] = n .. " " .. singular .. (n == 1 and "" or "s") end
	end
	add(counts.error, "error")
	add(counts.warning, "warning")
	add(counts.info + counts.hint, "note")
	if #parts == 0 then return "No problems" end
	return table.concat(parts, ", ")
end

return Diagnostics
