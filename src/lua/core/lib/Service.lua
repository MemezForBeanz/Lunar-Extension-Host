--- The background service: the headless host, run for this user without a console.
--
-- It starts at sign-in and keeps a user's headless extensions running whether or not the
-- window is open. The desktop app finds it through `endpoint.json`, so a local library
-- needs no address or token typed in.
--
--     lunar-cli service run         run in this process
--     lunar-cli service install     start at sign-in
--     lunar-cli service uninstall   stop starting at sign-in
--     lunar-cli service start       start it now, detached
--     lunar-cli service stop        ask it to stop
--     lunar-cli service status      say what it is doing
--
-- On Windows the sign-in entry runs `Lunar.exe --service run`, because the app is a
-- windowed program and LunarCLI would open a console at every sign-in. On Linux it is a
-- systemd user unit. See docs/headless.md for running one machine-wide.
--
-- Everything lives in `<cache dir>/service`: `service.json` (optional settings), `tokens`,
-- `endpoint.json`, and `state/` for extension databases.
--
-- @module core.lib.Service

local ok_ffi, ffi = pcall(require, "ffi")
local cjson = require("cjson")
local platform = require("core.platform")
local Instance = require("core.lib.Instance")

local M = {}

M.DEFAULT_LISTEN = "127.0.0.1:8421"
M.RUN_VALUE = "Lunar Service"
M.UNIT = "lunar"

local TOKEN_BYTES = 32
local RUN_KEY = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
local HKEY_CURRENT_USER = ffi and ffi.cast("void*", 0x80000001ULL)
local KEY_SET_VALUE, KEY_QUERY_VALUE = 0x0002, 0x0001
local REG_SZ = 1
local EVENT_MODIFY_STATE, SYNCHRONIZE = 0x0002, 0x00100000
local WAIT_OBJECT_0 = 0
local SW_HIDE = 0

--- The folder the service keeps everything in.
function M.dir()
	return platform.path:join(platform.cache_dir(), "service")
end

function M.file(name)
	return platform.path:join(M.dir(), name)
end

local function instance_name()
	return "service-" .. Instance.key(platform.config_dir())
end
M.instanceName = instance_name

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	return text
end

local function write_file(path, text)
	local temp = path .. ".new"
	local f, err = io.open(temp, "wb")
	if not f then return nil, err end
	f:write(text)
	f:close()
	os.remove(path)
	local ok, why = os.rename(temp, path)
	if not ok then return nil, why end
	return true
end

