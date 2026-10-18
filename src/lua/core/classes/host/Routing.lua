--- Internal routing service for core.classes.HostAPI.
-- @module core.classes.host.Routing
-- @local

local M = {}
local RouteUri = require("core.lib.RouteUri")
local handle = require("core.lib.handle")
local DEFAULT_OWNER = require("core.classes.host.Owners")

function M.registerRouteHandler(self, action, fn, owner)
    if type(action) ~= "string" or action == "" then
        error("registerRouteHandler action is required", 2)
    end
    if type(fn) ~= "function" then
        error("registerRouteHandler fn must be a function", 2)
    end
    owner = owner or DEFAULT_OWNER
    local handlers = self._route_handlers[owner]
    if not handlers then
        handlers = {}
        self._route_handlers[owner] = handlers
    end
    handlers[action] = fn
    return fn
end

function M.registerRouteSerializer(self, fn, owner)
    if type(fn) ~= "function" then
        error("registerRouteSerializer fn must be a function", 2)
    end
    owner = owner or DEFAULT_OWNER
    self._route_serializers[owner] = fn
    return fn
end


--- Build a route error record.
-- @local
function M._routeError(self, code, message)
    return { code = code, message = message }
end

function M.dispatchRoute(self, uri)
    local route, parse_err = RouteUri.parse(uri)
    if not route then
        return nil, self:_routeError("invalid_route", parse_err)
    end

    if route.kind == "host" then
        local widget = self._host_tabs[route.target]
        if not widget then
            return nil, self:_routeError("unknown_host_target", "unknown host target: " .. route.target)
        end
        if route.action then
            return nil, self:_routeError("unknown_host_action", "host target does not support action: " .. route.action)
        end
        if not self:_activateTabWidget(widget) then
            return nil, self:_routeError("host_target_unavailable", "host target is not available: " .. route.target)
        end
        return true, route
    end

    local owner = self._owner_by_extension_id[route.target]
    if not owner then
        return nil, self:_routeError("unknown_plugin", "plugin is not loaded: " .. route.target)
    end
    local rec = self._owners[owner]
    if rec and rec.tabs[1] then self:_activateTabWidget(rec.tabs[1]) end

    local action = route.action
    if not action then return true, route end
    local handler = self._route_handlers[owner] and self._route_handlers[owner][action]
    if not handler then
        return nil, self:_routeError("unknown_plugin_action",
            string.format("plugin '%s' does not support action '%s'", route.target, action))
    end
    local ok, result = xpcall(function()
        return handler(route.params, route)
    end, debug.traceback)
    if not ok then
        return nil, self:_routeError("route_handler_error", tostring(result))
    end
    return true, result
end

function M.currentRoute(self)
    local owner = self:_activeOwner()
    if owner then
        local manifest = self._manifest_by_owner[owner]
        if manifest then
            local action, params
            local serializer = self._route_serializers[owner]
            if serializer then
                local ok, state = pcall(serializer)
                if not ok then
                    self:setStatus("Route serialization error: " .. tostring(state))
                    return nil
                end
                if type(state) == "table" then
                    action, params = state.action, state.params
                end
            end
            return RouteUri.serialize({
                kind = "plugin",
                target = manifest.id,
                action = action,
                params = params,
            })
        end
    end

    local active = self:_activeTab()
    for id, widget in pairs(self._host_tabs) do
        if handle.same(self.iup, widget, active) then
            return RouteUri.serialize({ kind = "host", target = id })
        end
    end
    return nil
end

function M.currentAddress(self)
    local active = self:_activeTab()
    for id, widget in pairs(self._host_tabs) do
        if handle.same(self.iup, widget, active) then
            return { kind = "host", target = id, params = {} }
        end
    end

    local owner = self:_activeOwner()
    if owner then
        local serializer = self._route_serializers[owner]
        if serializer then
            local ok, route = pcall(serializer)
            if ok and type(route) == "table" then
                return route
            end
        end
        local manifest = self._manifest_by_owner[owner]
        if manifest and manifest.id then
            return { kind = "plugin", target = manifest.id, params = {} }
        end
    end
    return nil
end

function M.currentAddressURI(self)
    local route = self:currentAddress()
    if not route then
        return nil
    end
    local uri = RouteUri.serialize(route)
    return uri
end

function M.dispatchAddress(self, uri_or_route)
    local route = uri_or_route
    if type(uri_or_route) == "string" then
        local parsed, err = RouteUri.parse(uri_or_route)
        if not parsed then
            return nil, self:_routeError("malformed_route", "Malformed Lunar address: " .. tostring(err))
        end
        route = parsed
    end
    if type(route) ~= "table" then
        return nil, self:_routeError("malformed_route", "Route dispatch requires a parsed route table or lunar:// URI")
    end

    if route.kind == "host" then
        local widget = self._host_tabs[route.target]
        if not widget then
            return nil, self:_routeError("unknown_route", "Unknown host route target: " .. tostring(route.target))
        end
        if not self:_activateTabWidget(widget) then
            return nil, self:_routeError("route_unavailable", "Host route target is not available: " .. tostring(route.target))
        end
        return true, route
    end

    if route.kind ~= "plugin" then
        return nil, self:_routeError("malformed_route", "Unknown route kind: " .. tostring(route.kind))
    end

    local owner = self._owner_by_extension_id[route.target]
    if not owner then
        return nil, self:_routeError("unknown_route", "Unknown plugin route target: " .. tostring(route.target))
    end

    local rec = self._owners[owner]
    if rec and rec.tabs and rec.tabs[1] then
        self:_activateTabWidget(rec.tabs[1])
    end

    if route.action and route.action ~= "" then
        local handlers = self._route_handlers[owner]
        local handler = handlers and handlers[route.action]
        if not handler then
            return nil, self:_routeError(
                "unknown_route",
                string.format("Plugin '%s' does not provide route '%s'", tostring(route.target), tostring(route.action))
            )
        end
        local ok, result = pcall(handler, route.params or {}, route)
        if not ok then
            return nil, self:_routeError("dispatch_failed", "Route dispatch failed: " .. tostring(result))
        end
        return true, result
    end

    return true, route
end

return M
