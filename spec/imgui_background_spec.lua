local Runtime = require("core.imgui.Runtime")
local Null = require("core.imgui.backend.Null")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local ProcessJob = require("core.lib.ProcessJob")
local Activity = require("core.classes.Activity")
local ActivityPanel = require("core.ui.ActivityPanel")
local TaskRunner = require("core.classes.TaskRunner")
local Extension = require("core.classes.Extension")
local HostAPI = require("core.classes.HostAPI")

local backend
local warnings
local old_warn
local old_error

local function frame(dt)
	if dt then backend.advance(dt) end
	Runtime.step(false)
end

local function timer(opts)
	local t = iup.timer({ time = tostring(opts.time or 100) })
	function t:action_cb()
		return opts.action()
	end
	t.run = opts.run == false and "NO" or "YES"
	return t
end

local function host()
	local tabs = iup.flattabs{}
	local ext_menu, file_menu, help_menu = iup.menu{}, iup.menu{}, iup.menu{}
	local status_box = iup.hbox{}
	local host = HostAPI:new({
		iup = iup, mode = "gui", app = { title = "test", version = "1", dir = "." },
		settings = { get = function() end, set = function() end, save = function() end },
		tabs = tabs, ext_menu = ext_menu, file_menu = file_menu, help_menu = help_menu,
		status_box = status_box, set_status = function() end,
		notify = function() end,
		subprocess = { terminate = function() end, destroy = function() end },
	})
	return host, tabs, ext_menu, file_menu, help_menu
end

local function fake_process(chunks, hold_open)
	local pos = { stdout = 0, stderr = 0 }
	local killed = false
	local proc = {}
	function proc:read(name)
		if name ~= "stdout" then return nil end
		pos.stdout = pos.stdout + 1
		return chunks[pos.stdout]
	end
	function proc:poll()
		if killed then return 1 end
		if hold_open then return nil end
		return pos.stdout >= #chunks and 0 or nil
	end
	function proc:kill() killed = true end
	function proc:close() end
	return {
		spawn = function() return proc end,
	}, function() return killed end
end

