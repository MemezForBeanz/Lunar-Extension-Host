--- Run a tool as a job that streams JSON-lines events (the engine protocol).
--
-- The tool writes one JSON object per line to **stdout**. Everything on
-- **stderr** is diagnostics: passed to `on_stderr` line by line and kept (the
-- tail) for the final report, never parsed. So a Python warning or a traceback
-- can't corrupt the protocol.
--
-- **Protocol v1.** Every stdout line is an object with `v = 1` and a `type`:
--
--   * `progress` - `{ step, done, total, message }` (all optional but `type`)
--   * `log`      - `{ level, message }`
--   * `item`     - one unit of work changing state (`{ id, state, ... }`)
--   * `result`   - the final outcome: `{ ok = true|false, summary, data }`
--   * `error`    - a failure the tool caught: `{ message, code }`
--
-- JSON `null` arrives as `cjson.null`, not `nil`. Lines that aren't valid
-- protocol, or are longer than `max_line` bytes, are counted, reported through
-- `on_protocol_error` and skipped.
--
-- **Success is explicit.** A job is `"ok"` only when the tool exits with code 0
-- *and* reported a `result` with `ok = true`. Exit code 0 alone could be a tool
-- that crashed its own way out, or never got to the end.
--
-- **Nothing blocks the caller.** stdin is delivered by a native background
-- thread, and each `pump()` reads a bounded amount from each stream. Drive jobs
-- with `attach_timer` (one shared timer runs every job) or call `pump()` yourself.
--
-- **Callbacks can't break the job.** An error in `on_event`, `on_stderr`,
-- `on_protocol_error` or `on_exit` is caught, logged and recorded in the result
-- (`callback_error`); the tool keeps running.
--
-- @module core.lib.ProcessJob
-- @usage
--   local job = assert(ProcessJob.start{
--       argv = { engine, "collect", "--json", "675.30" },
--       env = { API_TOKEN = token },
--       on_event = function(ev) if ev.type == "progress" then bar(ev.done, ev.total) end end,
--       on_exit = function(res) show(res.status, res.summary) end,
--   })
--   job:attach_timer(iup)

local M = {}

--- Protocol version this host speaks.
M.PROTOCOL = 1

local KNOWN_TYPES = { progress = true, log = true, item = true, result = true, error = true }

local Job = {}
Job.__index = Job

local function now_seconds()
	local ok, socket = pcall(require, "socket")
	if ok and socket.gettime then return socket.gettime() end
	return os.time()
end

local function log_warn(msg)
	local ok, log = pcall(require, "core.lib.log")
	if ok and log.get then pcall(function() log.get("job"):warn(msg) end) end
end

local function decode(line)
	local ok_cjson, cjson = pcall(require, "cjson")
	if not ok_cjson then return nil, "cjson unavailable" end
	local ok, obj = pcall(cjson.decode, line)
	if not ok then return nil, "not JSON" end
	if type(obj) ~= "table" then return nil, "not a JSON object" end
	if obj.v ~= M.PROTOCOL then return nil, "protocol version " .. tostring(obj.v) .. ", expected " .. M.PROTOCOL end
	if not KNOWN_TYPES[obj.type] then return nil, "unknown event type " .. tostring(obj.type) end
	return obj
end

local function nonneg(v, default)
	v = tonumber(v)
	if v == nil then return default end
	return math.max(0, v)
end

