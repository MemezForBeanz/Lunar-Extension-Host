local cjson = require("cjson")
local UpdateCheck = require("core.ui.UpdateCheck")
local Updater = require("core.lib.Updater")

local function setup(opts)
	opts = opts or {}
	local log = { states = {}, toasts = 0, messages = {}, prompts = 0, downloads = 0, requests = 0 }
	local iup = {
		Alarm = function() log.prompts = log.prompts + 1; return opts.answer or 2 end,
		Message = function(_, text) log.messages[#log.messages + 1] = text end,
	}
	local host = {
		runAsync = function(_, fn, cb)
			if opts.defer then log.run = function() cb(pcall(fn)) end else cb(pcall(fn)) end
		end,
		notify = function() log.toasts = log.toasts + 1 end,
		addStatusElement = function(_, _, spec) log.icon_click = spec.on_click end,
	}
	local bar = {
		setUpdateState = function(_, state, tip) log.states[#log.states + 1] = state; log.tip = tip end,
		startUpdateSpin = function() log.spinning = true end,
		stopUpdateSpin = function() log.spinning = false end,
		updateIcon = function() return { widget = function() return {} end } end,
	}
	local latest = opts.latest or "2.0.0"
	local check = UpdateCheck.new({ iup = iup, host = host, status_bar = bar, platform = opts.platform or "windows",
		app_title = "Lunar", app_version = "1.9.8", installed = function() return {} end,
		request = function(req)
			log.requests = log.requests + 1
			if opts.unreachable then return nil, "offline" end
			if req.url == Updater.LATEST_METADATA then
				return { status = 200, body = cjson.encode({ version = latest, msi = "LunarExtensionHost-" .. latest .. ".msi" }) }
			end
			return { status = 200, body = string.rep("a", 64) .. "  LunarExtensionHost-" .. latest .. ".msi\n" }
		end,
		download = function(asset, done)
			log.downloads = log.downloads + 1
			if opts.download_throws then error("downloader exception") end
			log.asset = asset
			if opts.start_fails then return nil, "Could not start downloader" end
			log.download_done = done
			if not opts.defer_download then
				if opts.download_fails then done(nil, "SHA-256 mismatch") else done("C:\\cache\\update.msi") end
			end
			return {}
		end,
		launch = function(path)
			log.launched = path
			if opts.launch_fails then return nil, "denied" end
			return true
		end,
		open_release = function(url) log.opened = url; return true end,
		exit = function() log.exited = true end,
	})
	return check, log, iup
end

describe("UpdateCheck", function()
	it("reports unreachable GitHub with a useful tooltip", function()
		local check, log = setup({ unreachable = true })
		check:startup()
		assert.same({ "checking", "unavailable" }, log.states)
		assert.truthy(log.tip:find("offline", 1, true))
		assert.equal(0, log.toasts)
	end)
	it("is current when no published release is newer", function()
		local check, log = setup({ latest = "1.9.8" })
		check:startup()
		assert.same({ "checking", "current" }, log.states)
	end)
	it("announces once without prompting or downloading during background checks", function()
		local check, log = setup({ answer = 1 })
		check:startup(); check:startup()
		assert.equal(1, log.toasts)
		assert.equal(0, log.prompts)
		assert.equal(0, log.downloads)
	end)
	it("waits for explicit approval before downloading", function()
		local check, log = setup()
		check:checkNow()
		assert.equal(1, log.prompts)
		assert.equal(0, log.downloads)
		assert.is_nil(log.launched)
	end)
	it("only launches and exits after the staged installer has been verified", function()
		local check, log = setup({ answer = 1, defer_download = true })
		check:checkNow()
		assert.equal(1, log.downloads)
		assert.is_nil(log.launched)
		assert.is_nil(log.exited)
		assert.is_true(log.spinning)
		log.download_done("C:\\cache\\verified.msi")
		assert.equal("C:\\cache\\verified.msi", log.launched)
		assert.is_true(log.exited)
		assert.is_false(log.spinning)
		assert.equal("ready", log.states[#log.states])
	end)
	it("keeps Lunar open on checksum or download failure", function()
		local check, log = setup({ answer = 1, download_fails = true })
		check:checkNow()
		assert.is_nil(log.launched)
		assert.is_nil(log.exited)
		assert.equal("available", log.states[#log.states])
		assert.truthy(log.messages[1]:find("SHA-256 mismatch", 1, true))
	end)
	it("clears the busy state when the downloader cannot start", function()
		local check, log = setup({ answer = 1, start_fails = true })
		check:checkNow()
		assert.is_false(check._downloading)
		assert.is_false(log.spinning)
		assert.is_nil(log.exited)
	end)
	it("recovers if preparing a download throws", function()
		local check, log = setup({ answer = 1, download_throws = true })
		check:checkNow()
		assert.is_false(check._downloading)
		assert.is_false(log.spinning)
		assert.is_nil(log.exited)
		assert.truthy(log.messages[1]:find("downloader exception", 1, true))
	end)
	it("returns to available without an error dialog after cancellation", function()
		local check, log = setup({ answer = 1, defer_download = true })
		check:checkNow()
		log.download_done(nil, "Cancelled")
		assert.is_nil(log.launched)
		assert.is_nil(log.exited)
		assert.is_false(check._downloading)
		assert.equal(0, #log.messages)
		assert.equal("available", log.states[#log.states])
	end)
	it("keeps a verified download for retry if the relauncher cannot start", function()
		local check, log = setup({ answer = 1, launch_fails = true })
		check:checkNow(); check:checkNow()
		assert.equal(1, log.downloads)
		assert.is_nil(log.exited)
		assert.truthy(log.messages[1]:find("denied", 1, true))
	end)
	it("prevents overlapping checks and checks during downloads", function()
		local check, log = setup({ defer = true, answer = 1, defer_download = true })
		check:checkNow(); check:checkNow()
		assert.is_true(check._checking)
		log.run()
		local requests = log.requests
		check:checkNow(); check:startup()
		assert.equal(requests, log.requests)
		assert.equal(1, log.downloads)
	end)
	it("opens package downloads on Linux and leaves Lunar running", function()
		local check, log = setup({ answer = 1, platform = "linux" })
		check:checkNow()
		assert.equal(Updater.RELEASES .. "/tag/v2.0.0", log.opened)
		assert.equal(0, log.downloads)
		assert.is_nil(log.exited)
	end)
	it("wires the icon and repeats background checks every six hours", function()
		local check, log, iup = setup()
		local timers = {}
		function iup.timer(spec) timers[#timers + 1] = spec; return spec end
		check:install()
		assert.equal(21600000, timers[1].time)
		timers[1]:action_cb()
		assert.equal(0, log.prompts)
		log.icon_click()
		timers[2]:action_cb()
		assert.equal(1, log.prompts)
	end)
end)
