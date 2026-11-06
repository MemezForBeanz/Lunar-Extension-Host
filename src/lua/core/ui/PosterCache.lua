--- Posters decoded off the UI thread, scaled once to cell pixels, kept in a bounded cache.
--
-- This is the `media_native` module with a friendly constructor. The module exists only in the
-- desktop host, so `new` returns nil and a reason anywhere else.
--
-- ```lua
-- local cache = PosterCache.new({ max_mb = 256 })
-- local grid = CellGrid.new(iup, { count = #films, value = provider })
-- local drain = CellGrid.posters(grid, cache, function(pos) return films[pos].poster_path end)
-- local timer = ctx:addTimer({ time = 30, run = true, action = drain }, M)
-- -- on unload: stop the timer, then cache:close()
-- ```
--
-- `CellGrid.posters` is all a grid needs. The cache itself, for anything else that shows art:
--
--   cache:request(key, path, w, h)       Queue a decode of a file. false if the key is known.
--   cache:requestBytes(key, data, w, h)  The same for an image already in memory.
--   cache:get(key)                       lightuserdata, stride, w, h, or nothing. Marks it used.
--   cache:drain([limit])                 List of keys that finished, ready or failed. Call it
--                                        from a host timer; it is what lets finished work in.
--   cache:status(key)                    "queued", "ready" or "failed", plus the failure text.
--   cache:forget(key)                    Drop one key, so a failed image can be tried again.
--   cache:clear()                        Drop everything, including queued work.
--   cache:stats()                        `used_bytes`, `max_bytes`, `entries`, `evicted`, `queued`.
--   cache:close()                        Stop the workers and free everything. Safe to repeat.
--
-- Keys are yours, and name one image at one size. An image is scaled to cover w x h and
-- cropped to it, as 32-bit BGRA, top row first. The format list is the platform decoder's:
-- WIC on Windows, GdkPixbuf on Linux, so JPEG and PNG everywhere.
--
-- Decoding runs on worker threads that never enter Lua. Newest requests run first and the
-- queue is bounded (`max_queued`, default 256): what scrolled past is dropped unstarted, and
-- `status` then returns nothing, so a cell that comes back asks again.
--
-- A pointer from `get` stays valid until the next `drain`, `forget`, `clear` or `close`. Draw
-- with it straight away; do not keep it.
--
-- @module core.ui.PosterCache
local M = {}

--- Create a cache.
-- @tparam[opt] table opts `max_mb` (default 256), `threads` (default 2, at most 8), `max_queued`
-- @return the cache, or nil
-- @treturn[opt] string why not
function M.new(opts)
	local ok, native = pcall(require, "media_native")
	if not ok then return nil, "this host has no poster decoder" end
	return native.cache(opts or {})
end

return M
