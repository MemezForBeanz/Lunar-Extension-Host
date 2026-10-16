--- Per-machine identity resolver for run records and backend attribution.
-- Produces a small, stable identity block describing the host that produced
-- a build run: `{ hostname, user, ipv4, machine_id }`. The backend and local
-- history use this to attribute runs to a specific machine/operator without
-- any login, password, or token -- it is descriptive metadata, not
-- authentication.
--
-- Design rules:
--
-- * No new dependencies: hostname and user come from environment variables;
--   IPv4 is resolved via the vendored luasocket (`socket.dns`); `machine_id`
--   is a UUID generated once and persisted via SettingsManager so it is
--   stable across restarts on the same install.
-- * Never raises: every lookup is guarded so a missing socket module, a DNS
--   failure, or an absent settings manager degrades to a `nil` field rather
--   than breaking a build or the UI.
-- * Resolved once and cached: identity does not change during a process.
-- @module core.lib.machine

local M = {}

local cached = nil

-- Best-effort environment lookup.
local function env(name)
	local v = os.getenv(name)
	if type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

-- Resolve the primary IPv4 address via luasocket's DNS helpers. Guarded: the CLI
-- harness and some dev contexts run without the socket module, in which case this
-- returns nil rather than erroring.
local function resolve_ipv4(hostname)
	local ok_sock, socket = pcall(require, "socket")
	if not ok_sock or type(socket) ~= "table" or type(socket.dns) ~= "table" then
		return nil
	end
	local name = hostname
	if not name then
		local ok_hn, hn = pcall(socket.dns.gethostname)
		if ok_hn and type(hn) == "string" and hn ~= "" then
			name = hn
		end
	end
	if not name then
		return nil
	end
	local ok_ip, ip = pcall(socket.dns.toip, name)
	if ok_ip and type(ip) == "string" and ip:match("^%d+%.%d+%.%d+%.%d+$") then
		return ip
	end
	return nil
end

-- Generate a random RFC-4122-style v4 UUID string. Pure Lua; used only to mint a
-- stable per-install machine_id the first time one is needed.
local seeded = false
local function uuid4()
	if not seeded then
		math.randomseed(os.time() + (tonumber(tostring({}):match("0x(%x+)") or "0", 16) or 0))
		-- Discard the first few values (LuaJIT/PUC seeding is weak on the low bits).
		math.random(); math.random(); math.random()
		seeded = true
	end
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	return (template:gsub("[xy]", function(c)
		local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
		return string.format("%x", v)
	end))
end

-- Resolve (and cache) a stable machine_id. When a SettingsManager is supplied the
-- id is persisted under "machine_id" so it survives restarts; without one, a
-- transient id is generated so the field is still populated for this process.
local function resolve_machine_id(settings_mgr)
	if settings_mgr and type(settings_mgr.get) == "function" then
		local existing = settings_mgr:get("machine_id")
		if type(existing) == "string" and existing ~= "" then
			return existing
		end
		local id = uuid4()
		if type(settings_mgr.set) == "function" then
			settings_mgr:set("machine_id", id)
			if type(settings_mgr.save) == "function" then
				pcall(function() settings_mgr:save() end)
			end
		end
		return id
	end
	return uuid4()
end

--- Resolve and return the machine identity record.
-- The result is cached after the first call; subsequent calls return the
-- same table without any further resolution.
-- @tparam[opt] table settings_mgr a SettingsManager instance with `get`, `set`,
--   and `save` methods. When provided, `machine_id` is persisted and remains
--   stable across restarts. When omitted a transient UUID is generated.
-- @treturn table identity record with fields: `hostname` (string|nil),
--   `user` (string|nil), `ipv4` (string|nil), `machine_id` (string).
-- @usage
-- local machine = require("core.lib.machine")
-- local id = machine.identify(settings_manager)
-- print(id.hostname, id.machine_id)
function M.identify(settings_mgr)
	if cached then
		return cached
	end
	local hostname = env("COMPUTERNAME")
	local info = {
		hostname   = hostname,
		user       = env("USERNAME"),
		ipv4       = resolve_ipv4(hostname),
		machine_id = resolve_machine_id(settings_mgr),
	}
	cached = info
	return info
end

--- Clear the cached identity so the next `identify` call re-resolves.
-- Intended for tests that need to re-resolve identity between test cases.
-- @local
function M._reset()
	cached = nil
end

--- Generate a new random RFC-4122-style v4 UUID string.
-- Pure Lua; useful when a one-off identifier is needed outside the
-- machine identity context.
-- @treturn string UUID string in the form `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`.
function M.new_id()
	return uuid4()
end

return M
