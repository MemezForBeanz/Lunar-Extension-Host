--- Cooperative async bridge for the host and every extension.
--
-- Wraps lunarmodules/copas so network I/O yields cooperatively instead of
-- blocking the IUP main loop. copas is single-threaded and cooperative: tasks are
-- resumed synchronously on the main thread whenever `pump()` (copas.step) is
-- called from an IUP timer, so it is SAFE to touch IUP widgets from inside a task
-- -- no cross-thread marshalling is required.
--
-- ### What this can and cannot make async
--
-- copas schedules coroutines around NON-BLOCKING SOCKETS. It makes socket work
-- (HTTP, TCP connects) yield. It does **nothing** for blocking file I/O: an
-- `io.open` on an unreachable UNC path stalls the whole scheduler and the UI
-- along with it, because the OS call never returns control to Lua. That is why
-- `probeTcp` exists -- reachability is settled over a socket (async, bounded)
-- *before* any file on the share is touched.
--
-- When copas is unavailable (`M.available == false`) `run()` degrades to a plain
-- synchronous call, preserving the old blocking behaviour rather than failing.
--
-- @module core.lib.async

local M = {}

-- copas.lua has a hard guard that aborts require() when socket.http is already
-- loaded AND _VERSION=="Lua 5.1". LuaJIT reports _VERSION=="Lua 5.1", and the app
-- loads ssl.https (which pulls in socket.http) long before this module, so a naive
-- require("copas") ALWAYS threw -- silently disabling async. copas.http ships its
-- own non-blocking HTTP implementation and does not depend on socket.http staying
-- unloaded, so hide socket.http across the require and restore it afterwards so
-- the synchronous transport still works for callers that need it.
local function load_copas()
	local saved_http = package.loaded["socket.http"]
	package.loaded["socket.http"] = nil
	local ok, mod = pcall(require, "copas")
	package.loaded["socket.http"] = saved_http
	if ok and type(mod) == "table" then return mod end
	return nil
end

local copas = load_copas()
local chttp
if copas then
	local ok_http, h = pcall(require, "copas.http")
	if ok_http and type(h) == "table" then chttp = h end
end

--- True when the copas scheduler and its HTTP transport are both usable.
M.available = (copas ~= nil and chttp ~= nil) or false
M.copas = M.available and copas or nil
--- copas's non-blocking `socket.http`-compatible transport, or `nil`. It does not
-- check the server's host name; extensions should use `ctx:http` (`core.lib.http`).
M.http = chttp

local tunpack = table.unpack or unpack -- luacheck: ignore 143

-- pcall's results with their count: `#t` stops at the first nil, which would
-- drop the error of a task that returns `nil, err`.
local function pcall_n(fn)
	local function pack(...) return { n = select("#", ...), ... } end
	return pack(pcall(fn))
end

--- Schedule `fn` as a copas task; `cb(ok, ...)` receives the pcall result.
--
-- IMPORTANT: `copas.addthread` runs the task body IMMEDIATELY (synchronously, up
-- to its first socket yield) -- it does NOT wait for the next `pump()`. Transports
-- decide between the async and blocking paths by inspecting `copas.running`, so
-- that flag MUST already be true when addthread fires, or the first leg of the
-- request runs on the blocking path and freezes the UI anyway. It is raised here
-- and only lowered in `pump()` once every task has drained.
--
-- @tparam function fn work to run
-- @tparam[opt] function cb completion callback
-- @treturn boolean true when scheduled asynchronously, false when run inline
function M.run(fn, cb)
	if not M.available then
		local res = pcall_n(fn)
		if cb then cb(tunpack(res, 1, res.n)) end
		return false
	end
	copas.running = true
	copas.addthread(function()
		local res = pcall_n(fn)
		if cb then cb(tunpack(res, 1, res.n)) end
	end)
	return true
end

--- Pump the scheduler once, non-blocking.
-- @treturn boolean true while work remains (keep the pump timer running)
function M.pump()
	if not M.available then return false end
	copas.running = true
	copas.step(0)
	if copas.finished() then
		copas.running = false
		return false
	end
	return true
end

--- Cooperative sleep, for use *inside* a task. No-op outside the scheduler.
function M.sleep(sec)
	if M.available and copas.running then
		copas.sleep(sec)
	end
end

--- Can we open a TCP connection to `host:port` within `timeout` seconds?
--
-- Call this INSIDE a task (see `run`): the connect yields to the pump instead of
-- blocking. Its purpose is to answer "is this server there at all?" cheaply and
-- with a bound we control, so callers can skip work that would otherwise hang on
-- an unreachable host for the OS's own (much longer, unconfigurable) timeout.
--
-- @tparam string host hostname or IP
-- @tparam number port TCP port
-- @tparam[opt=1.5] number timeout seconds
-- @treturn boolean reachable
-- @treturn string|nil failure reason when not reachable
function M.probeTcp(host, port, timeout)
	if type(host) ~= "string" or host == "" then
		return false, "no host"
	end
	timeout = tonumber(timeout) or 1.5

	local ok_socket, socket = pcall(require, "socket")
	if not ok_socket or type(socket) ~= "table" then
		return false, "luasocket unavailable"
	end

	local skt = socket.tcp()
	if not skt then return false, "could not create socket" end

	if not (M.available and copas.running) then
		-- Outside the scheduler this still beats the alternative: a bounded
		-- blocking connect, rather than an unbounded wait on the filesystem.
		skt:settimeout(timeout)
		local ok, err = skt:connect(host, port)
		pcall(function() skt:close() end)
		return ok == 1 or ok == true, ok and nil or tostring(err or "unreachable")
	end

	copas.settimeout(skt, timeout)
	local ok, err = copas.connect(skt, host, port)
	pcall(function() copas.close(skt) end)
	if ok then
		return true
	end
	return false, tostring(err or "unreachable")
end

--- Extract the host portion of a UNC path (`\\server\share\...` -> `server`).
-- Returns nil for anything that is not a UNC path.
function M.uncHost(path)
	if type(path) ~= "string" then return nil end
	return path:match("^\\\\([^\\]+)")
end

return M
