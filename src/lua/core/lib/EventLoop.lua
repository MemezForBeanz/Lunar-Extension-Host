--- The headless host's event loop: timers, process jobs and the copas scheduler
-- on one thread, without IUP.
--
-- The GUI host drives the same pieces from IUP timers (`ctx:addTimer`, the async
-- pump, `ProcessJob`'s shared timer). Headless, `core.headless` creates one loop
-- and passes it to `HostAPI`, which then hands out loop timers and lets the loop
-- pump jobs and copas. Each turn:
--
--   1. fire the timers that are due (a callback that raises disarms its timer and
--      is reported once, the way the GUI isolates a failing timer, unless the
--      timer was made with `keep_on_error`);
--   2. pump every running `ProcessJob`;
--   3. step copas, waiting for socket activity until the next timer is due (at
--      most `max_wait`), or just sleep when copas has nothing to do.
--
-- `run()` returns after `stop()`, or when `until_idle` is set and no timer, job
-- or copas task is left (tests and one-shot commands use that).
--
-- @module core.lib.EventLoop

local M = {}
M.__index = M

local socket_ok, socket = pcall(require, "socket")

local function now()
	if socket_ok and socket.gettime then return socket.gettime() end
	return os.time()
end

local function sleep(sec)
	if sec <= 0 then return end
	if socket_ok and socket.sleep then socket.sleep(sec) end
end

local Timer = {}
Timer.__index = Timer

--- Arm the timer (its first tick is one interval from now).
function Timer:start()
	if self._loop._closed then return self end
	self.running = true
	self.due = self._loop._now() + self.interval
	return self
end

--- Disarm the timer. It can be started again.
function Timer:stop()
	self.running = false
	return self
end

--- Stop the timer for good and drop it from the loop.
function Timer:close()
	self.running = false
	self._loop:_drop(self)
end

--- Create a loop.
-- @tparam[opt] table opts `{ max_wait = seconds (0.25), job_wait = seconds while
--   jobs run (0.05), on_error = function(msg), now = clock, sleep = fn, async = module,
--   jobs = ProcessJob-like module, should_stop = function }`. `should_stop` is polled
--   every turn (the C launcher's SIGTERM/SIGINT flag); `now`, `sleep`, `async` and
--   `jobs` are for tests.
-- @treturn EventLoop
function M.new(opts)
	opts = opts or {}
	local self = setmetatable({}, M)
	self._timers = {}
	self._stopped = false
	self._closed = false
	self.max_wait = opts.max_wait or 0.25
	self.job_wait = opts.job_wait or 0.05
	self._on_error = opts.on_error
	self._now = opts.now or now
	self._sleep = opts.sleep or sleep
	self._async = opts.async
	self._jobs = opts.jobs
	self._should_stop = opts.should_stop
	return self
end

function M:_report(msg)
	if self._on_error then pcall(self._on_error, msg) end
end

function M:_async_mod()
	if self._async == nil then
		local ok, mod = pcall(require, "core.lib.async")
		self._async = ok and mod or false
	end
	return self._async or nil
end

function M:_jobs_mod()
	if self._jobs == nil then
		local ok, mod = pcall(require, "core.lib.ProcessJob")
		self._jobs = ok and mod or false
	end
	return self._jobs or nil
end

--- A repeating timer.
-- @tparam number interval_ms milliseconds between ticks
-- @tparam function fn callback
-- @tparam[opt=true] boolean run start it now
-- @tparam[opt] table opts `{ keep_on_error = boolean }`: report a raising callback
--   and keep the timer armed instead of disarming it
-- @treturn table timer with `start()`, `stop()`, `close()` and a `running` flag
function M:every(interval_ms, fn, run, opts)
	assert(type(fn) == "function", "EventLoop:every: callback required")
	local t = setmetatable({
		_loop = self,
		interval = math.max(tonumber(interval_ms) or 100, 1) / 1000,
		fn = fn,
		running = false,
		keep_on_error = opts and opts.keep_on_error == true,
	}, Timer)
	self._timers[#self._timers + 1] = t
	if run ~= false then t:start() end
	return t
end

--- A one-shot timer.
-- @tparam number delay_ms milliseconds from now
-- @tparam function fn callback
-- @treturn table timer (see `every`)
function M:after(delay_ms, fn)
	local t
	t = self:every(delay_ms, function()
		t:close()
		fn()
	end)
	return t
end

function M:_drop(timer)
	for i = #self._timers, 1, -1 do
		if self._timers[i] == timer then table.remove(self._timers, i) end
	end
end

-- Fire due timers; returns the time until the next one is due (or nil).
function M:_fire_timers()
	local t_now = self._now()
	-- A callback may add or close timers; walk a snapshot.
	local snapshot = {}
	for i, t in ipairs(self._timers) do snapshot[i] = t end
	for _, t in ipairs(snapshot) do
		if t.running and t.due <= t_now then
			t.due = t_now + t.interval
			local ok, err = xpcall(t.fn, debug.traceback)
			if not ok then
				if not t.keep_on_error then t.running = false end
				self:_report("Timer error: " .. tostring(err))
			end
		end
	end
	local next_in
	t_now = self._now()
	for _, t in ipairs(self._timers) do
		if t.running then
			local d = t.due - t_now
			if not next_in or d < next_in then next_in = d end
		end
	end
	return next_in
end

--- Is there anything left to do (a running timer, a job, a copas task)?
function M:busy()
	for _, t in ipairs(self._timers) do
		if t.running then return true end
	end
	local jobs = self:_jobs_mod()
	if jobs and jobs.active() > 0 then return true end
	local async = self:_async_mod()
	if async and async.available and async.copas and not async.copas.finished() then return true end
	return false
end

--- One turn of the loop (exposed for tests).
-- @treturn boolean whether any work is left
function M:turn()
	local next_in = self:_fire_timers()
	local jobs = self:_jobs_mod()
	local job_count = 0
	if jobs then
		if jobs.active() > 0 then jobs.tick() end
		job_count = jobs.active()
	end
	local wait = self.max_wait
	if job_count > 0 then wait = math.min(wait, self.job_wait) end
	if next_in then wait = math.min(wait, math.max(next_in, 0)) end
	if self._stopped then return false end
	local async = self:_async_mod()
	if async and async.available and async.copas and not async.copas.finished() then
		local ok, err = pcall(async.step, wait)
		if not ok then self:_report("Scheduler error: " .. tostring(err)) end
	else
		self._sleep(wait)
	end
	return self:busy()
end

--- Run until `stop()` (or, with `until_idle`, until nothing is left to do).
-- @tparam[opt] table opts `{ until_idle = boolean, deadline = seconds }`
-- @treturn string why it returned: `"stopped"`, `"idle"` or `"deadline"`
function M:run(opts)
	opts = opts or {}
	local deadline = opts.deadline and (self._now() + opts.deadline)
	self._stopped = false
	while not self._stopped do
		if self._should_stop and self._should_stop() then return "stopped" end
		local more = self:turn()
		if opts.until_idle and not more then return "idle" end
		if deadline and self._now() >= deadline then return "deadline" end
	end
	return "stopped"
end

--- Let running jobs finish: disarm every timer (no new work starts from one),
-- then keep pumping jobs and copas until no job is left or `seconds` pass.
-- Copas tasks alone (an idle HTTP server) don't hold it open.
-- @tparam number seconds grace period
-- @treturn boolean true when every job finished in time
function M:drain(seconds)
	for _, t in ipairs(self._timers) do t.running = false end
	local jobs = self:_jobs_mod()
	if not jobs then return true end
	local deadline = self._now() + math.max(tonumber(seconds) or 0, 0)
	self._stopped = false
	while jobs.active() > 0 do
		if self._now() >= deadline then return false end
		self:turn()
	end
	return true
end

--- Ask `run()` to return after the current turn.
function M:stop()
	self._stopped = true
end

--- Stop every timer and refuse new ones (on shutdown).
function M:close()
	self._closed = true
	for _, t in ipairs(self._timers) do t.running = false end
	self._timers = {}
	self:stop()
end

return M
