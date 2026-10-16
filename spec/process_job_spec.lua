local cjson = require("cjson")
local ProcessJob = require("core.lib.ProcessJob")

-- A scripted stand-in for the native `process` module. `script.stdout` and
-- `script.stderr` are lists of chunks handed out one per read ("" = nothing yet);
-- after the list runs out the stream is at EOF unless `hold_open` is set.
-- `exit_after` is how many polls report "still running".
local function fake(script)
	local state = { spawned = nil, killed = false, closed = false, polls = 0, written = {} }
	local proc = {}
	local pos = { stdout = 0, stderr = 0 }
	function proc:read(name)
		local list = script[name] or {}
		pos[name] = pos[name] + 1
		local chunk = list[pos[name]]
		if chunk == nil then
			if script.hold_open and script.hold_open[name] then return "" end
			return nil
		end
		return chunk
	end
	function proc:poll()
		if state.killed then return 1 end
		state.polls = state.polls + 1
		if state.polls > (script.exit_after or 0) then return script.exit_code or 0 end
		return nil
	end
	function proc:kill() state.killed = true return true end
	function proc:close() state.closed = true end

	local mod = {
		spawn = function(opts)
			state.spawned = opts
			if script.spawn_error then return nil, script.spawn_error end
			return proc
		end,
	}
	return mod, state
end

local function ev(t)
	t.v = t.v or 1
	return cjson.encode(t) .. "\n"
end

