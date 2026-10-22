--- Headless Lunar: the extension host without a window.
--
-- Loads the same extensions the desktop app does (the built-in folder, then the
-- selected org pack's `extensions/`), but only those whose manifest lists the
-- `headless` mode, and runs them on a `core.lib.EventLoop` instead of IUP. It is
-- what runs on a server: an extension adds timers, jobs, HTTP calls and, later,
-- HTTP routes, and the loop drives them until the process is told to stop.
--
--     lunar-cli --headless [--pack ID] [--dev] [--extensions DIR]...
--                          [--until-idle] [--for SECONDS] [--log-level LEVEL]
--
-- `--pack ID` must name an installed, trusted org pack, unless `--dev` is given;
-- `--dev` also accepts `--extensions DIR` (an extra extension folder, for
-- developing an extension without installing it). Without `--pack` the profile
-- is chosen the way the desktop app chooses it.
--
-- Stopping: the C launcher turns SIGTERM / SIGINT (Ctrl+C, a console close on
-- Windows) into `LUNAR_STOP_REQUESTED()`; the loop checks it every turn, then
-- every extension's `shutdown()` runs and its timers and jobs are cleaned up.
--
-- @module core.headless

local M = {}

M.USAGE = [[
usage: lunar-cli --headless [options]

  --pack ID          use the org pack ID (must be installed and trusted unless --dev)
  --dev              development mode: allow untrusted packs and --extensions
  --extensions DIR   also load extensions from DIR (with --dev; repeatable)
  --until-idle       exit once no timer, job or request is left (tests, one-shot runs)
  --for SECONDS      exit after SECONDS
  --log-level LEVEL  DEBUG, INFO (default), WARN or ERROR
  --help             show this help
]]

--- Parse the arguments after `--headless`.
-- @tparam table argv list of strings
-- @treturn[1] table options
-- @treturn[2] nil
-- @treturn[2] string error
function M.parse_args(argv)
	local opts = { extensions = {}, log_level = "INFO" }
	local i = 1
	local function value(flag)
		i = i + 1
		local v = argv[i]
		if v == nil or v:sub(1, 2) == "--" then return nil, flag .. " needs a value" end
		return v
	end
	while argv[i] ~= nil do
		local a = argv[i]
		local v, err
		if a == "--pack" then
			v, err = value(a); opts.pack = v
		elseif a == "--dev" then
			opts.dev = true
		elseif a == "--extensions" then
			v, err = value(a); opts.extensions[#opts.extensions + 1] = v
		elseif a == "--until-idle" then
			opts.until_idle = true
		elseif a == "--for" then
			v, err = value(a)
			opts.seconds = tonumber(v)
			if v and (not opts.seconds or opts.seconds <= 0) then err = "--for needs a number of seconds" end
		elseif a == "--log-level" then
			v, err = value(a)
			opts.log_level = v and v:upper()
			if v and not ({ DEBUG = 1, INFO = 1, WARN = 1, ERROR = 1 })[opts.log_level] then
				err = "--log-level must be DEBUG, INFO, WARN or ERROR"
			end
		elseif a == "--help" or a == "-h" then
			opts.help = true
		else
			err = "unknown option " .. a
		end
		if err then return nil, err end
		i = i + 1
	end
	if #opts.extensions > 0 and not opts.dev then
		return nil, "--extensions needs --dev"
	end
	return opts
end

-- The folder holding the executable (set by the C launcher), else the cwd.
local function app_dir()
	if type(LUNAR_EXE_DIR) == "string" and LUNAR_EXE_DIR ~= "" then return LUNAR_EXE_DIR end
	return require("lfs").currentdir()
end

--- Pick the org profile the way the desktop app does; `--pack` must match it.
-- @local
function M.resolve_profile(opts, resolve)
	resolve = resolve or require("core.lib.OrgProfile").resolve
	local ok, profile, info = pcall(resolve, { dev_select = opts.dev and opts.pack or nil })
	if not ok then return nil, "org profile: " .. tostring(profile) end
	if opts.pack then
		if not profile or profile.id ~= opts.pack then
			local why = info and info.errors and info.errors[1]
			return nil, "org pack '" .. opts.pack .. "' is not installed"
				.. (opts.dev and "" or " in a trusted location (or use --dev)")
				.. (why and (": " .. why) or "")
		end
		if not profile.trusted and not opts.dev then
			return nil, "org pack '" .. opts.pack .. "' is not trusted (install it for all users, or use --dev)"
		end
	end
	return profile or false, info
end

--- Extension roots: the built-in folder, the trusted (or --dev) pack, --extensions.
-- @local
function M.extension_roots(dir, profile, opts)
	local path = require("core.platform").path
	local roots = { { dir = path:join(dir, "plugins"), source = "built-in" } }
	if profile and (profile.trusted or opts.dev) then
		roots[#roots + 1] = { dir = path:join(profile.dir, "extensions"), source = "org:" .. profile.id }
	end
	for _, extra in ipairs(opts.extensions or {}) do
		roots[#roots + 1] = { dir = extra, source = "dev:" .. extra }
	end
	return roots
end

--- Build the host: settings, event loop, HostAPI, extensions loaded and ready.
-- @tparam table opts parsed options (plus, for tests, `profile`, `roots`, `loop`)
-- @treturn[1] table `{ host, extensions, loop, profile, log }`
-- @treturn[2] nil
-- @treturn[2] string error
function M.boot(opts)
	local log = require("core.lib.log")
	log.configure({ level = opts.log_level or "INFO" })
	local hlog = log.get("headless")

	local profile, info = opts.profile, nil
	if profile == nil then
		profile, info = M.resolve_profile(opts)
		if profile == nil then return nil, info end
	end
	profile = profile or nil
	if profile then
		hlog:info(string.format("org pack %s (%s)", profile.id, profile.trusted and "trusted" or "untrusted, --dev"))
	else
		hlog:info("no org pack; running neutral")
	end
	for _, err in ipairs(info and info.errors or {}) do hlog:warn("skipped profile " .. err) end

	local SettingsManager = require("core.classes.SettingsManager")
	local settings = SettingsManager:new({ legacy_dir_name = profile and profile.legacy_config_dir })
	settings:load()
	settings:applyProfile(profile)

	local EventLoop = require("core.lib.EventLoop")
	local loop = opts.loop or EventLoop.new({
		on_error = function(msg) hlog:error(msg) end,
		should_stop = type(LUNAR_STOP_REQUESTED) == "function" and LUNAR_STOP_REQUESTED or nil,
	})

	local HostAPI = require("core.classes.HostAPI")
	local host = HostAPI:new({
		loop = loop,
		mode = "headless",
		settings = settings,
		set_status = function(msg) hlog:info(tostring(msg)) end,
		notify = function(spec)
			local level = (spec.kind == "error" and "error") or (spec.kind == "warning" and "warn") or "info"
			hlog[level](hlog, tostring(spec.title or "") .. (spec.body and (": " .. tostring(spec.body)) or ""))
		end,
	})

	local ExtensionManager = require("core.classes.ExtensionManager")
	local ext_mgr = ExtensionManager:new(opts.roots or M.extension_roots(app_dir(), profile, opts))
	local loaded = ext_mgr:loadAll(host)
	for _, s in ipairs(ext_mgr.skipped) do
		hlog:debug(string.format("skipped %s (%s): %s", tostring(s.id), tostring(s.source), tostring(s.reason)))
	end
	hlog:info(string.format("%d extension(s) loaded", loaded))
	host:_markShown()
	return { host = host, extensions = ext_mgr, loop = loop, profile = profile, log = hlog }
end

--- Run the host until stopped. Returns why the loop ended.
-- @tparam table app the table `boot` returned
-- @tparam table opts parsed options
-- @treturn string `"stopped"`, `"idle"` or `"deadline"`
function M.run(app, opts)
	local why = app.loop:run({ until_idle = opts.until_idle, deadline = opts.seconds })
	app.log:info("stopping (" .. why .. ")")
	app.extensions:shutdownAll()
	app.loop:close()
	return why
end

--- Entry point for `lunar-cli --headless`.
-- @tparam table argv the arguments after `--headless`
-- @treturn integer process exit code
function M.main(argv)
	local opts, err = M.parse_args(argv or {})
	if not opts then
		io.stderr:write("lunar-cli: " .. err .. "\n\n" .. M.USAGE)
		return 2
	end
	if opts.help then
		io.stdout:write(M.USAGE)
		return 0
	end
	local app, berr = M.boot(opts)
	if not app then
		io.stderr:write("lunar-cli: " .. tostring(berr) .. "\n")
		return 1
	end
	M.run(app, opts)
	return 0
end

return M
