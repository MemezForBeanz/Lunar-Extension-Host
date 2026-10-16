local cjson = require("cjson")
local UpdateCheck = require("core.ui.UpdateCheck")

local ROOT = "\\\\files.example\\lunar"

local function setup(opts)
	opts = opts or {}
	local log = { states = {}, toasts = 0, launched = nil, exited = false, messages = {} }
	local files = {
		[ROOT .. "\\manifest.json"] = cjson.encode({ latest = opts.latest or "2.0.0" }),
	}
	local check = UpdateCheck.new({
		iup = {
			Alarm = function() return opts.answer or 2 end,
			Message = function(_, text) log.messages[#log.messages + 1] = text end,
		},
		host = {
			-- The scheduler, run synchronously.
			runAsync = function(_, fn, cb) cb(pcall(fn)) end,
			notify = function() log.toasts = log.toasts + 1 end,
		},
		status_bar = {
			setUpdateState = function(_, s) log.states[#log.states + 1] = s end,
			startUpdateSpin = function() log.spun = true end,
			stopUpdateSpin = function() log.stopped = true end,
		},
		root = ROOT,
		app_title = "Lunar",
		app_version = "1.9.8",
		installed = function() return {} end,
		read = function(path) return files[path] end,
		reachable = function() return opts.reachable ~= false end,
		launch = function(msi)
			log.launched = msi
			if opts.launch_fails then return nil, "denied" end
			return true
		end,
		exit = function() log.exited = true end,
	})
	return check, log
end

describe("UpdateCheck", function()
	it("shows checking, then unavailable when the share can't be reached", function()
		local check, log = setup({ reachable = false })
		check:startup()
		assert.are.same({ "checking", "unavailable" }, log.states)
		assert.are.equal(0, log.toasts)
	end)

	it("is current when nothing is newer", function()
		local check, log = setup({ latest = "1.9.8" })
		check:startup()
		assert.are.same({ "checking", "current" }, log.states)
	end)

	it("announces an available update once, however often it checks", function()
		local check, log = setup()
		check:startup()
		check:checkNow()
		assert.are.equal("available", log.states[#log.states])
		assert.are.equal(1, log.toasts)
		assert.is_true(log.spun and log.stopped)
		assert.is_nil(log.launched)
	end)

	it("installs the versioned MSI and exits when the user agrees", function()
		local check, log = setup({ answer = 1 })
		check:startup()
		assert.are.equal(ROOT .. "\\releases\\2.0.0\\LunarExtensionHost-2.0.0.msi", log.launched)
		assert.is_true(log.exited)
	end)

	it("stays open and says why when the relauncher can't start", function()
		local check, log = setup({ answer = 1, launch_fails = true })
		check:startup()
		assert.is_false(log.exited)
		assert.truthy(log.messages[1]:find("denied", 1, true))
		assert.are.equal("available", log.states[#log.states])
	end)
end)
