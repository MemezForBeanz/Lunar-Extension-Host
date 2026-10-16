--- Manages persistent application settings in `settings.json` under the per-user config folder (`%APPDATA%\Lunar Extension Host`, `~/.config/lunar`).
--
-- A value comes from the first of these layers that has one:
--
--   1. **Locked** by the org profile (`applyProfile`). `set` refuses these keys.
--   2. **User**: anything the user (or an extension) set, and everything loaded
--      from `settings.json`. Only this layer is saved.
--   3. **Org defaults** from the profile.
--   4. **Built-in defaults** (`DEFAULTS` below).
--
-- Keys outside `DEFAULTS` are kept, so extension settings survive a restart.
-- One-time migrations carry legacy `onboarding_*` flags over to `welcome_tour_*`,
-- and the org profile may retire defaults older builds saved (see applyProfile).
--
-- @classmod core.classes.SettingsManager

local class = require("middleclass")
local lfs   = require("lfs")
local cjson = require("cjson")
local platform = require("core.platform")
local path = platform.path

local SettingsManager = class("SettingsManager")

-- The host's own settings. Extensions keep theirs in the same file and supply
-- their own defaults (`get` returns nil for a key nobody set).
local DEFAULTS = {
    theme               = "classic_dark",
    welcome_tour_completed = false,
    welcome_tour_dismissed = false,
    -- Shared backend (feedback; extensions may use it too). Empty in the neutral
    -- build so a fresh install makes no network calls; an org profile
    -- (core.lib.OrgProfile) supplies the URL. Best-effort: an unreachable server
    -- never affects local operation.
    backend_url          = "",
    -- TLS for the backend. "peer" checks the certificate chain and host name;
    -- "none" only encrypts. backend_ca_file adds a trust anchor (an internal CA).
    backend_tls_verify   = "peer",
    backend_ca_file      = "",
    -- Folder or share holding manifest.json for update checks. Empty: no update
    -- checks (the neutral build); an org profile points it at its release share.
    update_share         = "",
    -- core.ui.FolderDialog places: absolute folder paths. Favourites are pinned by
    -- the user; recents are most-recent-first and capped by the dialog.
    folder_favourites    = {},
    folder_recents       = {},
    -- Tab layout: tab_groups is a nested tree of tabs and groups (see
    -- core.classes.TabGroups). tab_order is the pre-groups format, read once to
    -- migrate and no longer written.
    tab_order            = "",
    tab_groups           = {},
    -- UI motion (core.classes.MotionDirector, docs/motion.md). motion_enabled turns
    -- off every animation, host and extensions alike; motion_scale multiplies every
    -- duration (2.0 is half speed). motion_respect_system follows the OS "show
    -- animations" accessibility setting, which people with vestibular disorders
    -- rely on, so it stays on by default.
    motion_enabled        = true,
    motion_scale          = 1.0,
    motion_respect_system = true,
}

local COPY_CHUNK = 64 * 1024

-- Copy one file in bounded chunks, checking every read, write and close, so a
-- full disk or locked file reports failure instead of leaving a silent truncation.
local function copy_file(from, to)
    local fin = io.open(from, "rb")
    if not fin then return false end
    local fout = io.open(to, "wb")
    if not fout then fin:close(); return false end
    local ok = true
    while ok do
        local chunk = fin:read(COPY_CHUNK)
        if not chunk then break end
        ok = fout:write(chunk) ~= nil
    end
    fin:close()
    return (fout:close() ~= nil) and ok
end

-- Recursively copy `src` into `dst`. Returns false if anything could not be copied.
-- lfs.dir raises on an unreadable folder, so callers must run this under pcall.
local function copy_tree(src, dst)
    if not lfs.attributes(dst, "mode") and not lfs.mkdir(dst) then return false end
    for name in lfs.dir(src) do
        if name ~= "." and name ~= ".." then
            local from, to = path:join(src, name), path:join(dst, name)
            local mode = lfs.attributes(from, "mode")
            if mode == "directory" then
                if not copy_tree(from, to) then return false end
            elseif mode == "file" then
                if not copy_file(from, to) then return false end
            end
        end
    end
    return true
end

