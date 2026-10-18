-- HostAPI: processes belong to the extension that started them, and unloading it
-- ends them; removeOwned finishes its teardown even when a step throws.

local HostAPI = require("core.classes.HostAPI")
local ProcessJob = require("core.lib.ProcessJob")

-- iup stand-in: every call is a no-op unless overridden; timers are plain tables.
local function fake_iup(overrides)
	local base = { DEFAULT = -2, timer = function(t) return t end }
	for k, v in pairs(overrides or {}) do base[k] = v end
	return setmetatable(base, { __index = function() return function() end end })
end

-- A process that runs until killed; `log` records kill/close calls.
local function fake_process(log)
	local p = { killed = false }
	function p:read() return self.killed and nil or "" end
	function p:poll() return self.killed and 137 or nil end
	function p:kill() self.killed = true; log[#log + 1] = "kill" end
	function p:close() self.killed = true; log[#log + 1] = "close" end
	function p:pid() return 4242 end
	return p
end

describe("HostAPI owned processes", function()
	it("cancels an owner's jobs on unload and drops their callbacks", function()
		local log, exits, events = {}, 0, 0
		local host = HostAPI:new({ iup = fake_iup() })
		local owner = {}
		local job = assert(host:startJob({
			argv = { "engine" },
			process = { spawn = function() return fake_process(log) end },
			on_event = function() events = events + 1 end,
			on_exit = function() exits = exits + 1 end,
		}, owner))
		host:removeOwned(owner)
		assert.are.same({ "kill" }, log)
		for _ = 1, 3 do ProcessJob.tick() end
		assert.is_true(job:done())
		assert.are.equal(0, exits)
		assert.are.equal(0, events)
	end)

	it("still calls on_exit for a job that finishes while its owner is loaded", function()
		local exits = 0
		local host = HostAPI:new({ iup = fake_iup() })
		local job = assert(host:startJob({
			argv = { "engine" },
			process = { spawn = function()
				return { read = function() return nil end, poll = function() return 0 end,
					kill = function() end, close = function() end }
			end },
			on_exit = function() exits = exits + 1 end,
		}, {}))
		for _ = 1, 3 do ProcessJob.tick() end
		assert.is_true(job:done())
		assert.are.equal(1, exits)
	end)

	it("closes processes started with spawn when the owner unloads", function()
		local log = {}
		local saved = package.loaded["process"]
		package.loaded["process"] = { spawn = function() return fake_process(log) end }
		local host = HostAPI:new({ iup = fake_iup() })
		local owner, other = {}, {}
		assert(host:spawn({ argv = { "tool" } }, owner))
		assert(host:spawn({ argv = { "tool" } }, other))
		host:removeOwned(owner)
		package.loaded["process"] = saved
		assert.are.same({ "close" }, log)
	end)

	it("records owned legacy subprocess handles and ends them on unload", function()
		local calls = {}
		local module = {
			start = function(cmd) calls[#calls + 1] = "start " .. cmd; return "h1" end,
			start_argv = function(argv, cwd) calls[#calls + 1] = "argv " .. argv[1] .. " " .. cwd; return "h2" end,
			terminate = function(h) calls[#calls + 1] = "terminate " .. h; return true end,
			destroy = function(h) calls[#calls + 1] = "destroy " .. h end,
			poll = function() return nil end,
		}
		local host = HostAPI:new({ iup = fake_iup(), subprocess = module })
		local owner = {}
		assert.are.equal("h1", host.subprocess.start("run.bat", owner))
		assert.are.equal("h2", host.subprocess.start_argv({ "git" }, "C:\\repo", owner))
		assert.are.equal("h1", host.subprocess.start("unowned.bat"))      -- no owner: as before
		assert.is_nil(host.subprocess.poll("h1"))                          -- passthrough
		host.subprocess.destroy("h2")                                      -- caller cleaned up itself
		host:removeOwned(owner)
		assert.are.same({
			"start run.bat", "argv git C:\\repo", "start unowned.bat", "destroy h2",
			"terminate h1", "destroy h1",
		}, calls)
	end)

	it("has no subprocess field when the module isn't available", function()
		assert.is_nil(HostAPI:new({ iup = fake_iup() }).subprocess)
	end)
end)

describe("HostAPI:removeOwned robustness", function()
	it("finishes every step when one destroy throws, and reports the failure", function()
		local destroyed = {}
		local iup = fake_iup({
			Destroy = function(h)
				if h == "bad-timer" then error("boom") end
				destroyed[#destroyed + 1] = h
			end,
		})
		local host = HostAPI:new({ iup = iup })
		local owner = {}
		local rec = host:_record(owner)
		rec.timers = { "bad-timer", "good-timer" }
		rec.items = { "menu-item" }
		local log = {}
		rec.processes[fake_process(log)] = true

		local ok, failures = host:removeOwned(owner)
		assert.is_true(ok)
		assert.are.equal(1, failures)
		assert.are.same({ "good-timer", "menu-item" }, destroyed)
		assert.are.same({ "close" }, log)
		assert.is_nil(host._owners[owner])
	end)
end)
