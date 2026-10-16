--- Builds the host application menu bar: File, Extensions, Help.
-- The host contributes minimal items per menu (File → Exit; Help → About) and
-- exposes each menu handle plus its anchor item so the `HostAPI` can let extensions
-- append their own entries.
--
-- @module core.ui.MenuBar

local M = {}

--- Build the application menu bar.
-- **deps fields:**
--
-- * `iup` `userdata` — IUP library reference.
-- * `app_title` `string` — Application title shown in the About dialog.
-- * `app_version` `string` — Application version shown in the About dialog.
-- * `ext_mgr` `table` — `ExtensionManager` instance (used by "Reload Extensions").
-- * `set_status` `function(msg)` — host status-bar update callback.
-- * `build_ext_ctx` `function() -> ctx` — factory for the extension context passed to `reloadAll`.
-- * `on_reload` `function()` *(optional)* — called after a successful reload. The host
--   uses it to re-apply the tab-group layout: a reload appends every extension tab
--   back at the root strip, so without this the user's groups would come back empty.
--
-- @tparam table deps Dependency table (see above).
-- @treturn userdata IUP menu widget to assign to the dialog's `MENU` attribute.
-- @treturn table Handle table with keys: `ext_menu`, `ext_submenu`, `file_menu`,
--   `file_exit`, `help_menu`, `help_submenu`, `help_about`.
function M.build(deps)
    local iup            = deps.iup
    local app_title      = deps.app_title
    local app_version    = deps.app_version
    local ext_mgr        = deps.ext_mgr
    local set_status     = deps.set_status
    local build_ext_ctx  = deps.build_ext_ctx
    local on_reload      = deps.on_reload

     -- File menu  --

    local file_exit = iup.item{ TITLE = "Exit" }

    function file_exit:action()
        return iup.CLOSE
    end

    local file_menu = iup.menu{
        file_exit,
    }

     -- Extensions menu --
     -- The "(No extensions loaded)" placeholder is created/destroyed dynamically by
     -- the ExtensionManager (Win32 menu items can't be hidden via VISIBLE), so it is
     -- NOT declared statically here. Extensions append their own items at load.

    local ext_reload = iup.item{ TITLE = "Reload Extensions" }

    function ext_reload:action()
        local count = ext_mgr:reloadAll(build_ext_ctx())
        if on_reload then pcall(on_reload) end

        if count > 0 then
            set_status(string.format("Reloaded %d extension(s)", count))
        else
            set_status("No extensions found in plugins/")
        end
        return iup.DEFAULT
    end

    local ext_menu = iup.menu{
        ext_reload,
    }

     -- Help menu  --

    local help_about = iup.item{ TITLE = "About " .. app_title }

    -- The runtime the binary is actually built on, not a hard-coded string.
    local lua_runtime = (type(jit) == "table" and jit.version) or _VERSION

    function help_about:action()
        iup.Message(app_title,
            app_title .. " v" .. app_version .. "\n\n"
            .. "Lightweight, extension-based tooling host.\n"
            .. "Built with " .. lua_runtime .. " + IUP 3.32\n\n"
            .. "(c) Lunar Extension Host contributors")
        return iup.DEFAULT
    end

    local help_menu = iup.menu{ help_about }

    local ext_submenu  = iup.submenu{ TITLE = "Extensions", ext_menu  }
    local help_submenu = iup.submenu{ TITLE = "Help",       help_menu }
    local menu = iup.menu{
        iup.submenu{ TITLE = "File", file_menu },
        ext_submenu,
        help_submenu,
    }

    return menu, {
        ext_menu     = ext_menu,
        ext_submenu  = ext_submenu,
        file_menu    = file_menu,
        file_exit    = file_exit,
        help_menu    = help_menu,
        help_submenu = help_submenu,
        help_about   = help_about,
    }
end

return M
