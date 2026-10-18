--- Internal menus service for core.classes.HostAPI.
-- @module core.classes.host.Menus
-- @local

local M = {}
local DEFAULT_OWNER = require("core.classes.host.Owners")


-- Lazily create the separator that sits directly above File's "Exit" item. It is
-- only added once an extension contributes a File entry, so a plugin-less app shows
-- just "Exit" with no leading separator.
function M._ensureFileSeparator(self)
    if self._file_sep then return self._file_sep end
    local iup = self.iup
    if not (self.file_menu and self._file_exit) then return nil end
    local sep = iup.separator{}
    iup.Insert(self.file_menu, self._file_exit, sep)
    iup.Map(sep)
    self._file_sep = sep
    return sep
end


-- Lazily create the separator that sits directly above Help's "About" item.
function M._ensureHelpSeparator(self)
    if self._help_sep then return self._help_sep end
    local iup = self.iup
    if not (self.help_menu and self._help_about) then return nil end
    local sep = iup.separator{}
    iup.Insert(self.help_menu, self._help_about, sep)
    iup.Map(sep)
    self._help_sep = sep
    return sep
end


-- Destroy the lazy File/Help separators (host-level, shared). Called on reload after
-- all extension-owned items are torn down, so they are rebuilt cleanly on reload.
function M._resetMenuSeparators(self)
    local iup = self.iup
    if self._file_sep then iup.Detach(self._file_sep); iup.Destroy(self._file_sep); self._file_sep = nil end
    if self._help_sep then iup.Detach(self._help_sep); iup.Destroy(self._help_sep); self._help_sep = nil end
end

function M.addMenuItem(self, title, callback, target, owner)
    local iup = self.iup
    local item = iup.item{ TITLE = title }
    function item:action()
        if callback then callback() end
        return iup.DEFAULT
    end

    if target == "file" and self.file_menu then
        local anchor = self:_ensureFileSeparator() or self._file_exit
        iup.Insert(self.file_menu, anchor, item)
    elseif target == "help" and self.help_menu then
        local anchor = self:_ensureHelpSeparator() or self._help_about
        iup.Insert(self.help_menu, anchor, item)
    else
        iup.Append(self.ext_menu, item)
    end

    iup.Map(item)
    table.insert(self:_record(owner).items, item)

    -- Track the item so it is shown only while the owning extension's tab is active.
    -- (Owners with no tabs are treated as always-visible — see _applyMenuScope.)
    self._tab_scoped[#self._tab_scoped + 1] = {
        owner   = owner or DEFAULT_OWNER,
        item    = item,
        target  = target or "extensions",
        present = true,
    }
    if self._shown then self:_applyMenuScope() end

    return item
end

function M.addVersionInfo(self, name, version, owner)
    local iup = self.iup
    if not self.help_menu then return end
    local title = tostring(name or "Extension") .. "    v" .. tostring(version or "?")
    local item = iup.item{ TITLE = title, ACTIVE = "NO" }
    -- The version block sits above the first non-version Help item. Capture that
    -- anchor once; every version inserts before it, keeping versions at the top in
    -- insertion order regardless of when other Help items were added.
    if not self._help_version_after then
        local ok, first = pcall(iup.GetNextChild, self.help_menu)
        self._help_version_after = (ok and first) or (self:_ensureHelpSeparator() or self._help_about)
    end
    iup.Insert(self.help_menu, self._help_version_after, item)
    iup.Map(item)
    table.insert(self:_record(owner).items, item)
    return item
end


-- Re-insert a previously-detached scoped item at its correct menu position.
function M._insertScopedItem(self, s)
    local iup = self.iup
    if s.target == "file" and self.file_menu then
        local anchor = self:_ensureFileSeparator() or self._file_exit
        iup.Insert(self.file_menu, anchor, s.item)
    elseif s.target == "help" and self.help_menu then
        local anchor = self:_ensureHelpSeparator() or self._help_about
        iup.Insert(self.help_menu, anchor, s.item)
    else
        iup.Append(self.ext_menu, s.item)
    end
    iup.Map(s.item)
end


-- Show the active owner's contributed menu items; hide everyone else's. Items whose
-- owner contributes no tabs stay visible (they have no tab to scope them to).
function M._applyMenuScope(self)
    local iup = self.iup
    local active_owner = self:_activeOwner()
    for _, s in ipairs(self._tab_scoped) do
        local rec = self._owners[s.owner]
        local owner_has_tabs = rec and #rec.tabs > 0
        local want
        if owner_has_tabs then
            want = (s.owner == active_owner)
        else
            want = true
        end
        if want and not s.present then
            self:_insertScopedItem(s)
            s.present = true
        elseif (not want) and s.present then
            iup.Detach(s.item)
            s.present = false
        end
    end
    self:_fixupFileSeparator()
end


-- Keep the File menu's leading separator only while at least one File item is shown,
-- so an inactive tab leaves the File menu as just "Exit" (no dangling separator).
function M._fixupFileSeparator(self)
    local iup = self.iup
    local any = false
    for _, s in ipairs(self._tab_scoped) do
        if s.target == "file" and s.present then any = true; break end
    end
    if any then
        self:_ensureFileSeparator()
    elseif self._file_sep then
        iup.Detach(self._file_sep)
        iup.Destroy(self._file_sep)
        self._file_sep = nil
    end
end

return M
