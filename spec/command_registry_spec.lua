local CommandRegistry = require("core.classes.CommandRegistry")

describe("CommandRegistry", function()
	local function noop() return true end

	describe("score", function()
		it("matches characters in order, ignoring case", function()
			assert.is_number(CommandRegistry.score("cfu", "Check for Updates"))
			assert.is_nil(CommandRegistry.score("ufc", "Check for Updates"))
		end)

		it("ranks a prefix above a scattered match", function()
			assert.is_true(CommandRegistry.score("set", "Settings")
				> CommandRegistry.score("set", "Reset Tabs"))
		end)
	end)

	it("recognises a lunar address", function()
		assert.is_true(CommandRegistry.isAddress("lunar://host/settings"))
		assert.is_true(CommandRegistry.isAddress("  lunar:"))
		assert.is_false(CommandRegistry.isAddress("settings"))
	end)

	it("refuses a command without a title or a function", function()
		local registry = CommandRegistry:new()
		assert.is_nil(registry:register({ title = "x" }))
		assert.is_nil(registry:register({ run = noop }))
	end)

	it("replaces a command registered twice under one id", function()
		local registry = CommandRegistry:new()
		registry:register({ id = "a", title = "One", run = noop })
		registry:register({ id = "a", title = "Two", run = noop })
		assert.equals(1, #registry:commands())
		assert.equals("Two", registry:commands()[1].title)
	end)

	it("offers to open a lunar address instead of searching", function()
		local opened
		local registry = CommandRegistry:new({ open_address = function(uri) opened = uri return true end })
		registry:register({ title = "lunar stuff", run = noop })
		local items = registry:query("lunar://host/settings")
		assert.equals(1, #items)
		assert.is_true((registry:run(items[1])))
		assert.equals("lunar://host/settings", opened)
	end)

	it("reports a failed address with its message", function()
		local registry = CommandRegistry:new({ open_address = function() return nil, "no such route" end })
		local ok, message = registry:run(registry:query("lunar://nope")[1])
		assert.is_false(ok)
		assert.equals("no such route", message)
	end)

	it("hides a command while its when returns false", function()
		local registry = CommandRegistry:new()
		local shown = false
		registry:register({ title = "Sometimes", run = noop, when = function() return shown end })
		assert.equals(0, #registry:query(""))
		shown = true
		assert.equals(1, #registry:query(""))
	end)

	it("searches keywords as well as titles", function()
		local registry = CommandRegistry:new()
		registry:register({ title = "Open Settings", keywords = "preferences", run = noop })
		assert.equals("Open Settings", registry:query("prefer")[1].title)
	end)

	it("includes the items of a provider in a search", function()
		local registry = CommandRegistry:new()
		registry:addProvider({ id = "tabs", items = function()
			return { { title = "Log Parser", category = "Go to", run = noop } }
		end })
		assert.equals("Log Parser", registry:query("log")[1].title)
	end)

	it("gives a prefix to its provider alone, with the rest of the text", function()
		local registry = CommandRegistry:new()
		local asked
		registry:register({ title = "task runner", run = noop })
		local tasks = registry:addProvider({ id = "tasks", prefix = "task ", items = function(query)
			asked = query
			return { { title = "build", run = noop } }
		end })
		local items, provider = registry:query("task bui")
		assert.equals("bui", asked)
		assert.equals(1, #items)
		assert.equals("build", items[1].title)
		assert.equals(tasks, provider)
	end)

	it("survives a provider that errors", function()
		local registry = CommandRegistry:new()
		registry:addProvider({ id = "bad", items = function() error("boom") end })
		registry:register({ title = "Fine", run = noop })
		assert.equals(1, #registry:query("fine"))
	end)

	it("removes what an owner added", function()
		local registry = CommandRegistry:new()
		local owner = {}
		registry:register({ title = "Mine", run = noop }, owner)
		registry:addProvider({ id = "p", items = function() return {} end }, owner)
		registry:register({ title = "Theirs", run = noop })
		registry:removeOwned(owner)
		assert.equals(1, #registry:commands())
		assert.equals("Theirs", registry:commands()[1].title)
		assert.equals(1, #registry:query("theirs"))
	end)

	it("lists recently run commands first and keeps the list short", function()
		local store = {}
		local settings = {
			get = function(_, key) return store[key] end,
			set = function(_, key, value) store[key] = value end,
			save = function() end,
		}
		local registry = CommandRegistry:new({ settings = settings })
		for i = 1, 7 do registry:register({ id = "c" .. i, title = "C" .. i, run = noop }) end
		for i = 1, 7 do registry:run(registry:commands()[i]) end
		assert.equals(5, #store.command_recent)
		assert.equals("c7", registry:query("")[1].id)
	end)

	it("turns an error in a command into a message", function()
		local registry = CommandRegistry:new()
		local item = registry:register({ title = "Bad", run = function() error("boom") end })
		local ok, message = registry:run(item)
		assert.is_false(ok)
		assert.matches("boom", message)
	end)
end)
