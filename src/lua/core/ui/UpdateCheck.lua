--- Discover published GitHub releases, offer an update, and stage it before exit.
-- Checks run on the cooperative network scheduler. Downloads run as host-owned
-- jobs and must pass SHA-256 verification before the installer is launched.
-- @classmod core.ui.UpdateCheck
local Updater = require("core.lib.Updater")
local UpdateCheck = {}
UpdateCheck.__index = UpdateCheck
UpdateCheck.POLL_INTERVAL = 6 * 60 * 60 * 1000

--- Construct with IUP, host, status_bar, app_title, app_version, installed,
-- platform and launch. Tests may inject request, download, open_release and exit.
function UpdateCheck.new(opts)
	return setmetatable({ _o = opts, _exit = opts.exit or function() os.exit(0) end,
		_checking = false, _downloading = false, _announced = false }, UpdateCheck)
end

--- Attach the update icon and periodic background check.
function UpdateCheck:install()
	local o, sb = self._o, self._o.status_bar
	o.host:addStatusElement(sb:updateIcon():widget(), {
		persistent = true, position = 1, padding = 0,
		tooltip = "Check GitHub for Lunar updates",
		on_click = function() self:checkNow() end,
	})
	if o.iup.timer then
		local check = self
		self._poll_timer = o.iup.timer({ time = UpdateCheck.POLL_INTERVAL })
		function self._poll_timer:action_cb() check:startup(); return o.iup.DEFAULT end
		self._poll_timer.run = "YES"
	end
end

--- Discover updates inside the host's network scheduler.
function UpdateCheck:check()
	local o = self._o
	return Updater.check({ app_version = o.app_version, installed = o.installed and o.installed() or {},
		platform = o.platform, request = o.request })
end

function UpdateCheck:_message(text)
	self._o.iup.Message(self._o.app_title, text)
end

function UpdateCheck:_launch(path)
	local called, ok, err = pcall(self._o.launch, path)
	if not called then err, ok = ok, nil end
	if not ok then
		self:_message("Unable to launch the update installer.\n\n" .. tostring(err))
		return
	end
	-- The verified MSI is staged locally; the detached installer waits for this
	-- process to leave before upgrading and reopening Lunar.
	self._exit()
end

function UpdateCheck:_offer(result)
	local o = self._o
	local lines = {}
	if result.app_update then
		lines[#lines + 1] = string.format("Lunar: %s -> %s", o.app_version, result.latest)
	end
	if #result.extensions > 0 then
		lines[#lines + 1] = "Extensions:"
		for _, line in ipairs(result.extensions) do lines[#lines + 1] = "  - " .. line end
	end
	local windows = not o.platform or o.platform == "windows"
	local action = windows and "Download and Install" or "Open Downloads"
	local answer = o.iup.Alarm(o.app_title,
		"A published GitHub release is available.\n\n" .. table.concat(lines, "\n")
			.. (windows and "\n\nDownload, verify and install it now?" or "\n\nOpen the release downloads to update your installation?"),
		action, "Later")
	if answer ~= 1 then return end
	if not windows then
		local open = o.open_release or require("core.platform").open
		local ok, err = open(result.release_url)
		if not ok then self:_message("Unable to open the release downloads.\n\n" .. tostring(err)) end
		return
	end
	if self._staged and self._staged.version == result.latest then return self:_launch(self._staged.path) end
	self._downloading = true
	o.status_bar:startUpdateSpin()
	o.status_bar:setUpdateState("checking", "Downloading and verifying Lunar " .. result.latest)
	local finished = false
	local function done(path, err)
		if finished then return end
		finished, self._downloading = true, false
		o.status_bar:stopUpdateSpin()
		if not path then
			o.status_bar:setUpdateState("available")
			if err == "Cancelled" then return end
			self:_message("The update could not be downloaded and verified. Lunar will stay open.\n\n" .. tostring(err)
				.. "\n\nRelease downloads: " .. result.release_url)
			return
		end
		self._staged = { version = result.latest, path = path }
		o.status_bar:setUpdateState("ready")
		self:_launch(path)
	end
	local download = o.download or function(installer, callback)
		return require("core.lib.UpdateDownload").start({ host = o.host, installer = installer }, callback)
	end
	local called, job, err = pcall(download, result.installer, done)
	if not called then done(nil, job)
	elseif not job and not finished then done(nil, err) end
end

function UpdateCheck:_settle(ok, result, offer)
	local o = self._o
	if not ok or type(result) ~= "table" then result = { status = "unavailable", error = tostring(result) } end
	self._checking = false
	o.status_bar:stopUpdateSpin()
	local tooltip = result.error and ("Could not check GitHub for updates\n" .. result.error) or nil
	o.status_bar:setUpdateState(result.status, tooltip)
	if result.status == "available" then
		if not self._announced then
			self._announced = true
			pcall(function() o.host:notify({ title = "Update available", kind = "info",
				body = "Lunar " .. result.latest .. " is available on GitHub. Click the update icon to update." }) end)
		end
		if offer then self:_offer(result) end
	end
end

function UpdateCheck:_begin(offer)
	if self._checking or self._downloading then return end
	self._checking = true
	local o = self._o
	o.status_bar:setUpdateState("checking")
	if offer then o.status_bar:startUpdateSpin() end
	local function run()
		o.host:runAsync(function() return self:check() end, function(ok, result) self:_settle(ok, result, offer) end)
	end
	-- Give the requested check's spinner a frame before starting network work.
	if offer and o.iup.timer then
		if not self._timer then
			local check = self
			self._timer = o.iup.timer({ time = 150 })
			function self._timer:action_cb() self.run = "NO"; check._run(); return o.iup.DEFAULT end
		end
		self._run = run
		self._timer.run = "YES"
	else
		run()
	end
end

--- Startup and periodic checks announce availability without opening a dialog.
function UpdateCheck:startup() self:_begin(false) end
--- A check requested from the status icon or Check for Updates command.
function UpdateCheck:checkNow() self:_begin(true) end
return UpdateCheck
