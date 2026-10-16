--- Discovers, loads, tracks, and reloads plugin extensions.
--
-- Extensions come from an ordered list of **roots**: the built-in plugins
-- folder, then the selected org pack's `extensions/` folder (main.lua decides
-- which roots are allowed; a release build only uses protected ones). Before any
-- of an extension's code runs, its manifest must pass validation, name a
-- platform this host runs on (`platforms`), need no newer host API than this one
-- (`host_api`), and use an id no earlier root has already loaded.
--
-- Each extension receives the host's `HostAPI` instance as its `ctx`. The
-- `HostAPI` records exactly what each extension created (tabs, menu items, timers,
-- settings) and tears it all down on unload via `host:removeOwned(ext)`.
--
-- Plugin forms:
--
--   * `<dir>/<name>.lua` — single-file plugin
--   * `<dir>/<name>/init.lua` — folder plugin (may ship its own modules in
--     subdirectories, required as `"classes.X"`, `"ui.X"`, `"libs.X"` — the
--     manager puts the plugin folder on `package.path` while the plugin loads;
--     native C modules in the plugin root or a `native/` subdir are put on
--     `package.cpath`, so the extension can require its own native module)
--
-- @classmod core.classes.ExtensionManager

local class = require("middleclass")
local lfs   = require("lfs")
local Manifest = require("core.lib.ExtensionManifest")
local platform = require("core.platform")
local path = platform.path

local ExtensionManager = class("ExtensionManager")

local function ensure_dir(dir)
    local attr = lfs.attributes(dir)
    if not attr then lfs.mkdir(dir) end
end

local function plugin_name_from_path(file)
    if type(file) ~= "string" then
        return "<unknown plugin>"
    end
    return file:match("([^\\/]+)%.lua$") or file
end

local function report_plugin_error(iup, ctx, entry, phase, err)
    local plugin_name = plugin_name_from_path(entry and entry.path)
    local message = string.format(
        "Plugin '%s' failed during %s.\n\n%s",
        plugin_name,
        tostring(phase or "load"),
        tostring(err or "Unknown error")
    )
    if ctx and ctx.setStatus then
        ctx:setStatus(message)
    end
    if iup and iup.Message then
        iup.Message("Plugin Load Error", message)
    end
end

--- Create a new ExtensionManager.
-- @tparam string|table roots One plugins folder, or a list of roots
--   `{ dir = string, source = string, create = boolean }` in load order. A root
--   with `create = true` is created if missing (the built-in folder); other
--   missing roots are skipped.
-- @usage
--   local mgr = ExtensionManager:new({
--       { dir = app_plugins, source = "built-in", create = true },
--       { dir = pack_extensions, source = "org:acme" },
--   })
function ExtensionManager:initialize(roots)
    if type(roots) == "string" then
        roots = { { dir = roots, source = "built-in", create = true } }
    end
    self._roots     = roots or {}
    self.extensions = {}    -- loaded extension instances
    self.skipped    = {}    -- { id, name, source, reason } for extensions not loaded
    self._ctx       = nil   -- last-used HostAPI (for shutdown cleanup)
end

