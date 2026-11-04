local TaskRunner = require("core.classes.TaskRunner")

describe("TaskRunner", function()
	local function harness(exit_codes)
		local statuses, later = {}, {}
		local spawned = 0
		local proc = {
			read = function() end,
			poll = function() return table.remove(exit_codes, 1) end,
			close = function() end,
		}
		local runner = TaskRunner:new({
			spawn = function() spawned = spawned + 1 return proc end,
			status = function(message) statuses[#statuses + 1] = message end,
			after = function(_, fn) later[#later + 1] = fn end,
		})
		local function step() table.remove(later, 1)() end
		return runner, statuses, step, function() return spawned end
	end

	describe("parse", function()
		local function decode(doc) return function() return doc end end

		it("keeps valid tasks", function()
			local tasks, problems = TaskRunner.parse("", decode({
				tasks = { { label = "Build", command = { "make" }, cwd = "src" } },
			}))
			assert.equals("Build", tasks[1].label)
			assert.same({ "make" }, tasks[1].argv)
			assert.equals(0, #problems)
		end)

		it("refuses a shell string, and says which task", function()
			local tasks, problems = TaskRunner.parse("", decode({
				tasks = { { label = "Build", command = "make all" } },
			}))
			assert.equals(0, #tasks)
			assert.matches("Build", problems[1])
		end)

		it("reports a document of the wrong shape", function()
			local tasks, problems = TaskRunner.parse("", decode({ nope = true }))
			assert.equals(0, #tasks)
			assert.equals(1, #problems)
		end)

		it("survives a decoder that throws", function()
			local _, problems = TaskRunner.parse("", function() error("bad json") end)
			assert.equals(1, #problems)
		end)
	end)

	it("runs until the process exits and reports success", function()
		local runner, statuses, step = harness({ 0 })
		assert.is_true((runner:run({ label = "Build", argv = { "make" } })))
		assert.is_true(runner:isRunning("Build"))
		step()
		assert.is_false(runner:isRunning("Build"))
		assert.equals("Build: finished", statuses[#statuses])
	end)

	it("reports a failing exit code", function()
		local runner, statuses, step = harness({ 2 })
		runner:run({ label = "Build", argv = { "make" } })
		step()
		assert.equals("Build: failed (exit 2)", statuses[#statuses])
	end)

	it("refuses to start a task that is still running", function()
		local runner, _, _, spawned = harness({})
		runner:run({ label = "Build", argv = { "make" } })
		local ok, message = runner:run({ label = "Build", argv = { "make" } })
		assert.is_false(ok)
		assert.matches("already running", message)
		assert.equals(1, spawned())
	end)

	it("says why a task could not start", function()
		local runner = TaskRunner:new({
			spawn = function() return nil, "no such file" end,
			status = function() end, after = function() end,
		})
		local ok, message = runner:run({ label = "Build", argv = { "make" } })
		assert.is_false(ok)
		assert.matches("no such file", message)
	end)

	it("lists user tasks before extension tasks and removes an owner's", function()
		local owner = {}
		local runner = TaskRunner:new({
			spawn = function() end, status = function() end, after = function() end,
			load = function() return { { label = "Mine", argv = { "a" } } } end,
		})
		runner:add({ label = "Theirs", argv = { "b" } }, owner)
		local list = runner:list()
		assert.equals("Mine", list[1].label)
		assert.equals("Theirs", list[2].label)
		runner:removeOwned(owner)
		assert.equals(1, #runner:list())
	end)
end)
