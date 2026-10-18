--- Internal secrets service for core.classes.HostAPI.
-- @module core.classes.host.Secrets
-- @local

local M = {}


-- =======================================================================
-- SECRETS
-- =======================================================================

-- Where an extension's secret lives in the OS store. Namespaced by manifest id,
-- so one extension can't read another's.
function M._secretTarget(self, owner, name)
    local manifest = self._manifest_by_owner[owner]
    if not (manifest and type(manifest.id) == "string") then
        return nil, "secrets need a registered extension"
    end
    if type(name) ~= "string" or not name:match("^[%w][%w._-]*$") then
        return nil, "secret names are letters, digits, '.', '_' and '-'"
    end
    return "Lunar Extension Host/" .. manifest.id .. "/" .. name
end

function M._secretStore(self)
    return self._secret_store or require("core.platform")
end

function M.getSecret(self, owner, name)
    local target, err = self:_secretTarget(owner, name)
    if not target then return nil, err end
    return self:_secretStore().secret_get(target)
end

function M.setSecret(self, owner, name, value)
    local target, err = self:_secretTarget(owner, name)
    if not target then return nil, err end
    if type(value) ~= "string" or value == "" then return nil, "a secret must be a non-empty string" end
    return self:_secretStore().secret_set(target, value)
end

function M.deleteSecret(self, owner, name)
    local target, err = self:_secretTarget(owner, name)
    if not target then return nil, err end
    return self:_secretStore().secret_delete(target)
end

return M
