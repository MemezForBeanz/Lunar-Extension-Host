--- Walks a library root a slice at a time, so a large library never stalls a stream.
-- Each `step` runs for at most `budget_ms` and commits once. Paths in the catalog
-- are relative to the root, which keeps a moved disk from invalidating a library.
-- @module libs.scanner

local filescan = require("core.lib.filescan")
local lfs = require("lfs")
local naming = require("libs.naming")
local art = require("libs.art")
local nfo = require("libs.nfo")

local Scan = {}
Scan.__index = Scan

local M = {}

--- Begin a scan of one library.
-- @tparam table catalog a `libs.catalog`
-- @tparam table library a library row
-- @tparam[opt] table opts `clock_ms`, `list`, `attr`, `now`
function M.new(catalog, library, opts)
	opts = opts or {}
	return setmetatable({
		catalog = catalog, library = library, scan = (library.scan_count or 0) + 1,
		pending = { "" }, files = {}, folders = {}, read_nfo = {}, clock_ms = opts.clock_ms or filescan.now_ms,
		list = opts.list or filescan.listDir, attr = opts.attr or lfs.attributes,
		now = opts.now or os.time, seen = 0, added = 0, done = false,
	}, Scan)
end

local function join(a, b)
	if a == "" then return b end
	return a .. "/" .. b
end

function Scan:_absolute(relative)
	if relative == "" then return self.library.root end
	return self.library.root .. "/" .. relative
end

-- Names only: lists one directory and remembers what it holds.
function Scan:_walk_one()
	local relative = table.remove(self.pending)
	for _, entry in ipairs(self.list(self:_absolute(relative))) do
		local name = entry.name
		if entry.dir then
			if name:sub(1, 1) ~= "." then self.pending[#self.pending + 1] = join(relative, name) end
		elseif art.isImage(name) or name:lower():match("%.nfo$") then
			self.folders[relative] = self.folders[relative] or {}
			self.folders[relative][name:lower()] = name
		elseif name:sub(1, 1) ~= "." then
			self.files[#self.files + 1] = join(relative, name)
		end
	end
end

function Scan:_note(relative)
	local parsed = naming.parse(relative, self.library.kind)
	if not parsed then return end
	local attr = self.attr(self:_absolute(relative))
	if not attr then return end
	self.seen = self.seen + 1
	local file_id = self.catalog:noteFile(self.library.id, relative, attr.size, attr.modification, self.scan, parsed)
	if file_id then
		self.added = self.added + 1
		self.catalog:queueProbe(file_id)
	end
	local found = art.find(relative, self.folders, parsed.kind == "movie" and "movie" or "show")
	if next(found) then
		local work = self.catalog:topWorkOfFile(self.library.id, relative)
		for kind, path in pairs(found) do self.catalog:saveArt(work, kind, "library", path) end
	end
	self:_read_nfo(relative, parsed)
end

-- A show's .nfo is one file for many episodes, so each file is read only once a scan.
function Scan:_read_nfo(relative, parsed)
	local kind = parsed.kind == "movie" and "movie" or "show"
	local path = nfo.find(relative, self.folders, kind)
	if not path or self.read_nfo[path] then return end
	self.read_nfo[path] = true
	local file = io.open(self:_absolute(path), "rb")
	if not file then return end
	local text = file:read(nfo.MAX_BYTES + 1)
	file:close()
	local facts = nfo.parse(text)
	if facts then
		self.catalog:saveFacts(self.catalog:topWorkOfFile(self.library.id, relative), facts, true)
	end
end

--- Run one slice.
-- @tparam number budget_ms time this slice may take
-- @treturn boolean true when the scan has finished
function Scan:step(budget_ms)
	if self.done then return true end
	local deadline = self.clock_ms() + budget_ms
	self.catalog:batch(function()
		repeat
			if #self.files > 0 then
				self:_note(table.remove(self.files))
			elseif #self.pending > 0 then
				self:_walk_one()
			end
		until self.clock_ms() >= deadline or (#self.files == 0 and #self.pending == 0)
		return true
	end)
	if #self.files == 0 and #self.pending == 0 then
		self.catalog:finishScan(self.library.id, self.scan, self.now())
		self.done = true
	end
	return self.done
end

return M
