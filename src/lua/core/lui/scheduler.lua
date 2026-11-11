--- Batching: state updates mark roots dirty; a flush renders and commits them.
--
-- Outside a batch, the first update schedules a flush through the root's driver (an
-- `iup.timer` that fires on the next pass of the main loop), so any number of updates in
-- one callback cost one render. Inside `batch(fn)` (every event handler a primitive
-- installs runs in one, and so does `ui.flushSync`) the flush happens synchronously when
-- the outermost batch ends: a click handler that sets state returns to IUP with the
-- widgets already updated.
--
-- @module core.lui.scheduler
local M = {}

local pending = {}   -- roots in the order they were scheduled
local queued = {}    -- root -> true
local depth = 0
local flushing = false
local timers = setmetatable({}, { __mode = "k" }) -- driver -> timer

M.MAX_PASSES = 50

--- Flush every scheduled root, again while flushing schedules more (effects that set
-- state). Gives up with an error after `MAX_PASSES` rounds: an update loop.
function M.flushAll()
	if flushing then return end
	flushing = true
	local passes = 0
	local ok, err = pcall(function()
		while #pending > 0 do
			passes = passes + 1
			if passes > M.MAX_PASSES then
				local list = pending
				pending, queued = {}, {}
				for _, r in ipairs(list) do r._scheduled = false end
				error("lui: maximum update depth exceeded (an effect or a render keeps setting state)", 0)
			end
			local list = pending
			pending, queued = {}, {}
			for _, root in ipairs(list) do
				root._scheduled = false
				if not root._unmounted then root:_flushNow() end
			end
		end
	end)
	flushing = false
	if not ok then error(err, 0) end
end

local function timer_for(driver)
	local t = timers[driver]
	if t == nil then
		local ok, made = pcall(driver.timer, 1, function()
			local fok, err = pcall(M.flushAll)
			if not fok then io.stderr:write("lui: ", tostring(err), "\n") end
		end)
		t = ok and made or false
		timers[driver] = t
	end
	return t or nil
end

--- Ask for `root` to be flushed.
function M.schedule(root)
	if root._unmounted then return end
	if not queued[root] then
		queued[root] = true
		root._scheduled = true
		pending[#pending + 1] = root
	end
	if depth > 0 or flushing then return end
	local custom = root._opts and root._opts.schedule
	if custom then custom(function() M.flushAll() end); return end
	local t = timer_for(root._driver)
	if t then t.start() end
end

--- Forget a root (unmounted, or flushed directly).
function M.cancel(root)
	if not queued[root] then return end
	queued[root] = nil
	root._scheduled = false
	for i, r in ipairs(pending) do if r == root then table.remove(pending, i); break end end
end

--- Run `fn(...)` with updates batched, then flush synchronously.
-- @return what `fn` returned
function M.batch(fn, ...)
	depth = depth + 1
	local res = (function(...) return { n = select("#", ...), ... } end)(pcall(fn, ...))
	depth = depth - 1
	if depth == 0 then M.flushAll() end
	if not res[1] then error(res[2], 0) end
	return unpack(res, 2, res.n)
end

function M.inBatch() return depth > 0 end

return M
