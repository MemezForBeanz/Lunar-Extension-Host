--- Keeps a connected server's artwork on this computer.
-- Pictures are asked for by item id and written to the cache folder, so a page paints from disk
-- and only ever fetches a picture once. The grids get a path or nothing, never a wait.
-- @module libs.artcache

local M = {}
local Cache = {}
Cache.__index = Cache

M.MAX_FETCHES = 4

--- Create a cache.
-- @tparam table opts `dir`, `fetch(id, kind, done)` where `done(bytes)` gets nil on failure,
--   `exists(path)`, `write(path, bytes)`, `on_arrival()`
function M.new(opts)
	return setmetatable({ dir = opts.dir, fetch = opts.fetch, exists = opts.exists, write = opts.write,
		on_arrival = opts.on_arrival, running = 0, queued = {}, known = {}, failed = {} }, Cache)
end

--- Where a picture lives.
function Cache:path(id, kind)
	return string.format("%s/%d-%s.img", self.dir, id, kind)
end

function Cache:_pump()
	while self.running < M.MAX_FETCHES and #self.queued > 0 do
		local job = table.remove(self.queued)
		self.running = self.running + 1
		self.fetch(job.id, job.kind, function(bytes)
			self.running = self.running - 1
			if bytes and self.write(job.path, bytes) then
				self.known[job.path] = true
				self.on_arrival()
			else
				self.failed[job.path] = true
			end
			self:_pump()
		end)
	end
end

--- The local path of a picture, or nil while it is on its way.
-- @tparam number id
-- @tparam string kind `poster` or `backdrop`
-- @treturn string|nil
function Cache:get(id, kind)
	local path = self:path(id, kind)
	if self.known[path] then return path end
	if self.failed[path] then return nil end
	if self.exists(path) then
		self.known[path] = true
		return path
	end
	self.failed[path] = true   -- a queued picture isn't asked for again; arrival clears this
	self.queued[#self.queued + 1] = { id = id, kind = kind, path = path }
	self:_pump()
	return nil
end

--- The best picture an item has for a shape.
-- @tparam table item `id`, `art` (the kinds the server has)
-- @tparam string wanted `poster` or `backdrop`
-- @treturn string|nil a local path
function Cache:best(item, wanted)
	local other = wanted == "poster" and "backdrop" or "poster"
	local kinds = item.art or {}
	if kinds[wanted] then return self:get(item.id, wanted) end
	if kinds[other] then return self:get(item.id, other) end
	return nil
end

--- Which kinds a server's `art` column names.
-- @tparam string|nil text `poster,backdrop`
-- @treturn table set of kinds
function M.kinds(text)
	local out = {}
	for kind in tostring(text or ""):gmatch("[^,]+") do out[kind] = true end
	return out
end

return M
