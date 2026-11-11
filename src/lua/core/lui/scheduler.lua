--- The commit queue: state updates mark roots dirty; a flush renders and commits them.
--
-- **One pending flush.** The first update outside a batch arms the driver's timer (an
-- `iup.timer` with IUP's minimum of 1 ms: it fires on the next pass of the main loop,
-- it is not a microtask). Later updates join the queue without re-arming it. The timer
-- stops itself before it flushes, so it never repeats.
--
-- **Batches.** Inside `batch(fn)` (every event handler a primitive installs runs in one,
-- and so does `ui.flushSync`) nothing is armed; the queue is flushed synchronously when
-- the outermost batch *of the current main-loop level* ends. A handler that opens a
-- modal loop (`iup.Popup`) is still inside its batch, but the modal's own handlers run
-- one loop level deeper and flush their own updates when they end, so a dialog opened
-- from a click still updates while it is up.
--
-- **Reentrancy.** A flush requested while a flush runs at the same loop level (an effect
-- that sets state) does not recurse: the running flush takes it in its next round. A
-- flush started from a nested modal loop runs, but skips a root that is mid-flush
-- further out: that root goes back in the queue and the outer flush renders it when it
-- continues. Nothing is lost and no root ever renders inside its own commit.
--
-- @module core.lui.scheduler
local M = {}

local queue = {}       -- roots, in the order they were scheduled
local queued = {}      -- root -> true
local depth = {}       -- main-loop level -> open batches at that level
local flushing         -- loop level of the flush in progress, nil when none
local timers = setmetatable({}, { __mode = "k" }) -- driver -> { start, stop, armed }

M.MAX_PASSES = 50

--- The current main-loop level (iup.MainLoopLevel through the driver; 0 without one).
local level_fn = function() return 0 end
function M.setLoopLevel(fn) if fn then level_fn = fn end end
local function level()
	local ok, l = pcall(level_fn)
	return ok and tonumber(l) or 0
end

local function enqueue(root)
	if queued[root] then return end
	queued[root] = true
	root._scheduled = true
	queue[#queue + 1] = root
end

local function busy_here(l)
	return (depth[l] or 0) > 0 or (flushing ~= nil and l <= flushing)
end

--- Flush every queued root, again while flushing queues more (effects that set state).
-- Gives up with an error after `MAX_PASSES` rounds: an update loop.
function M.flushAll()
	local l = level()
	if flushing ~= nil and l <= flushing then return end -- the running flush takes it
	local outer = flushing
	flushing = l
	local passes = 0
	local ok, err = pcall(function()
		while #queue > 0 do
			passes = passes + 1
			if passes > M.MAX_PASSES then
				for _, r in ipairs(queue) do r._scheduled = false end
				queue, queued = {}, {}
				error("lui: maximum update depth exceeded (an effect or a render keeps setting state)", 0)
			end
			local list = queue
			queue, queued = {}, {}
			local deferred = false
			for _, root in ipairs(list) do
				root._scheduled = false
				if root._unmounted then
					-- dropped
				elseif root._in_flush then
					enqueue(root) -- mid-flush further out: that flush renders it when it continues
					deferred = true
				else
					root:_flushNow()
				end
			end
			if deferred then break end
		end
	end)
	flushing = outer
	if not ok then error(err, 0) end
end

local function timer_for(driver)
	local t = timers[driver]
	if t == nil then
		local entry = { armed = false }
		local ok, made = pcall(driver.timer, 1, function()
			entry.armed = false
			local fok, err = pcall(M.flushAll)
			if not fok then io.stderr:write("lui: ", tostring(err), "\n") end
		end)
		if ok and made then
			entry.start, entry.stop, entry.handle = made.start, made.stop, made.handle
			t = entry
		else
			t = false
		end
		timers[driver] = t
	end
	return t or nil
end

--- The scheduling state for a driver, for tests: `{ armed, handle }` or nil.
function M.timerState(driver)
	local t = timers[driver]
	return t and { armed = t.armed, handle = t.handle } or nil
end

--- Queue `root`; arm the timer unless a batch or a flush at this level will take it.
function M.schedule(root)
	if root._unmounted then return end
	enqueue(root)
	if busy_here(level()) then return end
	local custom = root._opts and root._opts.schedule
	if custom then custom(function() M.flushAll() end); return end
	local t = timer_for(root._driver)
	if t and not t.armed then
		t.armed = true
		t.start()
	end
end

--- Take a root out of the queue (it is being flushed directly, or unmounted).
function M.cancel(root)
	if not queued[root] then return end
	queued[root] = nil
	root._scheduled = false
	for i, r in ipairs(queue) do if r == root then table.remove(queue, i); break end end
end

--- Flush one root now, then whatever its effects queued. For a root already in the
-- middle of a flush (its own effect asked), this queues it for that flush instead.
function M.flushRoot(root)
	if root._in_flush then enqueue(root); return false end
	M.cancel(root)
	local r = root:_flushNow()
	if #queue > 0 and not busy_here(level()) then M.flushAll() end
	return r
end

--- Run `fn(...)` with updates batched, then flush synchronously when this is the
-- outermost batch of the current main-loop level.
-- @return what `fn` returned
function M.batch(fn, ...)
	local l = level()
	depth[l] = (depth[l] or 0) + 1
	local res = (function(...) return { n = select("#", ...), ... } end)(pcall(fn, ...))
	depth[l] = depth[l] - 1
	if depth[l] == 0 then
		depth[l] = nil
		M.flushAll()
	end
	if not res[1] then error(res[2], 0) end
	return unpack(res, 2, res.n)
end

function M.inBatch() return (depth[level()] or 0) > 0 end
function M.pending() return #queue end

return M