--- Start a job.
-- @tparam table opts
-- @tparam table opts.argv Program and arguments (no shell).
-- @tparam[opt] string opts.cwd Working directory for the tool.
-- @tparam[opt] table opts.env Environment overrides (`false` removes a variable).
--   Pass credentials here or through `stdin`, never in `argv`.
-- @tparam[opt] string opts.stdin Written to the tool's stdin (then closed) by a
--   background thread. Not kept by the job.
-- @tparam[opt] function opts.on_event `fn(event)` for each protocol event.
-- @tparam[opt] function opts.on_stderr `fn(line)` for each stderr line.
-- @tparam[opt] function opts.on_protocol_error `fn(line, reason)`.
-- @tparam[opt] function opts.on_exit `fn(result)` once, when the job is finished
--   (see `Job:result`).
-- @tparam[opt=1048576] number opts.max_line Longest accepted stdout line, in bytes.
-- @tparam[opt=65536] number opts.stderr_keep Bytes of stderr tail kept (0 keeps none).
-- @tparam[opt=65536] number opts.read_chunk Bytes read per stream per `pump`.
-- @tparam[opt=2] number opts.drain_grace After the tool exits, finish once no
--   output has arrived for this many seconds (a grandchild may hold a stream open).
-- @tparam[opt=10] number opts.drain_limit Finish this many seconds after exit
--   regardless, ending anything still running; the result is marked `truncated`.
-- @tparam[opt] table opts.process Process module (tests pass a fake); defaults to
--   the native `process` module.
-- @tparam[opt] function opts.now Clock in seconds (tests).
-- @treturn[1] Job
-- @treturn[2] nil
-- @treturn[2] string Why the tool could not be started.
function M.start(opts)
	assert(type(opts) == "table" and type(opts.argv) == "table", "ProcessJob.start: opts.argv required")
	local proc_mod = opts.process or require("process")
	local proc, err = proc_mod.spawn({
		argv = opts.argv, cwd = opts.cwd, env = opts.env, stdin = opts.stdin,
	})
	if not proc then return nil, err end
	-- Copy what the job needs; never keep opts (it may hold stdin or env secrets).
	return setmetatable({
		_proc = proc,
		_on_event = opts.on_event,
		_on_stderr = opts.on_stderr,
		_on_protocol_error = opts.on_protocol_error,
		_on_exit = opts.on_exit,
		_now = opts.now or now_seconds,
		_max_line = math.max(1, nonneg(opts.max_line, 1024 * 1024)),
		_stderr_keep = nonneg(opts.stderr_keep, 64 * 1024),
		_chunk = math.max(1, nonneg(opts.read_chunk, 64 * 1024)),
		_grace = nonneg(opts.drain_grace, 2),
		_limit = nonneg(opts.drain_limit, 10),
		_out = { buf = "", skipping = false, eof = false },
		_err = { buf = "", skipping = false, eof = false },
		_stderr_tail = "",
		_protocol_errors = 0,
		_done = false,
	}, Job)
end