describe("background work on the ImGui host", function()
	before_each(function()
		backend = Null.new({ w = 1280, h = 800 })
		Runtime.init(backend)
		package.loaded["core.lib.ProcessJob"] = nil
		ProcessJob = require("core.lib.ProcessJob")
		warnings = {}
		old_warn, old_error = Runtime.warn, Element.hooks.error
		Runtime.warn = function(message) warnings[#warnings + 1] = tostring(message) end
		Element.hooks.error = function(_, name, err)
			warnings[#warnings + 1] = name .. ": " .. tostring(err)
		end
	end)

	after_each(function()
		Runtime.warn, Element.hooks.error = old_warn, old_error
	end)

	it("fires a timer once per elapsed period", function()
		local count = 0
		local t = timer({ time = 100, action = function() count = count + 1; return iup.DEFAULT end })
		frame(0.099); assert.equals(0, count)
		frame(0.001); assert.equals(1, count)
		frame(0.2); assert.equals(2, count)
		iup.Destroy(t)
	end)

	it("does not coalesce multiple periods into a burst", function()
		local count = 0
		local t = timer({ time = 100, action = function() count = count + 1; return iup.DEFAULT end })
		frame(0.31); assert.equals(1, count)
		frame(0.1); assert.equals(2, count)
		iup.Destroy(t)
	end)

	it("stops a timer when RUN is set to NO", function()
		local count = 0
		local t = timer({ time = 50, action = function() count = count + 1; return iup.DEFAULT end })
		frame(0.05); assert.equals(1, count)
		iup.SetAttribute(t, "RUN", "NO")
		frame(1); assert.equals(1, count)
		iup.Destroy(t)
	end)

	it("contains a timer callback error and keeps other timers alive", function()
		local good = 0
		local bad = timer({ time = 10, action = function() error("timer boom") end })
		local ok = timer({ time = 10, action = function() good = good + 1; return iup.DEFAULT end })
		frame(0.01)
		assert.equals(1, good)
		assert.is_true(#warnings > 0)
		assert.equals("YES", iup.GetAttribute(bad, "RUN"))
		iup.Destroy(bad); iup.Destroy(ok)
	end)

	it("lets a timer callback return CLOSE", function()
		local t = timer({ time = 10, action = function() return iup.CLOSE end })
		local dialog = iup.dialog{ iup.label{ TITLE = "loop" } }
		iup.Show(dialog)
		local ok = pcall(function() Runtime.mainLoop() end)
		assert.is_true(ok)
		iup.Destroy(t); iup.Destroy(dialog)
	end)

	it("can destroy a timer from its own callback", function()
		local count = 0
		local t
		t = timer({ time = 10, action = function()
			count = count + 1
			iup.Destroy(t)
			return iup.DEFAULT
		end })
		frame(0.01); frame(0.01)
		assert.equals(1, count)
	end)

	it("updates Activity progress and completion states", function()
		local now = 0
		local store = Activity:new({ now = function() return now end })
		local work = store:start({ title = "Upload", tool = "Sync" })
		work:progress(2, 10, "two")
		local row = ActivityPanel.rows(store)[1]
		assert.equals("running", row.state)
		assert.equals(0.2, row.progress)
		assert.truthy(row.secondary:find("two", 1, true))
		now = 1; work:finish(true, "done")
		assert.equals("ok", ActivityPanel.rows(store)[1].state)
	end)

	it("shows failed activity rows and marks them viewable", function()
		local store = Activity:new({ now = function() return 0 end })
		local work = store:start({ title = "Build" })
		work:finish(false, "compile failed")
		local row = ActivityPanel.rows(store)[1]
		assert.equals("failed", row.state)
		assert.equals("compile failed", row.secondary)
		assert.equals(1, store:unviewed())
		store:markViewed()
		assert.equals(0, store:unviewed())
	end)

	it("preserves newest-first activity panel ordering", function()
		local store = Activity:new({ now = function() return 0 end })
		store:start({ title = "First" })
		store:start({ title = "Second" })
		local rows = ActivityPanel.rows(store)
		assert.equals("Second", rows[1].title)
		assert.equals("First", rows[2].title)
	end)

	it("offers cancellation for running activity rows", function()
		local cancelled = false
		local store = Activity:new()
		store:start({ title = "Cancelable", cancel = function() cancelled = true end })
		local row = ActivityPanel.rows(store)[1]
		assert.same({ "cancel" }, row.actions)
		assert.is_true(store:cancel(1))
		assert.is_true(cancelled)
	end)

	it("finishes owned activity when removed", function()
		local owner = {}
		local store = Activity:new()
		local work = store:start({ title = "Owned", owner = owner })
		store:removeOwned(owner)
		assert.is_false(work:isRunning())
		assert.equals("cancelled", ActivityPanel.rows(store)[1].state)
	end)

	it("streams ProcessJob events through its real IUP timer", function()
		local cjson = require("cjson")
		local mod = fake_process({
			cjson.encode({ v = 1, type = "log", message = "one" }) .. "\n",
			cjson.encode({ v = 1, type = "log", message = "two" }) .. "\n",
			cjson.encode({ v = 1, type = "result", ok = true }) .. "\n",
		})
		local events = {}
		local job = assert(ProcessJob.start({
			argv = { "fake" }, process = mod,
			on_event = function(event) events[#events + 1] = event.message end,
		}))
		local tick = timer({ time = 10, action = function() job:pump(); return iup.DEFAULT end })
		for _ = 1, 6 do frame(0.05) end
		for _ = 1, 20 do if job:result() then break end; job:pump() end
		assert.same({ "one", "two" }, events)
		assert.equals("ok", job:result().status)
		iup.Destroy(tick)
	end)

	it("keeps ProcessJob callback errors contained", function()
		local cjson = require("cjson")
		local mod = fake_process({
			cjson.encode({ v = 1, type = "log", message = "result" }) .. "\n",
			cjson.encode({ v = 1, type = "result", ok = true }) .. "\n",
		})
		local job = assert(ProcessJob.start({
			argv = { "fake" }, process = mod,
			on_event = function() error("callback boom") end,
		}))
		local tick = timer({ time = 10, action = function() job:pump(); return iup.DEFAULT end })
		for _ = 1, 6 do frame(0.05) end
		for _ = 1, 20 do if job:result() then break end; job:pump() end
		assert.equals("ok", job:result().status)
		assert.truthy(job:result().callback_error:find("callback boom", 1, true))
		iup.Destroy(tick)
	end)

	it("cancels ProcessJob and stops later callbacks", function()
		local cjson = require("cjson")
		local mod, killed = fake_process({
			cjson.encode({ v = 1, type = "log", message = "before" }) .. "\n",
			cjson.encode({ v = 1, type = "log", message = "after" }) .. "\n",
		}, true)
		local events = {}
		local job = assert(ProcessJob.start({
			argv = { "fake" }, process = mod,
			on_event = function(event) events[#events + 1] = event.message end,
		}))
		local tick = timer({ time = 10, action = function() job:pump(); return iup.DEFAULT end })
		frame(0.05); job:cancel(); frame(0.05)
		assert.is_true(killed())
		-- Job:cancel kills the tool; the next pump still reads what was already buffered,
		-- then finishes "cancelled" and drops the callbacks (ProcessJob's documented contract)
		assert.equals("before", events[1])
		assert.equals("cancelled", job:result().status)
		local seen = #events
		frame(0.05); frame(0.05)
		assert.equals(seen, #events)
		iup.Destroy(tick)
	end)

	it("gives each ProcessJob chunk its own frame", function()
		local cjson = require("cjson")
		local chunks = {}
		for i = 1, 10000 do chunks[i] = cjson.encode({ type = "log", message = tostring(i) }) .. "\n" end
		chunks[#chunks + 1] = cjson.encode({ type = "result", ok = true }) .. "\n"
		local mod = fake_process(chunks)
		local per_frame, current = {}, 0
		local job = assert(ProcessJob.start({
			argv = { "fake" }, process = mod,
			on_event = function() current = current + 1 end,
		}))
		job:attach_timer(iup, 1)
		for _ = 1, 10001 do
			current = 0; frame(0.001); per_frame[#per_frame + 1] = current
			if job:result() then break end
		end
		for _, count in ipairs(per_frame) do assert.is_true(count <= 1) end
	end)

	it("runs TaskRunner callbacks on later emulator frames", function()
		local pending, statuses = {}, {}
		local runner = TaskRunner:new({
			spawn = function()
				return {
					read = function() end, poll = function() return 0 end,
					kill = function() end, close = function() end,
				}
			end,
			status = function(message) statuses[#statuses + 1] = message end,
			after = function(_, fn)
				local t = timer({ time = 1, action = function() fn(); return iup.DEFAULT end })
				pending[#pending + 1] = t
			end,
		})
		assert.is_true(runner:run({ label = "Build", argv = { "fake" } }))
		assert.equals("Build: running", statuses[1])
		frame(0.001)
		assert.equals("Build: finished", statuses[2])
	end)

	it("does not run the same TaskRunner task twice", function()
		local runner = TaskRunner:new({
			spawn = function() return { read = function() end, poll = function() return nil end, kill = function() end } end,
			status = function() end, after = function() end,
		})
		local task = { label = "Build", argv = { "fake" } }
		assert.is_true(runner:run(task))
		assert.is_false(runner:run(task))
	end)

	it("contains TaskRunner process callback failures", function()
		local runner = TaskRunner:new({
			spawn = function() return { read = function() error("read boom") end, poll = function() return 0 end, close = function() end } end,
			status = function() end, after = function(_, fn) fn() end,
		})
		assert.is_true(runner:run({ label = "Build", argv = { "fake" } }))
		assert.is_false(runner:isRunning("Build"))
	end)

	it("tears down an Extension timer and UI through HostAPI ownership", function()
		local h, tabs, menu = host()
		local ext = Extension:new("Owned", "1")
		ext._ctx = h; ext._iup = iup
		local fired = 0
		local t = ext:addTimer({ time = 10, run = true, action = function() fired = fired + 1 end })
		local button = iup.flatbutton{ TITLE = "owned" }
		ext:addTab("Owned", iup.vbox{ button })
		ext:addMenuItem("Owned", function() end)
		frame(0.01); assert.equals(1, fired)
		h:removeOwned(ext)
		frame(0.1)
		assert.equals(1, fired)
		assert.is_nil(Element.state(t))
		assert.is_nil(Element.state(button))
		assert.equals(0, #Element.state(menu).children)
		assert.is_true(#Element.state(tabs).children >= 0)
	end)

	it("leaves another extension's timer and elements untouched", function()
		local h = host()
		local a, b = Extension:new("A", "1"), Extension:new("B", "1")
		a._ctx, b._ctx, a._iup, b._iup = h, h, iup, iup
		local ac, bc = 0, 0
		local at = a:addTimer({ time = 10, run = true, action = function() ac = ac + 1 end })
		b:addTimer({ time = 10, run = true, action = function() bc = bc + 1 end })
		frame(0.01); h:removeOwned(a); frame(0.01)
		assert.equals(1, ac); assert.equals(2, bc)
		assert.is_nil(Element.state(at))
	end)

	it("removes extension routes during teardown", function()
		local h = host()
		local ext = Extension:new("Routes", "1")
		ext._ctx = h; ext._iup = iup
		assert.is_true(h:registerExtension(ext, { id = "routes", name = "Routes" }, {}))
		ext:addRoute("ping", function() return { ok = true } end)
		local ok = h:dispatchRoute("lunar://plugin/routes/ping")
		assert.is_true(ok)
		h:removeOwned(ext)
		ok = h:dispatchRoute("lunar://plugin/routes/ping")
		assert.is_not_true(ok)
	end)

	it("isolates extension module caches", function()
		local Modules = require("core.lib.ExtensionModules")
		local a = Modules.new(".")
		local b = Modules.new(".")
		assert.are_not.equal(a, b)
		a:unload(); b:unload()
	end)

	it("reports extension shutdown errors without breaking teardown", function()
		local h = host()
		local ext = Extension:new("Broken", "1")
		ext._ctx = h; ext.shutdown = function() error("shutdown boom") end
		local ok = pcall(function() h:removeOwned(ext) end)
		assert.is_true(ok)
	end)

	it("does not load Runtime when requiring the service loop", function()
		local saved = {}
		for _, name in ipairs({ "core.imgui.Runtime", "core.lib.EventLoop", "core.headless" }) do
			saved[name] = package.loaded[name]; package.loaded[name] = nil
		end
		require("core.lib.EventLoop")
		require("core.headless")
		local loaded = package.loaded["core.imgui.Runtime"] ~= nil
		for name, mod in pairs(saved) do package.loaded[name] = mod end
		assert.is_false(loaded)
	end)

	it("parses service mode options without UI", function()
		local headless = require("core.headless")
		local opts = assert(headless.parse_args({ "--until-idle", "--for", "2" }))
		assert.is_true(opts.until_idle)
		assert.equals(2, opts.seconds)
	end)

	it("keeps Activity callbacks isolated from host frames", function()
		local store = Activity:new()
		store:subscribe(function() error("listener boom") end)
		local work = store:start({ title = "Safe" })
		work:progress(1, 2, "one")
		work:finish(true)
		assert.equals("ok", store:get(1).state)
	end)

	it("updates status text through a real host callback", function()
		local messages = {}
		local h = HostAPI:new({
			iup = iup, mode = "gui", app = {}, settings = {},
			set_status = function(message) messages[#messages + 1] = message end,
			notify = function() end,
		})
		h:setStatus("tick")
		assert.equals("tick", messages[1])
	end)
end)