local function ensure_dir(path)
	local lfs = require("lfs")
	local built = path:match("^%a:[/\\]") or (path:sub(1, 1) == "/" and "/" or "")
	for part in path:sub(#built + 1):gmatch("[^/\\]+") do
		built = built == "" and part or platform.path:join(built, part)
		if not lfs.attributes(built, "mode") then lfs.mkdir(built) end
	end
	return lfs.attributes(path, "mode") == "directory"
end

--- Random text for a token, from the OS generator.
-- @treturn[1] string hex
-- @treturn[2] nil
-- @treturn[2] string why
function M.randomToken()
	local bytes
	if ok_ffi and ffi.os == "Windows" then
		pcall(ffi.cdef, "unsigned char SystemFunction036(void*, unsigned long);")
		local out = ffi.new("unsigned char[?]", TOKEN_BYTES)
		if ffi.load("advapi32").SystemFunction036(out, TOKEN_BYTES) ~= 0 then bytes = ffi.string(out, TOKEN_BYTES) end
	else
		local f = io.open("/dev/urandom", "rb")
		if f then
			bytes = f:read(TOKEN_BYTES)
			f:close()
		end
	end
	if not bytes or #bytes ~= TOKEN_BYTES then return nil, "the system has no random source" end
	return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

--- The token this user's desktop signs in with, created on first use.
-- @treturn[1] string the token
-- @treturn[2] nil
-- @treturn[2] string why
function M.localToken()
	local path = M.file("tokens")
	local text = read_file(path)
	local token = text and text:match("^desktop%s+(%S+)")
	if token then return token end
	if not ensure_dir(M.dir()) then return nil, "cannot create " .. M.dir() end
	local fresh, err = M.randomToken()
	if not fresh then return nil, err end
	if ok_ffi and ffi.os ~= "Windows" then
		-- Created closed: the token never exists with wider permissions than it ends with.
		local old = os.execute("umask 077 && : > '" .. path:gsub("'", "'\\''") .. "'")
		if old ~= 0 and old ~= true then return nil, "cannot create " .. path end
	end
	local f, why = io.open(path, "wb")
	if not f then return nil, why end
	f:write("desktop ", fresh, "\n")
	f:close()
	return fresh
end

--- Settings the owner may have put in `service.json`, over the defaults.
-- @treturn table `listen`, `dev`, `extensions`, `pack`, `require`, `stop_grace`
function M.config()
	local out = { listen = M.DEFAULT_LISTEN, extensions = {}, require = {}, stop_grace = 30 }
	local text = read_file(M.file("service.json"))
	if text then
		local ok, data = pcall(cjson.decode, text)
		if ok and type(data) == "table" then
			for key, value in pairs(data) do out[key] = value end
		end
	end
	return out
end

--- The options `core.headless` should run with.
-- @tparam table config from `M.config`
-- @treturn table headless options
function M.headlessOptions(config)
	return {
		listen = config.listen, tokens_file = M.file("tokens"), state_dir = M.file("state"),
		dev = config.dev == true, pack = config.pack, extensions = config.extensions or {},
		require = config.require or {}, stop_grace = tonumber(config.stop_grace) or 30,
		tls_cert = config.tls_cert, tls_key = config.tls_key, log_level = config.log_level or "INFO",
	}
end

--- What `endpoint.json` says: how a desktop reaches the running service.
-- @tparam string listen `host:port`
-- @tparam boolean tls
-- @treturn table
function M.endpointFor(listen, tls)
	return { url = (tls and "https://" or "http://") .. listen }
end

--- Where to find a running service, or nil when none is running.
-- @treturn[1] table `url`, `token`
-- @treturn[2] nil
function M.endpoint()
	local text = read_file(M.file("endpoint.json"))
	if not text then return nil end
	local ok, data = pcall(cjson.decode, text)
	if not ok or type(data) ~= "table" or not data.url then return nil end
	return { url = data.url, token = M.localToken() }
end

--- Is a service running for this user?
function M.running()
	local held = Instance.acquire(instance_name())
	if held then
		held:release()
		return false
	end
	return held == false
end

-- Stopping ----------------------------------------------------------------------

local stop_event

local function win_declare()
	pcall(ffi.cdef, [[
		void* CreateEventW(void*, int, int, const unsigned short*);
		void* OpenEventW(unsigned long, int, const unsigned short*);
		int SetEvent(void*);
		unsigned long WaitForSingleObject(void*, unsigned long);
		int CloseHandle(void*);
		int MultiByteToWideChar(unsigned int, unsigned long, const char*, int, unsigned short*, int);
		long RegOpenKeyExW(void*, const unsigned short*, unsigned long, unsigned long, void**);
		long RegSetValueExW(void*, const unsigned short*, unsigned long, unsigned long, const void*, unsigned long);
		long RegDeleteValueW(void*, const unsigned short*);
		long RegQueryValueExW(void*, const unsigned short*, void*, unsigned long*, void*, unsigned long*);
		long RegCloseKey(void*);
		void* ShellExecuteW(void*, const unsigned short*, const unsigned short*, const unsigned short*,
			const unsigned short*, int);
	]])
end

local function widen(text)
	local size = ffi.C.MultiByteToWideChar(65001, 0, text, -1, nil, 0)
	local out = ffi.new("unsigned short[?]", size)
	ffi.C.MultiByteToWideChar(65001, 0, text, -1, out, size)
	return out, size
end

local function event_name()
	return "Local\\lunar-stop-" .. instance_name()
end

-- A windowed process gets no console events, so `service stop` signals a named event.
local function arm_stop()
	if not ok_ffi or ffi.os ~= "Windows" then return end
	win_declare()
	stop_event = ffi.C.CreateEventW(nil, 1, 0, (widen(event_name())))
	local earlier = LUNAR_STOP_REQUESTED
	function LUNAR_STOP_REQUESTED() -- luacheck: ignore 121
		if type(earlier) == "function" and earlier() then return true end
		return stop_event ~= nil and ffi.C.WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0
	end
end

--- Ask the running service to stop.
-- @treturn[1] boolean true
-- @treturn[2] nil
-- @treturn[2] string why
function M.stop()
	if ok_ffi and ffi.os == "Windows" then
		win_declare()
		local handle = ffi.C.OpenEventW(EVENT_MODIFY_STATE + SYNCHRONIZE, 0, (widen(event_name())))
		if handle == nil then return nil, "no service is running" end
		ffi.C.SetEvent(handle)
		ffi.C.CloseHandle(handle)
		return true
	end
	if os.execute("systemctl --user stop " .. M.UNIT .. " 2>/dev/null") == 0 then return true end
	return nil, "no service is running"
end

-- Starting at sign-in -----------------------------------------------------------

--- The program the sign-in entry and `service start` run, with its arguments.
-- @treturn string program
-- @treturn string arguments
function M.command()
	local dir = type(LUNAR_EXE_DIR) == "string" and LUNAR_EXE_DIR or "."
	if ok_ffi and ffi.os == "Windows" then
		return platform.path:join(dir, "Lunar.exe"), "--service run"
	end
	return platform.path:join(dir, "lunar-cli"), "service run"
end

--- A systemd unit for this service.
-- @tparam string program
-- @tparam string arguments
-- @tparam[opt] string target `default.target` for a user unit
-- @treturn string
function M.unitText(program, arguments, target)
	return table.concat({
		"[Unit]", "Description=Lunar background service", "After=network-online.target", "",
		"[Service]", "ExecStart=" .. program .. " " .. arguments, "Restart=on-failure", "RestartSec=30",
		"TimeoutStopSec=60", "KillMode=mixed", "",
		"[Install]", "WantedBy=" .. (target or "default.target"), "",
	}, "\n")
end

local function unit_path()
	local root = os.getenv("XDG_CONFIG_HOME") or ((os.getenv("HOME") or ".") .. "/.config")
	return root .. "/systemd/user/" .. M.UNIT .. ".service"
end

local function with_run_key(access, fn)
	win_declare()
	local key = ffi.new("void*[1]")
	local advapi = ffi.load("advapi32")
	local status = advapi.RegOpenKeyExW(HKEY_CURRENT_USER, (widen(RUN_KEY)), 0, access, key)
	if status ~= 0 then return nil, "cannot open the sign-in list (error " .. tostring(status) .. ")" end
	local out, why = fn(advapi, key[0])
	advapi.RegCloseKey(key[0])
	return out, why
end

--- Does the service start at sign-in?
function M.installed()
	if ok_ffi and ffi.os == "Windows" then
		return with_run_key(KEY_QUERY_VALUE, function(advapi, key)
			return advapi.RegQueryValueExW(key, (widen(M.RUN_VALUE)), nil, nil, nil, nil) == 0
		end) == true
	end
	local f = io.open(unit_path(), "rb")
	if f then f:close() end
	return f ~= nil
end

--- Start at sign-in, for this user.
-- @treturn[1] boolean true
-- @treturn[2] nil
-- @treturn[2] string why
function M.install()
	local program, arguments = M.command()
	if ok_ffi and ffi.os == "Windows" then
		local line = '"' .. program .. '" ' .. arguments
		return with_run_key(KEY_SET_VALUE, function(advapi, key)
			local wide, size = widen(line)
			local status = advapi.RegSetValueExW(key, (widen(M.RUN_VALUE)), 0, REG_SZ, wide, size * 2)
			if status ~= 0 then return nil, "cannot write the sign-in list (error " .. tostring(status) .. ")" end
			return true
		end)
	end
	local path = unit_path()
	if not ensure_dir(path:match("^(.*)/[^/]+$")) then return nil, "cannot create the systemd user folder" end
	local ok, err = write_file(path, M.unitText(program, arguments))
	if not ok then return nil, err end
	os.execute("systemctl --user daemon-reload 2>/dev/null; systemctl --user enable " .. M.UNIT .. " 2>/dev/null")
	return true
end

--- Stop starting at sign-in. A running service keeps running.
-- @treturn[1] boolean true
-- @treturn[2] nil
-- @treturn[2] string why
function M.uninstall()
	if ok_ffi and ffi.os == "Windows" then
		return with_run_key(KEY_SET_VALUE, function(advapi, key)
			advapi.RegDeleteValueW(key, (widen(M.RUN_VALUE)))
			return true
		end)
	end
	os.execute("systemctl --user disable " .. M.UNIT .. " 2>/dev/null")
	os.remove(unit_path())
	return true
end

--- Start the service now, detached from this process.
-- @treturn[1] boolean true
-- @treturn[2] nil
-- @treturn[2] string why
function M.start()
	if M.running() then return true end
	local program, arguments = M.command()
	if ok_ffi and ffi.os == "Windows" then
		win_declare()
		local result = ffi.load("shell32").ShellExecuteW(nil, (widen("open")), (widen(program)),
			(widen(arguments)), nil, SW_HIDE)
		if tonumber(ffi.cast("intptr_t", result)) <= 32 then return nil, "the service could not be started" end
		return true
	end
	if os.execute("systemctl --user start " .. M.UNIT .. " 2>/dev/null") == 0 then return true end
	local quoted = "'" .. program:gsub("'", "'\\''") .. "'"
	os.execute("nohup " .. quoted .. " " .. arguments .. " >/dev/null 2>&1 &")
	return true
end

-- Running -----------------------------------------------------------------------

--- Run the service in this process until it is told to stop.
-- @treturn integer exit code
function M.run()
	local held, why = Instance.acquire(instance_name())
	if held == false then return 0 end   -- already running, which is what was asked for
	if not held then
		io.stderr:write("lunar service: " .. tostring(why) .. "\n")
		return 1
	end
	local token, err = M.localToken()
	if not token then
		held:release()
		io.stderr:write("lunar service: " .. tostring(err) .. "\n")
		return 1
	end
	arm_stop()
	local headless = require("core.headless")
	local config = M.config()
	local opts = M.headlessOptions(config)
	local app, problem = headless.boot(opts)
	if not app then
		held:release()
		io.stderr:write("lunar service: " .. tostring(problem) .. "\n")
		return 1
	end
	if #app.extensions.extensions == 0 then
		-- Nothing wants a service on this machine, so don't sit in memory doing nothing.
		headless.run(app, { seconds = 0, stop_grace = 0, until_idle = true })
		held:release()
		return 0
	end
	local endpoint = M.file("endpoint.json")
	write_file(endpoint, cjson.encode(M.endpointFor(config.listen, config.tls_cert ~= nil)))
	headless.run(app, opts)
	os.remove(endpoint)
	held:release()
	return 0
end

M.USAGE = [[
usage: lunar-cli service <command>

  run         run the service in this process
  install     start the service at sign-in
  uninstall   stop starting it at sign-in
  start       start it now, detached
  stop        ask it to stop
  status      say whether it is running and starts at sign-in
]]

local function say(ok, err, done)
	if ok then
		io.stdout:write(done, "\n")
		return 0
	end
	io.stderr:write("lunar service: ", tostring(err), "\n")
	return 1
end

--- Entry point for `lunar-cli service` and `Lunar.exe --service`.
-- @tparam table argv the arguments after `service`
-- @treturn integer exit code
function M.main(argv)
	local command = argv[1]
	if command == "run" then return M.run() end
	if command == "install" then
		local ok, err = M.install()
		return say(ok, err, "Lunar's service will start at sign-in.")
	end
	if command == "uninstall" then
		local ok, err = M.uninstall()
		return say(ok, err, "Lunar's service will no longer start at sign-in.")
	end
	if command == "start" then
		local ok, err = M.start()
		return say(ok, err, "Lunar's service is starting.")
	end
	if command == "stop" then
		local ok, err = M.stop()
		return say(ok, err, "Lunar's service is stopping.")
	end
	if command == "status" then
		io.stdout:write(M.running() and "running" or "stopped", ", ",
			M.installed() and "starts at sign-in" or "does not start at sign-in", "\n")
		return 0
	end
	io.stderr:write(M.USAGE)
	return command == nil and 0 or 2
end

return M