-- Call a user callback; record (don't raise) its error.
function Job:_call(fn, ...)
	if not fn then return end
	local ok, err = pcall(fn, ...)
	if not ok then
		self._callback_errors = (self._callback_errors or 0) + 1
		self._callback_error = self._callback_error or tostring(err)
		log_warn("job callback failed: " .. tostring(err))
	end
end

-- Split `chunk` into complete lines for `stream`. Lines longer than max_line are
-- reported once (on_line(nil, reason)) and dropped, whether or not they arrived
-- with their newline in the same read.
function Job:_feed(stream, chunk, on_line)
	local data = stream.buf .. chunk
	local start = 1
	local too_long = "line longer than " .. self._max_line .. " bytes"
	while true do
		local nl = data:find("\n", start, true)
		if not nl then break end
		local line = data:sub(start, nl - 1):gsub("\r$", "")
		if stream.skipping then
			stream.skipping = false  -- the tail of a line already reported
		elseif #line > self._max_line then
			on_line(nil, too_long)
		else
			on_line(line)
		end
		start = nl + 1
	end
	stream.buf = data:sub(start)
	if #stream.buf > self._max_line then
		if not stream.skipping then on_line(nil, too_long) end
		stream.skipping = true
		stream.buf = ""
	end
end

function Job:_stdout_line(line, why)
	if not line then
		self._protocol_errors = self._protocol_errors + 1
		self:_call(self._on_protocol_error, "", why)
		return
	end
	if line:match("^%s*$") then return end
	local ev, bad = decode(line)
	if not ev then
		self._protocol_errors = self._protocol_errors + 1
		self:_call(self._on_protocol_error, line, bad)
		return
	end
	if ev.type == "result" then self._result = ev end
	if ev.type == "error" then self._error = ev end
	self:_call(self._on_event, ev)
end

function Job:_stderr_line(line)
	if not line then return end  -- an oversized stderr line is simply dropped
	if self._stderr_keep > 0 then
		local tail = self._stderr_tail .. line .. "\n"
		if #tail > self._stderr_keep then tail = tail:sub(-self._stderr_keep) end
		self._stderr_tail = tail
	end
	self:_call(self._on_stderr, line)
end

function Job:_read(stream, name, on_line)
	if stream.eof then return 0 end
	local data, err = self._proc:read(name, self._chunk)
	if data == nil then
		if err then self._read_error = self._read_error or (name .. ": " .. tostring(err)) end
		stream.eof = true
		-- A final line without a newline still counts.
		if stream.buf ~= "" and not stream.skipping then
			local last = stream.buf:gsub("\r$", "")
			stream.buf = ""
			on_line(last)
		end
		return 0
	end
	if #data > 0 then self:_feed(stream, data, on_line) end
	return #data
end

--- Read what is available and advance the job.
-- @treturn boolean `true` while the job is still running or draining.
function Job:pump()
	if self._done then return false end
	local got = self:_read(self._out, "stdout", function(l, why) self:_stdout_line(l, why) end)
	got = got + self:_read(self._err, "stderr", function(l) self:_stderr_line(l) end)
	if got > 0 then self._last_output = self._now() end

	if self._exit_code == nil then
		self._exit_code = self._proc:poll()
		if self._exit_code ~= nil then self._exited_at = self._now() end
	end
	if self._exit_code ~= nil then
		local t = self._now()
		local drained = self._out.eof and self._err.eof
		local quiet = got == 0 and t - math.max(self._exited_at, self._last_output or 0) >= self._grace
		local deadline = t - self._exited_at >= self._limit
		-- A cancelled job has nothing left worth waiting for.
		if drained or quiet or deadline or self._cancelled then
			self._truncated = (deadline and not drained and not quiet) or nil
			self:_finish()
			return false
		end
	end
	return true
end

function Job:_finish(internal_error)
	if self._done then return end
	self._done = true
	self._proc:close()  -- ends anything still running in the tool's tree

	local status, summary
	local result = self._result
	if internal_error then
		status, summary = "failed", "Internal error: " .. tostring(internal_error)
	elseif self._cancelled then
		status, summary = "cancelled", "Cancelled"
	elseif self._exit_code == 0 and result and result.ok == true then
		status, summary = "ok", result.summary
	else
		status = "failed"
		if self._error and type(self._error.message) == "string" then
			summary = self._error.message
		elseif result and result.ok == false then
			summary = type(result.summary) == "string" and result.summary or "The tool reported a failure"
		elseif self._exit_code ~= 0 then
			summary = "Exited with code " .. tostring(self._exit_code)
		else
			summary = "Exited without reporting a result"
		end
	end
	self._final = {
		status = status,
		summary = summary,
		exit_code = self._exit_code,
		result = result,
		error = self._error,
		stderr_tail = self._stderr_tail,
		protocol_errors = self._protocol_errors,
		read_error = self._read_error,
		truncated = self._truncated,
		callback_error = self._callback_error,
	}
	self:_call(self._on_exit, self._final)
	self._final.callback_error = self._callback_error  -- include an on_exit failure
	-- Drop references the caller handed us so a finished job holds nothing.
	self._on_event, self._on_stderr, self._on_protocol_error, self._on_exit = nil, nil, nil, nil
end

--- Stop the tool and everything it started. The job finishes on the next `pump`.
function Job:cancel()
	if self._done or self._cancelled then return end
	self._cancelled = true
	self._proc:kill()
end

--- `true` once the job has finished and `on_exit` has run.
-- @treturn boolean
function Job:done()
	return self._done
end

--- The final outcome, or `nil` while running:
-- `{ status = "ok"|"failed"|"cancelled", summary, exit_code, result, error,
--    stderr_tail, protocol_errors, read_error, truncated, callback_error }`.
-- @treturn table|nil
function Job:result()
	return self._final
end

-- ---------------------------------------------------------------------------
-- Shared scheduler: one IUP timer pumps every attached job and stops when none
-- are left. A finished job is dropped, so nothing keeps it (or its data) alive.
-- ---------------------------------------------------------------------------

local scheduler = { jobs = {}, timer = nil }

--- Pump every attached job once (the timer's tick; exposed for tests).
function M.tick()
	local still = {}
	for _, job in ipairs(scheduler.jobs) do
		local ok, more = pcall(job.pump, job)
		if not ok then
			-- A bug in the job machinery itself: fail the job, never "cancelled".
			pcall(function() job._proc:kill() end)
			pcall(job._finish, job, more)
			more = false
		end
		if more then still[#still + 1] = job end
	end
	scheduler.jobs = still
	if #still == 0 and scheduler.timer then scheduler.timer.run = "NO" end
end

--- Number of jobs the shared timer is driving.
-- @treturn integer
function M.active()
	return #scheduler.jobs
end

--- Drive this job from the shared timer until it finishes.
-- Attaching the same job twice has no effect.
-- @param iup The IUP module.
-- @tparam[opt=50] number interval_ms Tick interval (set by the first attach).
function Job:attach_timer(iup, interval_ms)
	if self._done or self._attached then return end
	self._attached = true
	scheduler.jobs[#scheduler.jobs + 1] = self
	if not scheduler.timer then
		scheduler.timer = iup.timer({ time = interval_ms or 50 })
		function scheduler.timer.action_cb()
			M.tick()
			return iup.DEFAULT
		end
	end
	scheduler.timer.run = "YES"
end

return M
