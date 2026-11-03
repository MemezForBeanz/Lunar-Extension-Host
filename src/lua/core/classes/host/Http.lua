--- HTTP routes owned by registered extensions.
-- @module core.classes.host.Http
local Manifest = require("core.lib.ExtensionManifest")
local M = {}

function M.addRoute(self, method, path, handler, opts, owner)
	local manifest = self._manifest_by_owner[owner]
	if not manifest or not Manifest.hasCapability(manifest, "http") then
		return nil, "addRoute requires a registered owner with http capability"
	end
	if self._stopping then return nil, "host is stopping" end
	if not self._http_server then return nil, "HTTP server disabled" end
	if opts ~= nil and type(opts) ~= "table" then return nil, "route options must be a table" end
	if opts and opts.public then return nil, "extension routes cannot be public" end
	if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("[%%?#\\%z%c]") then
		return nil, "route path must start with / and contain no escapes, query or fragment"
	end
	for part in path:gmatch("[^/]+") do
		if part == "." or part == ".." then return nil, "route path cannot contain dot components" end
	end
	local ok, route = pcall(self._http_server.route, self._http_server, method,
		"/ext/" .. manifest.id .. path, handler, {})
	if not ok then return nil, tostring(route) end
	local rec = self:_record(owner)
	rec.http_routes = rec.http_routes or {}
	rec.http_routes[route] = true
	return route
end

function M.removeRoute(self, handle, owner)
	local rec = self._owners[owner]
	if not rec or not rec.http_routes or not rec.http_routes[handle] then return false end
	rec.http_routes[handle] = nil
	return self._http_server:unroute(handle)
end

function M.removeOwned(self, owner)
	local rec = self._owners[owner]
	for route in pairs(rec and rec.http_routes or {}) do M.removeRoute(self, route, owner) end
end

return M
