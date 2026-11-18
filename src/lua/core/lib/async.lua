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

local function load_resolver()
	local ok, mod = pcall(require, "native_resolver")
	if ok and type(mod) == "table"
		and type(mod.start) == "function"
		and type(mod.poll) == "function" then
		return mod
	end
	return nil
end

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
-- Optional native DNS worker. The host preloads this in production; keeping it
-- optional preserves the standalone Lua/headless fallback.
M.resolver = load_resolver()

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

--- Run the scheduler once, waiting up to `timeout` seconds for socket activity.
-- The headless loop (`core.lib.EventLoop`) uses this so an idle host sleeps in
-- `select` instead of spinning; the GUI uses `pump` (no wait).
-- @tparam[opt=0] number timeout seconds
-- @treturn boolean true while work remains
function M.step(timeout)
	if not M.available then return false end
	copas.running = true
	copas.step(timeout or 0)
	if copas.finished() then
		copas.running = false
		return false
	end
	return true
end

--- Pump the scheduler once, non-blocking.
-- @treturn boolean true while work remains (keep the pump timer running)
function M.pump()
	return M.step(0)
end

--- Cooperative sleep, for use *inside* a task. No-op outside the scheduler.
function M.sleep(sec)
	if M.available and copas.running then
		copas.sleep(sec)
	end
end

local function monotime(socket)
	if type(M._test_gettime) == "function" then return M._test_gettime() end
	if M.resolver and type(M.resolver.now) == "function" then return M.resolver.now() end
	if type(socket.gettime) == "function" then return socket.gettime() end
	return os.clock()
end

local function is_numeric_host(host)
	if host:find(":", 1, true) then
		return host:match("^[0-9A-Fa-f:]+$") ~= nil
	end
	local count = 0
	for octet in host:gmatch("%d+") do
		count = count + 1
		if tonumber(octet) > 255 then return false end
	end
	return count == 4 and host:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

local function close_socket(socket, skt)
	if M.available and copas.running then
		pcall(function() copas.close(skt) end)
	else
		pcall(function() skt:close() end)
	end
end

local function cancel_resolver(resolver, request)
	if not request then return end
	if type(resolver.cancel) == "function" then pcall(resolver.cancel, request) end
	if type(resolver.close) == "function" then pcall(resolver.close, request) end
end

local function resolve_host(socket, host, deadline, cooperative)
	local resolver = M.resolver
	if not resolver then return nil, "native DNS resolver unavailable" end
	local request, err = resolver.start(host)
	while not request and err == "DNS resolver is busy" and monotime(socket) < deadline do
		local wait=math.min(0.01,deadline-monotime(socket))
		if cooperative then copas.sleep(wait)
		elseif M._test_sleep then M._test_sleep(wait)
		elseif socket.sleep then socket.sleep(wait) end
		if monotime(socket)>=deadline then return nil,"DNS resolver capacity timeout" end
		request,err=resolver.start(host)
	end
	if not request then return nil, tostring(err or "could not start DNS resolver") end
	local addresses
	while true do
		local now = monotime(socket)
		if now >= deadline then
			cancel_resolver(resolver, request)
			return nil, "timeout resolving host"
		end
		local state, value = resolver.poll(request)
		if state == "done" then
			addresses = value
			break
		elseif state == "error" then
			cancel_resolver(resolver, request)
			return nil, tostring(value or "host resolution failed")
		end
		local wait = math.min(0.01, deadline - now)
		if cooperative and M.available and copas.running then
			copas.sleep(wait)
		elseif type(M._test_sleep) == "function" then
			M._test_sleep(wait)
		elseif type(socket.sleep) == "function" then
			socket.sleep(wait)
		end
	end
	if type(resolver.close) == "function" then pcall(resolver.close, request) end
	if type(addresses) ~= "table" or #addresses == 0 then
		return nil, "host resolution returned no addresses"
	end
	-- LuaSocket/Copas can spend a full connect timeout on a refused IPv6 route
	-- on Windows. Prefer IPv4 when both are returned, retain IPv6 as fallback.
	local ordered = {}
	for _,address in ipairs(addresses) do if not address:find(":",1,true) then ordered[#ordered+1]=address end end
	for _,address in ipairs(addresses) do if address:find(":",1,true) then ordered[#ordered+1]=address end end
	return ordered
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
	if timeout <= 0 then return false, "timeout" end

	local ok_socket, socket = pcall(require, "socket")
	if not ok_socket or type(socket) ~= "table" then
		return false, "luasocket unavailable"
	end

	local deadline = monotime(socket) + timeout
	local cooperative = M.available and copas.running
	local addresses = { host }
	if not is_numeric_host(host) then
		if M.resolver then
			local resolved, resolve_err = resolve_host(socket, host, deadline, cooperative)
			if not resolved then return false, resolve_err end
			addresses = resolved
		elseif cooperative then
			return false, "native DNS resolver unavailable"
		end
	elseif host:find(":", 1, true) then
		-- LuaSocket accepts an unbracketed numeric IPv6 address.
		addresses = { host }
	end

	local last_err = "unreachable"
	for i, address in ipairs(addresses) do
		local remaining = deadline - monotime(socket)
		if remaining <= 0 then return false, "timeout" end
		local skt = socket.tcp()
		if not skt then return false, "could not create socket" end
		-- A dead first address must not consume the budget for every other family.
		local attempt_timeout = remaining / (#addresses - i + 1)
		if cooperative then
			copas.settimeout(skt, attempt_timeout)
			local ok, err = copas.connect(skt, address, port)
			close_socket(socket, skt)
			if ok then return true end
			last_err = tostring(err or last_err)
		else
			skt:settimeout(attempt_timeout)
			local ok, err = skt:connect(address, port)
			close_socket(socket, skt)
			if ok == 1 or ok == true then return true end
			last_err = tostring(err or last_err)
		end
	end
	return false, last_err
end

--- Extract the host portion of a UNC path (`\\server\share\...` -> `server`).
-- Returns nil for anything that is not a UNC path.
function M.uncHost(path)
	if type(path) ~= "string" then return nil end
	return path:match("^\\\\([^\\]+)")
end

return M