-- Best-effort recursive delete, used to clear a failed or interrupted staging copy.
local function remove_tree(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    pcall(function()
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                local p = dir .. platform.sep .. name
                if lfs.attributes(p, "mode") == "directory" then remove_tree(p) else os.remove(p) end
            end
        end
    end)
    lfs.rmdir(dir)
end

-- Copy the legacy folder into `<cfg_dir>.migrating` and rename it into place
-- only once every file copied. A failure leaves no `cfg_dir` behind, so the next
-- launch retries instead of treating a half-copied folder as done.
local function migrate_legacy(legacy, cfg_dir)
    local staging = cfg_dir .. ".migrating"
    remove_tree(staging)  -- left over from an interrupted earlier attempt
    local ran, copied = pcall(copy_tree, legacy, staging)
    if ran and copied and os.rename(staging, cfg_dir) then
        return true
    end
    remove_tree(staging)
    return false
end

--- Create a new SettingsManager and initialize storage paths.
-- Locates (or creates) the per-user config directory and seeds the in-memory
-- store with default values. Call `load()` to overlay saved values from disk.
--
-- When the config folder doesn't exist yet and `opts.legacy_dir_name` names a
-- sibling folder that does (the org's pre-Lunar build; see the profile's
-- `legacy_config_dir`), that folder is **copied** to the new location. Copied,
-- not moved, so the old build on the same machine keeps its settings. If the copy
-- fails, this session keeps using the old folder (`migration_complete` is false)
-- and the next launch tries again.
-- @tparam[opt] table opts `{ legacy_dir_name = string }`.
-- @usage
--   local settings = SettingsManager:new()
--   settings:load()
function SettingsManager:initialize(opts)
    local cfg_dir = platform.config_dir()
    local legacy_name = opts and opts.legacy_dir_name
    if not lfs.attributes(cfg_dir) then
        local legacy = legacy_name and path:join(path:dirname(cfg_dir), legacy_name)
        if legacy and lfs.attributes(legacy, "mode") == "directory" then
            self.migrated_from = legacy
            self.migration_complete = migrate_legacy(legacy, cfg_dir)
            if not self.migration_complete then cfg_dir = legacy end
        else
            -- Parents too: on Linux ~/.config (or $XDG_CONFIG_HOME) may not exist yet.
            local ok, err = platform.mkdirs(cfg_dir)
            if not ok then self.storage_error = err end
        end
    end
    self._cfg_dir = cfg_dir
    self._path = path:join(cfg_dir, "settings.json")
    self._user = {}       -- what the user set; the only layer that is saved
    self._org = nil       -- the applied org profile, if any
    self._org_defaults = {}
    self._locked = {}
end

--- Return the per-user config directory (`%APPDATA%\Lunar Extension Host`, `~/.config/lunar`).
-- Stable across runs and independent of the process working directory. Useful for
-- storing extension-specific data alongside the main settings file.
-- @treturn string Absolute path to the config directory.
-- @usage local cfgDir = settings:getConfigDir()
function SettingsManager:getConfigDir()
    return self._cfg_dir
end

-- Version of the settings.json layout. Migrations run once, when a file older
-- than this is loaded; save() stamps it.
local SETTINGS_SCHEMA = 2

--- Load saved settings from `settings.json` into the user layer.
-- Every key in the file is kept (extension settings included). Applies one-time
-- legacy migrations and re-saves when one was performed.
-- @usage settings:load()
function SettingsManager:load()
    -- A save that died after writing the temporary file but before swapping it in
    -- leaves the old settings.json in place; only fall back to the .tmp when the
    -- main file is gone.
    local f = io.open(self._path, "r") or io.open(self._path .. ".tmp", "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(cjson.decode, content)
    if not ok or type(data) ~= "table" then return end

    local migrated = false
    for k, v in pairs(data) do
        if type(k) == "string" then self._user[k] = v end
    end
    -- Older builds recorded the welcome tour under onboarding_* keys. Carry a
    -- legacy flag over once so users who finished or dismissed the tour don't
    -- see it again.
    local user = self._user
    -- Written before Lunar: org profiles may retire defaults those builds saved.
    -- Recorded in the file, so it survives until a profile that retires values has
    -- actually been applied and saved (see applyProfile).
    local legacy = (tonumber(user.settings_schema) or 1) < 2
    if legacy then user.pending_retirement = true end
    if user.onboarding_completed ~= nil or user.onboarding_dismissed ~= nil then
        if user.onboarding_completed == true then user.welcome_tour_completed = true end
        if user.onboarding_dismissed == true then user.welcome_tour_dismissed = true end
        user.onboarding_completed, user.onboarding_dismissed = nil, nil
        migrated = true
    end
    if legacy then migrated = true end  -- stamps settings_schema
    if migrated then self:save() end
end

--- Write the user layer to `settings.json`.
-- Writes a temporary file and swaps it in with a single replace, so a crash or a
-- full disk can't leave a truncated or missing settings file; on failure the old
-- file is untouched. Returns false if the write failed.
-- @treturn boolean Whether the settings were written.
-- @usage settings:save()
function SettingsManager:save()
    self._user.settings_schema = SETTINGS_SCHEMA
    local tmp = self._path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    local ok_enc, text = pcall(cjson.encode, self._user)
    local written = ok_enc and f:write(text) ~= nil
    local closed = f:close() ~= nil
    if not (written and closed) then
        os.remove(tmp)
        return false
    end
    -- One-step replace (MoveFileEx on Windows, rename(2) on Linux).
    if not platform.replace_file(tmp, self._path) then
        os.remove(tmp)
        return false
    end
    return true
end

--- Get the value of a setting by key.
-- Locked org value, else the user's value, else the org default, else the
-- built-in default. Returns `nil` for an unknown key that was never set.
-- @tparam string key Setting key (e.g. `"theme"`).
-- @return The current value of the setting (type depends on the key).
-- @usage local theme = settings:get("theme")
function SettingsManager:get(key)
    if self._locked[key] then return self._org_defaults[key] end
    local v = self._user[key]
    if v ~= nil then return v end
    v = self._org_defaults[key]
    if v ~= nil then return v end
    return DEFAULTS[key]
end

--- Set the value of a setting by key (in-memory only).
-- Call `save()` afterward to persist the change to disk. A key locked by the org
-- profile is refused.
-- @tparam string key Setting key.
-- @param value New value for the setting.
-- @treturn[1] boolean `true` when the value was set.
-- @treturn[2] boolean `false` when the key is locked.
-- @treturn[2] string `"locked"`.
-- @usage settings:set("theme", "classic"); settings:save()
function SettingsManager:set(key, value)
    if self._locked[key] then return false, "locked" end
    self._user[key] = value
    return true
end

--- Apply an org profile (see `core.lib.OrgProfile`), or `nil` to run neutral.
-- Its `settings` become org defaults and its `locked` keys override the user.
-- When the settings file predates Lunar, user values the profile lists in
-- `retired` (defaults older builds saved, not choices the user made) are dropped
-- and the file is saved, so the org default applies. That happens once, the first
-- time a retiring profile is applied and the save succeeds; until then the file
-- keeps `pending_retirement`, so a launch without the pack doesn't lose it.
-- @tparam[opt] table profile A profile from `OrgProfile.resolve`.
-- @usage settings:applyProfile(profile)
function SettingsManager:applyProfile(profile)
    self._org = profile
    self._org_defaults = (profile and profile.settings) or {}
    self._locked = (profile and profile.locked) or {}
    if self._user.pending_retirement and profile and profile.retired and next(profile.retired) then
        local dropped = {}
        for key, values in pairs(profile.retired) do
            local v = self._user[key]
            if v ~= nil and values[v] then
                dropped[key] = v
                self._user[key] = nil
            end
        end
        self._user.pending_retirement = nil
        if not self:save() then
            -- Not on disk: put everything back so the next launch tries again.
            for key, v in pairs(dropped) do self._user[key] = v end
            self._user.pending_retirement = true
        end
    end
end

--- The applied org profile, or `nil` when running neutral.
-- @treturn table|nil
function SettingsManager:getProfile()
    return self._org
end

--- Whether the org profile locks `key`, so the UI can show it as managed.
-- @tparam string key Setting key.
-- @treturn boolean
function SettingsManager:isLocked(key)
    return self._locked[key] == true
end

return SettingsManager