--- Discover plugin entry points under every root.
-- Returns entry tables `{ path, dir, manifest_path, default_id, default_name,
-- source, group }`, root by root in order, each root's entries sorted by path.
-- `group` is the root's tab group (an org pack's `tool_group`), if any.
-- @local
function ExtensionManager:_discover()
    local all = {}
    for _, root in ipairs(self._roots) do
        if root.create then ensure_dir(root.dir) end
        local attr = lfs.attributes(root.dir)
        if attr and attr.mode == "directory" then
            local entries = self:_discoverIn(root.dir)
            for _, e in ipairs(entries) do
                e.source = root.source or root.dir
                e.group = root.group
                all[#all + 1] = e
            end
        end
    end
    return all
end

-- One root's entries, sorted by path.
function ExtensionManager:_discoverIn(root_dir)
    local entries = {}
    local ok_iter, iter, state = pcall(lfs.dir, root_dir)
    if not ok_iter then return entries end
    for name in iter, state do
        if name ~= "." and name ~= ".." then
            local full = path:join(root_dir, name)
            local a = lfs.attributes(full)
            if a and a.mode == "file" and name:match("%.lua$") then
                -- Single-file plugin: requires resolve from the plugins dir itself.
                local stem = name:gsub("%.lua$", "")
                entries[#entries + 1] = {
                    path = full,
                    dir = root_dir,
                    manifest_path = path:join(root_dir, stem .. ".manifest.json"),
                    default_id = Manifest.defaultId(stem),
                    default_name = stem,
                }
            elseif a and a.mode == "directory" then
                local init = path:join(full, "init.lua")
                local ia = lfs.attributes(init)
                if ia and ia.mode == "file" then
                    -- Folder plugin: requires resolve from the plugin's own folder.
                    entries[#entries + 1] = {
                        path = init,
                        dir = full,
                        manifest_path = path:join(full, "manifest.json"),
                        default_id = Manifest.defaultId(name),
                        default_name = name,
                    }
                end
            end
        end
    end
    table.sort(entries, function(a, b) return a.path < b.path end)
    return entries
end

--- Load all plugins found in the plugins directory.
-- Iterates the directory, reads each manifest, compiles and registers each plugin,
-- and calls its `register(ctx)` entry point. The `"(No extensions loaded)"`
-- placeholder in the Extensions menu is created or destroyed here because Win32
-- menu items do not honor the `VISIBLE` attribute and must be added/removed instead.
-- @tparam HostAPI ctx The host API context passed to every extension's `register`.
-- @treturn number Count of extensions successfully loaded.
-- @usage
--   local n = mgr:loadAll(ctx)
--   print(n .. " extension(s) loaded")
function ExtensionManager:loadAll(ctx)
    local iup = ctx.iup
    self._ctx = ctx

    local loaded = 0
    local loaded_from = {}   -- id -> source, to refuse a second extension with the same id
    self.skipped = {}

    local discovered = self:_discover()

    for _, entry in ipairs(discovered) do
        local manifest, merr = Manifest.load(entry.manifest_path, {
            id = entry.default_id,
            name = entry.default_name,
        })
        if not manifest then
            report_plugin_error(iup, ctx, entry, "manifest validation", merr)
        elseif not Manifest.supports(manifest, platform.os) then
            -- Checked before any of the plugin's code runs. Not an error: the
            -- plugin says it needs another OS (e.g. one that drives .BAT builds).
            self.skipped[#self.skipped + 1] = {
                id = manifest.id, name = manifest.name, source = entry.source,
                reason = "needs " .. table.concat(manifest.platforms, " or "),
            }
        elseif (manifest.host_api or 1) > Manifest.HOST_API then
            report_plugin_error(iup, ctx, entry, "compatibility", string.format(
                "needs host API %d; this host provides %d. Update Lunar.",
                manifest.host_api, Manifest.HOST_API))
        elseif loaded_from[manifest.id] then
            report_plugin_error(iup, ctx, entry, "manifest validation", string.format(
                "extension id '%s' from %s is already loaded from %s",
                manifest.id, tostring(entry.source), loaded_from[manifest.id]))
        else
            loaded_from[manifest.id] = entry.source
            -- Make the plugin's own folder resolvable for require() while it loads, so a
            -- folder plugin can ship modules in classes/, ui/, libs/ subdirectories, and
            -- native C modules (.dll / .so) in its root or a native/ subdirectory.
            local saved_path  = package.path
            local saved_cpath = package.cpath
            local sep, lib = platform.sep, platform.lib_ext
            package.path = entry.dir .. sep .. "?.lua;" ..
                           entry.dir .. sep .. "?" .. sep .. "init.lua;" ..
                           saved_path
            package.cpath = entry.dir .. sep .. "?." .. lib .. ";" ..
                            entry.dir .. sep .. "native" .. sep .. "?." .. lib .. ";" ..
                            saved_cpath

            local loader, lerr = loadfile(entry.path)
            if not loader then
                report_plugin_error(iup, ctx, entry, "compile", lerr)
            else
                local ok, ext = pcall(loader)
                if not ok then
                    report_plugin_error(iup, ctx, entry, "initialization", ext)
                elseif not (ext and type(ext) == "table" and ext.register) then
                    report_plugin_error(iup, ctx, entry, "validation", "Plugin must return a table with register(ctx)")
                else
                    local reserved_id = manifest.id
                    manifest = Manifest.mergeRuntime(manifest, ext, {
                        id = entry.default_id,
                        name = entry.default_name,
                    })
                    -- The id checked for duplicates before the code ran is the one
                    -- the extension keeps; it may not rename itself at runtime.
                    if manifest.id ~= reserved_id then
                        report_plugin_error(iup, ctx, entry, "validation", string.format(
                            "extension returns id '%s' but its manifest declares '%s'",
                            tostring(manifest.id), tostring(reserved_id)))
                        package.path, package.cpath = saved_path, saved_cpath
                        goto continue
                    end
                    ext._ctx  = ctx
                    ext._iup  = iup
                    ext._host = ctx
                    -- The extension's own folder, so it can find files it ships
                    -- (an org pack installs extensions outside the app folder).
                    ext.dir   = entry.dir
                    local registered, register_err = true, nil
                    if ctx.registerExtension then
                        registered, register_err = ctx:registerExtension(ext, manifest, entry)
                    end

                    if not registered then
                        report_plugin_error(iup, ctx, entry, "manifest registration", register_err)
                    else
                        local rok, rerr = pcall(ext.register, ext, ctx)
                        if rok then
                            ext.source = entry.source
                            self.extensions[#self.extensions + 1] = ext
                            loaded = loaded + 1
                            -- Surface this extension's version at the top of the Help menu.
                            ctx:addVersionInfo(manifest.name or ext.name, manifest.version or ext.version, ext)
                        else
                            -- Roll back anything a partially-registered extension created.
                            ctx:removeOwned(ext)
                            report_plugin_error(iup, ctx, entry, "register", rerr)
                        end
                    end
                end
            end
            package.path  = saved_path
            package.cpath = saved_cpath
        end
        ::continue::
    end

    if loaded > 0 then
        self:_hidePlaceholder(ctx)
    else
        self:_showPlaceholder(ctx)
    end

    return loaded
end

--- Show the "(No extensions loaded)" placeholder at the top of the Extensions menu.
-- No-op if the placeholder is already present or the Extensions menu is unavailable.
-- @local
function ExtensionManager:_showPlaceholder(ctx)
    if self._placeholder then return end
    local iup  = ctx and ctx.iup
    local menu = ctx and ctx.ext_menu
    if not iup or not menu then return end

    local item = iup.item{ TITLE = "(No extensions loaded)", ACTIVE = "NO" }
    local first = iup.GetChild(menu, 0)
    if first then
        iup.Insert(menu, first, item)
    else
        iup.Append(menu, item)
    end
    iup.Map(item)
    self._placeholder = item
end

--- Remove the "(No extensions loaded)" placeholder from the Extensions menu.
-- The item is destroyed rather than hidden because Win32 menu items do not support
-- the `VISIBLE` attribute.
-- @local
function ExtensionManager:_hidePlaceholder(ctx)
    if not self._placeholder then return end
    local iup = ctx and ctx.iup
    if iup then
        iup.Detach(self._placeholder)
        iup.Destroy(self._placeholder)
    end
    self._placeholder = nil
end

--- Shut down all loaded extensions and remove everything they added to the host.
-- Calls each extension's `shutdown()` method, then invokes `ctx:removeOwned(ext)`
-- to clean up tabs, menu items, timers, and settings. Resets the lazy File/Help
-- menu separators and restores the "(No extensions loaded)" placeholder.
-- @usage mgr:shutdownAll()
function ExtensionManager:shutdownAll()
    local ctx = self._ctx
    for _, ext in ipairs(self.extensions) do
        if ext.shutdown then pcall(ext.shutdown, ext) end
        if ctx then ctx:removeOwned(ext) end
    end
    self.extensions = {}

    -- Rebuild the lazy File/Help separators cleanly on the next load.
    if ctx then ctx:_resetMenuSeparators() end

    -- With no extensions left, restore the placeholder.
    self:_showPlaceholder(ctx)
end

--- Shut down all loaded extensions then reload them with a fresh context.
-- Equivalent to `shutdownAll()` followed by `loadAll(ctx)`.
-- @tparam HostAPI ctx The host API context passed to every extension after reload.
-- @treturn number Count of extensions successfully loaded after reload.
-- @usage local n = mgr:reloadAll(ctx)
function ExtensionManager:reloadAll(ctx)
    self:shutdownAll()
    return self:loadAll(ctx)
end

return ExtensionManager
