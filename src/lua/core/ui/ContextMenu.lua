--- Declarative wrapper around IUP popup menus for the right-click actions pattern.
-- Extensions describe a menu as a flat list of entry specs and pop it at the cursor;
-- the class owns the IUP handles and rebuilds them whenever the spec changes.
--
-- An **entry spec** is a table in one of two forms (array order = menu order):
--
--   * `{ title = "Label\tCtrl+X", action = fn }` — a clickable item.  The
--     optional `active = false` field disables the item.
--   * `{ separator = true }` — a horizontal divider.
--
-- Action accelerators (after `\t`) are display-only hints; actual keyboard
-- shortcuts must be registered separately (e.g. via `ctx:addShortcut`).
--
-- @usage
--   local ContextMenu = require("core.ui.ContextMenu")
--   local menu = ContextMenu:new(iup, {
--       { title = "Select All\tCtrl+A", action = do_select_all },
--       { separator = true },
--       { title = "Remove\tCtrl+-",     action = do_remove },
--   })
--   -- in a BUTTON3 press callback:
--   menu:popup()
-- @classmod core.ui.ContextMenu

local class = require("middleclass")

local ContextMenu = class("ContextMenu")

--- Create a new ContextMenu.
-- @tparam userdata iup The IUP library reference (passed in by the host).
-- @tparam[opt] table items Initial entry-spec array; may be `nil` and set later via `setItems`.
-- @treturn ContextMenu New instance.
-- @usage
--   local m = ContextMenu:new(iup, {{ title = "Cut", action = cut_fn }})
function ContextMenu:initialize(iup, items)
    self._iup  = iup
    self._menu = nil
    if items then self:setItems(items) end
end

--- Replace the menu contents.
-- Safe to call repeatedly; the previous IUP menu handle is destroyed first.
-- @tparam table items Array of entry-spec tables (see module description).
-- @treturn ContextMenu `self` for chaining.
function ContextMenu:setItems(items)
    local iup = self._iup
    if self._menu then
        pcall(iup.Destroy, self._menu)
        self._menu = nil
    end

    local children = {}
    for _, spec in ipairs(items or {}) do
        if spec.separator then
            children[#children + 1] = iup.separator{}
        else
            local fn = spec.action
            local it = iup.item{ TITLE = spec.title or "" }
            function it:action()
                if fn then fn() end
                return iup.DEFAULT
            end
            if spec.active == false then iup.SetAttribute(it, "ACTIVE", "NO") end
            children[#children + 1] = it
        end
    end

    self._menu = iup.menu(children)
    return self
end

--- Return the underlying IUP menu handle.
-- Rarely needed directly; prefer `popup` for showing the menu.
-- @treturn userdata IUP menu handle, or `nil` if no items have been set.
function ContextMenu:handle()
    return self._menu
end

--- Pop the menu up at an absolute screen position.
-- When no coordinates are supplied the menu appears at the mouse cursor.
-- @tparam[opt=iup.MOUSEPOS] number x Absolute screen X position.
-- @tparam[opt=iup.MOUSEPOS] number y Absolute screen Y position.
function ContextMenu:popup(x, y)
    local iup = self._iup
    if not self._menu then return end
    iup.Popup(self._menu, x or iup.MOUSEPOS, y or iup.MOUSEPOS)
end

--- Destroy the underlying IUP menu handle and free its resources.
-- The instance is unusable after this call.
function ContextMenu:destroy()
    if self._menu then
        pcall(self._iup.Destroy, self._menu)
        self._menu = nil
    end
end

return ContextMenu
