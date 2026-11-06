package.path = "src/lua/?.lua;vendor/luasocket/src/?.lua;vendor/luasec/src/?.lua;vendor/copas/?.lua;vendor/copas/copas/?.lua;vendor/luarocks-tree/share/lua/5.1/?.lua;vendor/luarocks-tree/share/lua/5.1/?/init.lua;" .. package.path
-- Loopback-only fixture for scripts/benchmark_media.py; no extension or catalog.
local Http = require("core.lib.HttpServer")
local socket = require("socket")
local copas = require("core.lib.async").copas
local root, port = assert(arg[1]), tonumber(arg[2]) or 18471
local tls = arg[3] and { certificate = arg[3], key = arg[4] } or nil
local server = Http.new({ host = "127.0.0.1", port = port, tokens = { bench = "benchmark" },
	tls = tls, max_connections = 64 })
local lag, ticks, stopping = {}, 0, false
for _, method in ipairs({ "GET", "HEAD" }) do
	server:route(method, "/media", function()
		return Http.fileResponse(root, "fixture.bin", { mime = "application/octet-stream" })
	end)
	for name, path in pairs({ large = "large.bin", empty = "empty.bin", traversal = "../outside.bin", absolute = "/outside.bin",
		reparse = "link/fixture.bin", escape = "x/../../outside.bin", ads = "fixture.bin:stream" }) do
		server:route(method, "/" .. name, function()
			return Http.fileResponse(root, path)
		end)
	end
end
server:route("GET", "/metrics", function()
	table.sort(lag)
	local active = 0
	for _ in pairs(server.transfers) do active = active + 1 end
	return { json = { active_transfers = active, ticks = ticks, lag_p99_ms = lag[math.max(1, math.ceil(#lag * 0.99))] or 0 } }
end)
server:route("POST", "/stop", function() stopping = true return { status = 204 } end)
assert(server:start())
local next_tick = socket.gettime() + 0.01
while not stopping do
	copas.step(0.002)
	local now = socket.gettime()
	if now >= next_tick then
		ticks = ticks + 1
		lag[#lag + 1] = (now - next_tick) * 1000
		next_tick = now + 0.01
	end
end
server:stop()
while server:pendingFiles() do copas.step(0.002) end

