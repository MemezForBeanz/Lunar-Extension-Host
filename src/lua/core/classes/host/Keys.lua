--- Internal keys service for core.classes.HostAPI.
-- @module core.classes.host.Keys
-- @local

local M = {}
local DEFAULT_OWNER = require("core.classes.host.Owners")

function M._installKeyDispatch(self, ih)
    if not ih then return end
    pcall(function()
        local host = self
        ih.k_any = function(_, c)
            return host:_dispatchKey(c)
        end
    end)
end

function M.installKeyDispatch(self, root)
    self:_walkTree(root, function(ih)
        self:_installKeyDispatch(ih)
    end)
end


--- Route a key code to registered shortcut handlers that are currently in scope.
--
-- An owner that contributes tabs gets its shortcuts only while one of its tabs is
-- active; an owner with no tabs is always in scope. This mirrors the tab-scoping of
-- menu items, so an extension's shortcuts work only on its own tabs and fall
-- through to normal editing elsewhere.
--
-- @local
function M._dispatchKey(self, c)
    local iup  = self.iup
    local list = self._shortcuts[c]
    -- A handler can unregister itself (fullscreen Escape does). Dispatch a
    -- snapshot so removing it does not skip or invalidate the next handler.
    local pending = {}
    for i, entry in ipairs(list or {}) do pending[i] = entry end
    local active_owner = self:_activeOwner()
    local consumed = false
    for i = 1, #pending do
        local e = pending[i]
        local rec = self._owners[e.owner]
        local owner_has_tabs = rec and #rec.tabs > 0
        local in_scope = (not owner_has_tabs) or (e.owner == active_owner)
        if in_scope then
            pcall(e.fn)
            consumed = true
        end
    end
    if not consumed and self._key_fallback then
        local ok, handled = pcall(self._key_fallback, c)
        consumed = ok and handled or false
    end
    return consumed and iup.IGNORE or iup.CONTINUE
end

function M.registerShortcut(self, key, fn, owner)
    if not key or not fn then return end
    local list = self._shortcuts[key]
    if not list then list = {}; self._shortcuts[key] = list end
    local entry = { key = key, fn = fn, owner = owner or DEFAULT_OWNER }
    list[#list + 1] = entry
    table.insert(self:_record(owner).shortcuts, entry)
    return entry
end

function M.unregisterShortcut(self, entry)
    if not entry then return false end
    local list = self._shortcuts[entry.key]
    if not list then return false end
    for i = #list, 1, -1 do
        if list[i] == entry then
            table.remove(list, i)
            local record = self._owners[entry.owner]
            if record then
                for j = #record.shortcuts, 1, -1 do
                    if record.shortcuts[j] == entry then table.remove(record.shortcuts, j) end
                end
            end
            if #list == 0 then self._shortcuts[entry.key] = nil end
            return true
        end
    end
    return false
end

return M
