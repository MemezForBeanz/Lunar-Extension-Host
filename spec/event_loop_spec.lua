local EventLoop = require("core.lib.EventLoop")

-- A loop on a fake clock: sleeping advances time, copas and jobs are stubs.
local function fake_loop(opts)
	opts = opts or {}
	local clock = { t = 1000, slept = {} }
	local jobs = opts.jobs or { active = function() return 0 end, tick = function() end }
	local loop = EventLoop.new({
		now = function() return clock.t end,
		sleep = function(s) clock.slept[#clock.slept + 1] = s; clock.t = clock.t + s end,
		async = false,
		jobs = jobs,
		on_error = opts.on_error,
		should_stop = opts.should_stop,
		max_wait = opts.max_wait,
	})
	return loop, clock
end

describe("core.lib.EventLoop", function()
	it("fires a repeating timer every interval", function()
		local loop, clock = fake_loop()
		local ticks = {}
		local t = loop:every(100, function() ticks[#ticks + 1] = clock.t end)
		loop:run({ deadline = 0.35 })
		t:stop()
		assert.are.same({ 1000.1, 1000.2, 1000.3 }, (function()
			local r = {}
			for i, v in ipairs(ticks) do r[i] = math.floor(v * 1000 + 0.5) / 1000 end
			return r
		end)())
	end)

	it("runs a one-shot timer once and drops it", function()
		local loop = fake_loop()
		local n = 0
		loop:after(50, function() n = n + 1 end)
		assert.are.equal("idle", loop:run({ until_idle = true, deadline = 5 }))
		assert.are.equal(1, n)
		assert.is_false(loop:busy())
	end)

	it("a stopped timer doesn't fire, a started one does", function()
		local loop = fake_loop()
		local n = 0
		local t = loop:every(10, function() n = n + 1 end, false)
		loop:run({ deadline = 0.1 })
		assert.are.equal(0, n)
		t:start()
		loop:run({ deadline = 0.05 })
		assert.is_true(n >= 4)
	end)

	it("disarms a timer whose callback raises and reports it once", function()
		local reports = {}
		local loop = fake_loop({ on_error = function(m) reports[#reports + 1] = m end })
		local n = 0
		local t = loop:every(10, function() n = n + 1; error("boom") end)
		loop:run({ deadline = 0.1 })
		assert.are.equal(1, n)
		assert.is_false(t.running)
		assert.are.equal(1, #reports)
		assert.truthy(reports[1]:find("boom", 1, true))
	end)

	it("keeps a keep_on_error timer armed and reports every failure", function()
		local reports = {}
		local loop = fake_loop({ on_error = function(m) reports[#reports + 1] = m end })
		local n = 0
		local t = loop:every(10, function() n = n + 1; error("boom") end, true, { keep_on_error = true })
		loop:run({ deadline = 0.055 })
		assert.are.equal(5, n)
		assert.is_true(t.running)
		assert.are.equal(5, #reports)
	end)

	it("drain disarms timers and pumps jobs until none are left", function()
		local left = 3
		local jobs = { active = function() return left end, tick = function() left = math.max(left - 1, 0) end }
		local loop = fake_loop({ jobs = jobs })
		local n = 0
		local t = loop:every(10, function() n = n + 1 end)
		assert.is_true(loop:drain(5))
		assert.are.equal(0, left)
		assert.are.equal(0, n)
		assert.is_false(t.running)
	end)

	it("drain gives up at the grace period while a job still runs", function()
		local jobs = { active = function() return 1 end, tick = function() end }
		local loop, clock = fake_loop({ jobs = jobs })
		local start = clock.t
		assert.is_false(loop:drain(1))
		assert.is_true(clock.t - start >= 1)
		assert.is_true(clock.t - start < 1.2)
	end)

	it("sleeps until the next timer, at most max_wait", function()
		local loop, clock = fake_loop({ max_wait = 0.25 })
		loop:every(1000, function() end)
		loop:turn()
		assert.are.equal(0.25, clock.slept[1])
		local loop2, clock2 = fake_loop({ max_wait = 0.25 })
		loop2:every(40, function() end)
		loop2:turn()
		assert.is_true(math.abs(clock2.slept[1] - 0.04) < 1e-9)
	end)

	it("ticks process jobs while any are active and waits less meanwhile", function()
		local active, ticked = 2, 0
		local jobs = {
			active = function() return active end,
			tick = function() ticked = ticked + 1; active = active - 1 end,
		}
		local loop, clock = fake_loop({ jobs = jobs })
		assert.is_true(loop:turn())
		assert.are.equal(1, ticked)
		assert.is_true(clock.slept[1] <= 0.05)
		assert.are.equal("idle", loop:run({ until_idle = true, deadline = 5 }))
		assert.are.equal(2, ticked)
	end)

	it("returns when should_stop says so, and close() disarms everything", function()
		local stop = false
		local loop = fake_loop({ should_stop = function() return stop end })
		local n = 0
		local t = loop:every(10, function() n = n + 1; if n == 3 then stop = true end end)
		assert.are.equal("stopped", loop:run())
		assert.are.equal(3, n)
		loop:close()
		assert.is_false(t.running)
		assert.is_false(loop:busy())
	end)
end)