-- Pump until done (bounded so a bug can't hang the suite).
local function run(job)
	for _ = 1, 1000 do
		if not job:pump() then return job:result() end
	end
	error("job never finished")
end

local function start(script, extra)
	local mod, state = fake(script)
	local events, stderr, bad, final = {}, {}, {}, nil
	local opts = {
		argv = { "engine", "collect" },
		process = mod,
		now = function() return 0 end,
		on_event = function(e) events[#events + 1] = e end,
		on_stderr = function(l) stderr[#stderr + 1] = l end,
		on_protocol_error = function(l, why) bad[#bad + 1] = why end,
		on_exit = function(r) final = r end,
	}
	for k, v in pairs(extra or {}) do opts[k] = v end
	local job = assert(ProcessJob.start(opts))
	return job, { events = events, stderr = stderr, bad = bad, state = state, final = function() return final end }
end

describe("ProcessJob", function()
	it("reports ok only with exit 0 and an ok result", function()
		local job, t = start({
			stdout = { ev({ type = "progress", done = 1, total = 2 }), ev({ type = "result", ok = true, summary = "2 uploaded" }) },
		})
		local res = run(job)
		assert.are.equal("ok", res.status)
		assert.are.equal("2 uploaded", res.summary)
		assert.are.equal(2, #t.events)
		assert.are.same(res, t.final())
		assert.is_true(t.state.closed)
	end)

	it("treats exit 0 without a result as a failure", function()
		local job = start({ stdout = { ev({ type = "progress", done = 1 }) } })
		local res = run(job)
		assert.are.equal("failed", res.status)
		assert.are.equal("Exited without reporting a result", res.summary)
	end)

	it("reports the exit code, the tool's error and the stderr tail on failure", function()
		local job = start({
			stdout = { ev({ type = "error", message = "login failed" }) },
			stderr = { "Traceback (most recent call last):\n", "  boom\n" },
			exit_code = 2,
		})
		local res = run(job)
		assert.are.equal("failed", res.status)
		assert.are.equal("login failed", res.summary)
		assert.are.equal(2, res.exit_code)
		assert.truthy(res.stderr_tail:find("Traceback", 1, true))
	end)

	it("reassembles lines split across reads and strips CRLF", function()
		local line = ev({ type = "log", level = "info", message = "hello" }):gsub("\n$", "\r\n")
		local job, t = start({ stdout = { line:sub(1, 7), "", line:sub(8, 20), line:sub(21) } })
		run(job)
		assert.are.equal(1, #t.events)
		assert.are.equal("hello", t.events[1].message)
		assert.are.equal(0, #t.bad)
	end)

	it("never lets stderr noise reach the protocol", function()
		local job, t = start({
			stdout = { ev({ type = "result", ok = true }) },
			stderr = { "DeprecationWarning: {\"v\":1,\"type\":\"result\",\"ok\":false}\n" },
		})
		local res = run(job)
		assert.are.equal("ok", res.status)
		assert.are.equal(1, #t.stderr)
	end)

	it("counts invalid lines and skips oversized ones up to their newline", function()
		local big = string.rep("x", 40)
		local job, t = start({
			stdout = { "not json\n", ev({ v = 2, type = "log" }), ev({ type = "bogus" }), big, big, "tail\n",
				ev({ type = "result", ok = true }) },
		}, { max_line = 50 })
		local res = run(job)
		assert.are.equal("ok", res.status)
		assert.are.equal(4, res.protocol_errors)
		assert.truthy(t.bad[2]:find("protocol version 2", 1, true))
		assert.truthy(t.bad[4]:find("longer than", 1, true))
	end)

	it("takes a final line that has no newline", function()
		local last = ev({ type = "result", ok = true }):gsub("\n$", "")
		local res = run((start({ stdout = { last } })))
		assert.are.equal("ok", res.status)
	end)

	it("keeps draining output written just before exit", function()
		local job, t = start({
			stdout = { "", "", ev({ type = "progress" }), ev({ type = "result", ok = true }) },
			exit_after = 0,
		})
		local res = run(job)
		assert.are.equal("ok", res.status)
		assert.are.equal(2, #t.events)
	end)

	it("finishes after the grace period when a grandchild holds a stream open", function()
		local clock = 0
		local job = start({
			stdout = { ev({ type = "result", ok = true }) },
			hold_open = { stdout = true, stderr = true },
		}, { now = function() clock = clock + 0.5 return clock end, drain_grace = 2 })
		local res = run(job)
		assert.are.equal("ok", res.status)
	end)

	it("cancels by killing the tree and reports cancelled", function()
		local job, t = start({ stdout = { "", "", "" }, hold_open = { stdout = true }, exit_after = 1e9 })
		job:pump()
		job:cancel()
		local res = run(job)
		assert.is_true(t.state.killed)
		assert.are.equal("cancelled", res.status)
	end)

	it("passes argv, cwd and env through and feeds stdin", function()
		local job, t = start({ stdout = {} }, { cwd = "C:\\work", env = { API_TOKEN = "s3cret" }, stdin = "secret\n" })
		assert.are.same({ "engine", "collect" }, t.state.spawned.argv)
		assert.are.equal("C:\\work", t.state.spawned.cwd)
		assert.are.equal("s3cret", t.state.spawned.env.API_TOKEN)
		assert.are.equal("secret\n", t.state.spawned.stdin)  -- delivered natively, off-thread
		for _, v in pairs(job) do assert.are_not.equal("secret\n", v) end  -- not kept
	end)

	it("rejects a complete line over max_line even when it arrives in pieces", function()
		local job, t = start({
			stdout = { string.rep("y", 40), string.rep("y", 20) .. "\n", ev({ type = "result", ok = true }) },
		}, { max_line = 50 })
		local res = run(job)
		assert.are.equal("ok", res.status)
		assert.are.equal(1, res.protocol_errors)
		assert.truthy(t.bad[1]:find("longer than", 1, true))
	end)

	it("keeps no stderr at all with stderr_keep = 0", function()
		local res = run((start({ stdout = { ev({ type = "result", ok = true }) }, stderr = { "noise\n", "more\n" } },
			{ stderr_keep = 0 })))
		assert.are.equal("", res.stderr_tail)
	end)

	it("stops at the drain deadline when a descendant keeps writing after exit", function()
		local clock = 0
		local chatter = {}
		for i = 1, 500 do chatter[#chatter + 1] = "noise " .. i .. "\n" end
		local job = start({ stdout = { ev({ type = "result", ok = true }) }, stderr = chatter, exit_after = 0 },
			{ now = function() clock = clock + 0.1 return clock end, drain_grace = 2, drain_limit = 10 })
		local res = run(job)
		assert.is_true(res.truncated)
		assert.is_true(clock < 20)
	end)

	it("records a failing callback without cancelling the job", function()
		local job = start({ stdout = { "junk\n", ev({ type = "result", ok = true }) } },
			{ on_protocol_error = function() error("ui bug") end })
		local res = run(job)
		assert.are.equal("ok", res.status)
		assert.truthy(res.callback_error:find("ui bug", 1, true))
	end)

	it("records an on_exit failure in the result", function()
		local job = start({ stdout = { ev({ type = "result", ok = true }) } },
			{ on_exit = function() error("on_exit broke") end })
		local res = run(job)
		assert.are.equal("ok", res.status)
		assert.truthy(res.callback_error:find("on_exit broke", 1, true))
	end)

	describe("shared scheduler", function()
		local fake_iup = { DEFAULT = -2, timer = function(t) return t end }

		it("drives attached jobs and drops them when finished", function()
			local a = start({ stdout = { ev({ type = "result", ok = true }) } })
			local b = start({ stdout = { "", "", ev({ type = "result", ok = true }) } })
			a:attach_timer(fake_iup)
			a:attach_timer(fake_iup)  -- no double registration
			b:attach_timer(fake_iup)
			assert.are.equal(2, ProcessJob.active())
			for _ = 1, 20 do ProcessJob.tick() end
			assert.are.equal(0, ProcessJob.active())
			assert.are.equal("ok", a:result().status)
			assert.are.equal("ok", b:result().status)
		end)

		it("fails, not cancels, a job whose pump raises", function()
			local job, t = start({ stdout = { "" }, hold_open = { stdout = true }, exit_after = 1e9 })
			job.pump = function() error("internal boom") end
			job:attach_timer(fake_iup)
			ProcessJob.tick()
			assert.are.equal(0, ProcessJob.active())
			assert.are.equal("failed", job:result().status)
			assert.truthy(job:result().summary:find("internal boom", 1, true))
			assert.is_true(t.state.killed)
		end)
	end)

	it("returns the spawn error", function()
		local mod = fake({ spawn_error = "CreateProcess failed (2): not found" })
		local job, err = ProcessJob.start({ argv = { "nope" }, process = mod })
		assert.is_nil(job)
		assert.truthy(err:find("not found", 1, true))
	end)
end)
