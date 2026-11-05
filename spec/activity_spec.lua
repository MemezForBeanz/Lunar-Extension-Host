-- Activity: the store, the words it hands the status bar, the panel's rows, and how
-- jobs, tasks and toasts feed it.

local Activity = require("core.classes.Activity")
local ActivityPanel = require("core.ui.ActivityPanel")
local HostAPI = require("core.classes.HostAPI")
local ProcessJob = require("core.lib.ProcessJob")
local StatusBar = require("core.ui.StatusBar")
local TaskRunner = require("core.classes.TaskRunner")

local function store_at(start)
	local clock = { t = start or 100 }
	return Activity:new({ now = function() return clock.t end }), clock
end

local function count_entries(store)
	return #store:list()
end

describe("Activity store", function()
	it("lists newest first and starts out running", function()
		local store = store_at()
		store:start({ title = "One" })
		store:start({ title = "Two" })
		local list = store:list()
		assert.equals("Two", list[1].title)
		assert.equals("One", list[2].title)
		assert.equals("running", list[1].state)
	end)

	it("keeps 50 entries, dropping the oldest finished one", function()
		local store = store_at()
		store:start({ title = "Still running" })
		for i = 1, 60 do store:start({ title = "Job " .. i }):finish(true) end
		local list = store:list()
		assert.equals(50, #list)
		assert.equals("Job 60", list[1].title)
		assert.equals("Still running", list[#list].title)
	end)

	it("never drops running work to stay within the limit", function()
		local store = Activity:new({ limit = 2 })
		for i = 1, 3 do store:start({ title = "Job " .. i }) end
		assert.equals(3, #store:list())
	end)

	it("falls back to the tool's name for an untitled entry", function()
		local store = store_at()
		store:start({ tool = "Log Parser" })
		store:start({})
		assert.equals("Background work", store:list()[1].title)
		assert.equals("Log Parser", store:list()[2].title)
	end)

	it("keeps progress it isn't told about and ignores calls after the end", function()
		local store = store_at()
		local work = store:start({ title = "Scan" })
		work:progress(3, 12, "Reading")
		work:progress(nil, nil, "Writing")
		local item = store:list()[1]
		assert.equals(3, item.done)
		assert.equals(12, item.total)
		assert.equals("Writing", item.message)
		work:finish(true, "done")
		work:progress(9, 12, "late")
		work:finish(false, "late")
		assert.equals(3, item.done)
		assert.equals("ok", item.state)
		assert.equals("done", item.summary)
	end)

	it("says nothing when progress didn't change", function()
		local store = store_at()
		local work = store:start({ title = "Scan" })
		local changes = 0
		store:subscribe(function() changes = changes + 1 end)
		work:progress(1, 4)
		work:progress(1, 4)
		assert.equals(1, changes)
	end)

	it("survives a listener that throws", function()
		local store = store_at()
		store:subscribe(function() error("boom") end)
		assert.has_no.errors(function() store:start({ title = "x" }):finish(true) end)
	end)

	it("drops the cancel closure once the work has ended", function()
		local store = store_at()
		local work = store:start({ title = "x", cancel = function() end })
		work:finish(true)
		assert.is_nil(store:list()[1].cancel)
	end)
end)

describe("Activity cancel", function()
	it("offers nothing for work that didn't say how to stop", function()
		local store = store_at()
		local work = store:start({ title = "Firmware flash" })
		assert.is_false(work:cancel())
		assert.equals("running", store:list()[1].state)
	end)

	it("asks once, and stays running until the tool ends", function()
		local store = store_at()
		local asked = 0
		local work = store:start({ title = "x", cancel = function() asked = asked + 1 end })
		assert.is_true(work:cancel())
		assert.is_false(work:cancel())
		assert.equals(1, asked)
		assert.is_true(work:isRunning())
	end)

	it("treats a failure after a cancel as cancelled", function()
		local store = store_at()
		local work = store:start({ title = "x", cancel = function() end })
		work:cancel()
		work:finish(false, "exit 1")
		assert.equals("cancelled", store:list()[1].state)
		assert.equals(0, store:unviewed())
	end)

	it("handles a cancel that ends the work on the spot", function()
		local store = store_at()
		local work
		work = store:start({ title = "x", cancel = function() work:finish("cancelled", "Stopped") end })
		assert.is_true(work:cancel())
		assert.equals("cancelled", store:list()[1].state)
		assert.is_nil(store:list()[1].cancelling)
	end)

	it("goes back to cancellable and says why when asking throws", function()
		local store = store_at()
		local work = store:start({ title = "x", cancel = function() error("no handle") end })
		local ok, why = work:cancel()
		assert.is_false(ok)
		assert.matches("no handle", why)
		local item = store:list()[1]
		assert.is_nil(item.cancelling)
		assert.is_function(item.cancel)
		assert.matches("Could not cancel", item.message)
	end)
end)

describe("Activity status", function()
	it("is empty when idle", function()
		assert.is_nil(store_at():status())
	end)

	it("shows the oldest running entry and how many more", function()
		local store = store_at()
		store:start({ title = "Build Queue" }):progress(3, 12)
		store:start({ title = "Log Parser" })
		store:start({ title = "Upload" })
		local view = store:status()
		assert.equals("running", view.state)
		assert.equals("Build Queue 3 of 12  2 more running", view.text)
	end)

	it("reads a total of 100 as a percentage", function()
		local store = store_at()
		store:start({ title = "Flash" }):progress(40, 100)
		assert.equals("Flash 40%", store:status().text)
	end)

	it("shows a result for 8 seconds, then nothing", function()
		local store, clock = store_at()
		store:start({ title = "Scan" }):finish(true, "12 files")
		assert.equals("Scan finished", store:status().text)
		assert.equals("ok", store:status().state)
		assert.is_true(store:needsTick())
		clock.t = clock.t + 8
		assert.is_nil(store:status())
		assert.is_false(store:needsTick())
	end)

	it("leaves a failure showing until it is viewed", function()
		local store, clock = store_at()
		store:start({ title = "Scan" }):finish(false, "no share")
		assert.equals("failed", store:status().state)
		clock.t = clock.t + 8
		assert.equals("attention", store:status().state)
		store:markViewed()
		assert.is_nil(store:status())
	end)

	it("counts unseen failures alongside running work", function()
		local store = store_at()
		store:start({ title = "Scan" }):finish(false)
		store:start({ title = "Build" })
		assert.equals("Build  1 failed", store:status().text)
	end)

	it("marks only what a filter picks", function()
		local store = store_at()
		store:start({ title = "A", tab = "one" }):finish(false)
		store:start({ title = "B", tab = "two" }):finish(false)
		store:markViewed(function(item) return item.tab == "one" end)
		assert.equals(1, store:unviewed())
	end)

	it("formats elapsed time", function()
		assert.equals("12s", Activity.elapsed(12.9))
		assert.equals("3m 05s", Activity.elapsed(185))
		assert.equals("1h 02m", Activity.elapsed(3720))
		assert.equals("0s", Activity.elapsed(-1))
	end)
end)

describe("Activity removeOwned", function()
	it("ends the owner's work quietly and lets go of the owner", function()
		local store = store_at()
		local owner, ended = {}, {}
		store:subscribe(function(event, item) if event == "ended" then ended[#ended + 1] = item end end)
		store:start({ title = "Mine", owner = owner, cancel = function() error("not called") end })
		store:start({ title = "Theirs", owner = {} })
		store:removeOwned(owner)
		assert.equals(1, #ended)
		assert.is_true(ended[1].quiet)
		assert.equals("cancelled", ended[1].state)
		assert.is_nil(ended[1].owner)
		assert.equals("running", store:list()[1].state)
		-- Nothing to say about an unload in the status bar's result slot.
		assert.equals("Theirs", store:status().text)
	end)
end)

describe("ActivityPanel rows", function()
	local function always() return true end

	it("gives a running row its fields and Cancel only when it can be cancelled", function()
		local store, clock = store_at()
		local work = store:start({ title = "Build Queue", tool = "Build Queue", tab = "t", cancel = function() end })
		work:progress(3, 12, "Building RomBuilder")
		store:start({ title = "Firmware flash", tool = "iLO Redfish", tab = "t" })
		clock.t = clock.t + 65
		local rows = ActivityPanel.rows(store, { can_show = always })
		assert.same({ "show" }, rows[1].actions)
		assert.equals("show", rows[1].action)
		assert.equals("iLO Redfish  |  Running", rows[1].secondary)
		assert.same({ "show", "cancel" }, rows[2].actions)
		assert.equals("cancel", rows[2].action)
		assert.equals("Build Queue 3 of 12", rows[2].title)
		assert.equals("Building RomBuilder", rows[2].secondary)
		assert.equals("1m 05s", rows[2].column1)
		assert.equals(0.25, rows[2].progress)
	end)

	it("offers no Show once the tab has gone", function()
		local store = store_at()
		store:start({ title = "x" })
		assert.same({}, ActivityPanel.rows(store, { can_show = function() return false end })[1].actions)
	end)

	it("freezes elapsed time and takes Cancel away once finished", function()
		local store, clock = store_at()
		local work = store:start({ title = "x", cancel = function() end })
		clock.t = clock.t + 5
		work:finish(false, "no share")
		clock.t = clock.t + 100
		local row = ActivityPanel.rows(store, { can_show = always })[1]
		assert.equals("5s", row.column1)
		assert.equals("no share", row.secondary)
		assert.same({ "show" }, row.actions)
		assert.is_nil(row.progress)
	end)

	it("takes Cancel away while a cancel is under way", function()
		local store = store_at()
		store:start({ title = "x", cancel = function() end }):cancel()
		local row = ActivityPanel.rows(store)[1]
		assert.equals("Cancelling...", row.secondary)
		assert.same({}, row.actions)
	end)

	it("hints only at keys that work on the row", function()
		assert.equals("Esc to close", ActivityPanel.hint(nil))
		assert.equals("Enter to show    Delete to cancel    Esc to close",
			ActivityPanel.hint({ actions = { "show", "cancel" } }))
	end)
end)

describe("ActivityPanel palette items", function()
	local function score(query, text)
		return text:lower():find(query:lower(), 1, true) and 1 or nil
	end

	it("filters by the query", function()
		local store = store_at()
		store:start({ title = "Build Queue" })
		store:start({ title = "Log Parser" })
		local items = ActivityPanel.commandItems(store, "log", { score = score, open = function() end })
		assert.equals(1, #items)
		assert.equals("Log Parser", items[1].title)
		assert.equals("Activity", items[1].group)
	end)

	it("shows the tool, or opens the panel when there is no tab to show", function()
		local store = store_at()
		store:start({ title = "x" })
		local shown, opened = 0, 0
		local function run(result)
			local items = ActivityPanel.commandItems(store, "", {
				score = function() return 1 end,
				open = function() opened = opened + 1 end,
				show = function() shown = shown + 1; return result end,
			})
			assert.is_true(items[1].run())
		end
		run(true)
		assert.equals(0, opened)
		run(false)
		assert.equals(1, opened)
		assert.equals(2, shown)
	end)

	it("adds a Cancel item only for what can be cancelled", function()
		local store = store_at()
		local stopped = 0
		store:start({ title = "Flash" })
		store:start({ title = "Scan", cancel = function() stopped = stopped + 1 end })
		local items = ActivityPanel.commandItems(store, "", {
			score = function() return 1 end, open = function() end,
		})
		assert.equals(3, #items)
		assert.equals("Cancel Scan", items[2].title)
		assert.is_true(items[2].run())
		assert.equals(1, stopped)
	end)
end)

describe("StatusBar activity slot", function()
	local function bar()
		local calls = { spin = 0, refresh = 0, glyph = nil }
		local box, text = { VISIBLE = "NO", FLOATING = "YES" }, {}
		local spinning = false
		local icon = {
			isSpinning = function() return spinning end,
			startSpin = function() spinning = true; calls.spin = calls.spin + 1 end,
			stopSpin = function(_, glyph) spinning = false; calls.glyph = glyph end,
		}
		local iup = {
			SetAttribute = function(w, k, v) w[k] = v end,
			Refresh = function() calls.refresh = calls.refresh + 1 end,
		}
		local sb = setmetatable({ _iup = iup, _activity_box = box, _activity_icon = icon,
			_activity_text = text }, StatusBar)
		return sb, box, text, calls
	end

	it("appears with work, spins once, and only lays out when it comes or goes", function()
		local sb, box, text, calls = bar()
		sb:setActivity({ state = "running", text = "Build 1 of 3", tip = "a" })
		sb:setActivity({ state = "running", text = "Build 2 of 3", tip = "a" })
		assert.equals("YES", box.VISIBLE)
		assert.equals("NO", box.FLOATING)
		assert.equals("Build 2 of 3", text.TITLE)
		assert.equals(1, calls.spin)
		assert.equals(1, calls.refresh)
		sb:setActivity(nil)
		assert.equals("NO", box.VISIBLE)
		assert.equals("YES", box.FLOATING)
		assert.equals(2, calls.refresh)
	end)

	it("settles on the state's glyph and keeps an ampersand literal", function()
		local sb, _, text, calls = bar()
		sb:setActivity({ state = "failed", text = "Upload & scan failed" })
		assert.equals("activity_failed", calls.glyph)
		assert.equals("Upload && scan failed", text.TITLE)
	end)
end)

describe("startJob and Activity", function()
	local function fake_iup()
		return setmetatable({ DEFAULT = -2, timer = function(t) return t end },
			{ __index = function() return function() end end })
	end

	-- A tool that reports the given lines, then exits.
	local function tool(lines, code)
		local i = 0
		return { spawn = function()
			return {
				read = function(_, stream)
					if stream ~= "stdout" then return nil end
					i = i + 1
					return lines[i]
				end,
				poll = function() return i >= #lines and (code or 0) or nil end,
				kill = function() i = #lines end,
				close = function() end,
			}
		end }
	end

	local RESULT = '{"v":1,"type":"result","ok":true,"summary":"All done"}\n'
	local function drain() for _ = 1, 6 do ProcessJob.tick() end end

	local function host_with_owner()
		local host = HostAPI:new({ iup = fake_iup() })
		local owner = { name = "Black Duck" }
		return host, host:activityStore(), owner
	end

	it("records a job by itself, with its progress and result", function()
		local host, store, owner = host_with_owner()
		assert(host:startJob({
			argv = { "C:\\tools\\bdscan.exe" },
			process = tool({ '{"v":1,"type":"progress","done":2,"total":4,"message":"Hashing"}\n', RESULT }),
		}, owner))
		assert.equals(1, count_entries(store))
		local item = store:list()[1]
		assert.equals("Black Duck", item.title)
		drain()
		assert.equals(2, item.done)
		assert.equals(4, item.total)
		assert.equals("ok", item.state)
		assert.equals("All done", item.summary)
	end)

	it("still hands events to the tool", function()
		local host, _, owner = host_with_owner()
		local seen = 0
		assert(host:startJob({
			argv = { "x" }, process = tool({ RESULT }),
			on_event = function() seen = seen + 1 end,
		}, owner))
		drain()
		assert.equals(1, seen)
	end)

	it("adds nothing when the tool won't start", function()
		local host, store, owner = host_with_owner()
		local job = host:startJob({
			argv = { "x" }, process = { spawn = function() return nil, "not found" end },
		}, owner)
		assert.is_nil(job)
		assert.equals(0, count_entries(store))
	end)

	it("adds nothing with activity = false", function()
		local host, store, owner = host_with_owner()
		assert(host:startJob({ argv = { "x" }, process = tool({ RESULT }), activity = false }, owner))
		drain()
		assert.equals(0, count_entries(store))
	end)

	it("offers Cancel only when asked to", function()
		local host, store, owner = host_with_owner()
		assert(host:startJob({ argv = { "x" }, process = tool({ "" }) }, owner))
		assert.is_nil(store:list()[1].cancel)
		local job = assert(host:startJob({
			argv = { "x" }, process = tool({ "" }), activity = { title = "Scan", cancel = true },
		}, owner))
		local item = store:list()[1]
		assert.equals("Scan", item.title)
		assert.is_function(item.cancel)
		spy.on(job, "cancel")
		store:cancel(item.id)
		assert.spy(job.cancel).was.called(1)
		host:removeOwned(owner)
	end)

	it("reports a job the user cancelled as cancelled", function()
		local host, store, owner = host_with_owner()
		assert(host:startJob({
			argv = { "x" }, process = tool({ "", "", "", "", "", "", "" }, 1),
			activity = { cancel = true },
		}, owner))
		store:cancel(store:list()[1].id)
		drain()
		assert.equals("cancelled", store:list()[1].state)
	end)

	it("makes no second entry for a job inside the owner's own activity", function()
		local host, store, owner = host_with_owner()
		local work = host:activity({ title = "Release scan" }, owner)
		assert(host:startJob({
			argv = { "x" },
			process = tool({ '{"v":1,"type":"progress","done":1,"total":2}\n', RESULT }),
		}, owner))
		assert.equals(1, count_entries(store))
		drain()
		local item = store:list()[1]
		assert.equals(1, item.done)
		-- Ending it stays with whoever opened it: a pipeline may have more steps.
		assert.equals("running", item.state)
		work:finish(true)
		assert.equals("ok", item.state)
	end)

	it("reports into a handle passed in", function()
		local host, store, owner = host_with_owner()
		local work = host:activity({ title = "Mine" }, {})
		assert(host:startJob({
			argv = { "x" }, process = tool({ RESULT }), activity = work,
		}, owner))
		assert.equals(1, count_entries(store))
	end)

	it("doesn't join an entry a job recorded for itself", function()
		local host, store, owner = host_with_owner()
		assert(host:startJob({ argv = { "x" }, process = tool({ "" }) }, owner))
		assert(host:startJob({ argv = { "y" }, process = tool({ "" }) }, owner))
		assert.equals(2, count_entries(store))
		host:removeOwned(owner)
	end)

	it("doesn't join another owner's activity", function()
		local host, store, owner = host_with_owner()
		host:activity({ title = "Theirs" }, { name = "Other" })
		assert(host:startJob({ argv = { "x" }, process = tool({ RESULT }) }, owner))
		assert.equals(2, count_entries(store))
	end)

	it("ends an unloading owner's entries, which a late exit doesn't disturb", function()
		local host, store, owner = host_with_owner()
		assert(host:startJob({ argv = { "x" }, process = tool({ "" }, 1) }, owner))
		host:removeOwned(owner)
		local item = store:list()[1]
		assert.equals("cancelled", item.state)
		drain()
		assert.equals("cancelled", item.state)
		assert.equals(0, store:unviewed())
	end)
end)

describe("Activity toasts", function()
	-- A host with two tabs, `hosttab1` in front and `hosttab2` behind.
	local function host_with_tabs()
		local attrs = {}
		local iup = setmetatable({
			DEFAULT = -2,
			timer = function(t) return t end,
			GetAttribute = function(w) return attrs[w] end,
		}, { __index = function() return function() end end })
		local toasts = {}
		local front, behind = {}, {}
		attrs[front], attrs[behind] = "hosttab1", "hosttab2"
		local host = HostAPI:new({ iup = iup, tabs = {} })
		local shown
		host._tab_groups = {
			activeLeaf = function() return front end,
			frontPages = function() return { front } end,
			leaves = function() return { front, behind } end,
			reveal = function(_, page) shown = page; return true end,
		}
		host._toasts = { show = function(_, spec) toasts[#toasts + 1] = spec end, dismissOwned = function() end }
		local here, there = { name = "Here" }, { name = "There" }
		host._owner_by_tab = { hosttab1 = here, hosttab2 = there }
		return host, here, there, toasts, function() return shown end, behind, front, attrs
	end

	it("stays quiet when the job's tab is in front, and counts it as seen", function()
		local host, here, _, toasts = host_with_tabs()
		host:activity({ title = "Scan" }, here):finish(false, "no share")
		assert.equals(0, #toasts)
		assert.equals(0, host:activityStore():unviewed())
	end)

	it("toasts a job that ends behind the tab in front", function()
		local host, _, there, toasts = host_with_tabs()
		host:activity({ title = "Scan" }, there):finish(true, "12 files")
		assert.equals(1, #toasts)
		assert.equals("Scan finished", toasts[1].title)
		assert.equals("12 files", toasts[1].body)
		assert.equals("success", toasts[1].kind)
		assert.equals(there, toasts[1].owner)
	end)

	it("toasts a background failure and leaves it to be seen", function()
		local host, _, there, toasts = host_with_tabs()
		host:activity({ title = "Scan" }, there):finish(false, "no share")
		assert.equals("error", toasts[1].kind)
		assert.equals(1, host:activityStore():unviewed())
	end)

	it("doesn't toast what the user cancelled, or an unload", function()
		local host, _, there, toasts = host_with_tabs()
		host:activity({ title = "Scan" }, there):finish("cancelled")
		host:activity({ title = "Upload" }, there)
		host:removeOwned(there)
		assert.equals(0, #toasts)
	end)

	it("clears the dot when the failed tool's tab comes to the front", function()
		local host, _, there, _, _, _, _, attrs = host_with_tabs()
		host:activity({ title = "Scan" }, there):finish(false)
		assert.equals(1, host:activityStore():unviewed())
		host:_activityTabsViewed()
		assert.equals(1, host:activityStore():unviewed())
		for page, id in pairs(attrs) do attrs[page] = id == "hosttab1" and "hosttab2" or "hosttab1" end
		host:_activityTabsViewed()
		assert.equals(0, host:activityStore():unviewed())
	end)

	it("reveals the entry's tab, and can't once it has gone", function()
		local host, _, there, _, shown, behind = host_with_tabs()
		host:activity({ title = "Scan" }, there)
		local item = host:activityStore():list()[1]
		assert.is_true(host:canRevealActivity(item))
		assert.is_true(host:revealActivity(item))
		assert.equals(behind, shown())
		host._owner_by_tab.hosttab2 = nil
		assert.is_false(host:canRevealActivity(item))
		assert.is_false(host:revealActivity(item))
	end)

	it("files work under the front tab when the owner is that tab's", function()
		local host, here = host_with_tabs()
		host:activity({ title = "Scan" }, here)
		assert.equals("hosttab1", host:activityStore():list()[1].tab)
	end)

	it("takes the owner from the tab in front when none is passed", function()
		local host = host_with_tabs()
		host:activity({ title = "Scan" })
		local item = host:activityStore():list()[1]
		assert.equals("Here", item.tool)
		assert.equals("hosttab1", item.tab)
	end)

	it("leaves owner-less work without a tab, and toasts it", function()
		local host, _, _, toasts = host_with_tabs()
		host:activity({ title = "Rebuild", tool = "Tasks" }, false):finish(true)
		assert.is_nil(host:activityStore():list()[1].tab)
		assert.equals(1, #toasts)
	end)
end)

describe("TaskRunner and Activity", function()
	local function harness(exit)
		local pending
		local recorded = {}
		local killed = false
		local runner = TaskRunner:new({
			spawn = function()
				return {
					read = function() end,
					poll = function()
						if killed then return 1 end
						return exit
					end,
					kill = function() killed = true end,
					close = function() end,
				}
			end,
			status = function() end,
			after = function(_, fn) pending = fn end,
			activity = function(spec, owner)
				recorded.spec, recorded.owner = spec, owner
				recorded.finish = {}
				return { finish = function(_, ok, summary) recorded.finish = { ok = ok, summary = summary } end }
			end,
		})
		return runner, recorded, function() pending() end
	end

	it("records a task under no tool tab, and its result", function()
		local runner, recorded, step = harness(0)
		runner:run({ label = "Build", argv = { "make" } })
		assert.equals("Build", recorded.spec.title)
		assert.is_false(recorded.owner)
		step()
		assert.is_true(recorded.finish.ok)
	end)

	it("reports a failing exit code", function()
		local runner, recorded, step = harness(2)
		runner:run({ label = "Build", argv = { "make" } })
		step()
		assert.is_false(recorded.finish.ok)
		assert.equals("Exited with code 2", recorded.finish.summary)
	end)

	it("cancels by ending the process, and says cancelled", function()
		local runner, recorded, step = harness(nil)
		runner:run({ label = "Build", argv = { "make" } })
		recorded.spec.cancel()
		step()
		assert.equals("cancelled", recorded.finish.ok)
		assert.is_false(runner:isRunning("Build"))
	end)
end)
