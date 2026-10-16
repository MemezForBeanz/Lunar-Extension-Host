--- Extension manifest loader, validator, and merger.
-- Handles the lifecycle of an extension's `manifest.json` from raw JSON
-- on disk through to a normalized, validated Lua table used by the host
-- at runtime.
--
-- **Schema versions**: `1` and `2`. Version 2 adds `platforms`. A manifest that
-- restricts its platforms must say `schema_version: 2`, so a host too old to
-- understand the restriction rejects the plugin instead of silently loading it.
--
-- **Manifest fields** (all optional in the JSON; defaults are derived
-- from the `defaults` argument):
--
-- | Field           | Type         | Notes                                     |
-- |-----------------|--------------|-------------------------------------------|
-- | `schema_version`| number       | 1 or 2 (`SCHEMA_VERSION` is the newest)   |
-- | `id`            | string       | Lowercase, digits, `.`, `_`, `-`          |
-- | `name`          | string       | Human-readable display name               |
-- | `version`       | string       | Semver or any non-empty string            |
-- | `description`   | string       | Optional free-text description            |
-- | `group`         | string       | Default tab group; `/` nests (`"A/B"`)    |
-- | `capabilities`  | string array | Declared capability tokens                |
-- | `provides`      | object       | Sub-arrays: `tabs`, `routes`, `commands`, `settings`, `status` |
-- | `platforms`     | string array | Schema 2 only. `windows`, `linux`, `macos`; omitted = all |
-- | `host_api`      | integer      | Schema 2 only. Oldest host API the extension needs (default 1) |
-- @module core.lib.ExtensionManifest

local cjson = require("cjson")

local M = {}

--- Newest manifest schema this host reads.
M.SCHEMA_VERSION = 2

--- Version of the extension API (`ctx`) this host provides. Raise it when an
-- extension-visible API is added, so extensions that need it can say so.
M.HOST_API = 2  -- 2: ctx:registerTheme, ctx:registerFont

--- Platform names a manifest may list.
M.PLATFORMS = { windows = true, linux = true, macos = true }

local ID_PATTERN = "^[a-z0-9][a-z0-9._%-]*$"

local function trim(value)
	if type(value) ~= "string" then
		return nil
	end
	value = value:gsub("^%s+", ""):gsub("%s+$", "")
	if value == "" then
		return nil
	end
	return value
end

--- Derive a valid manifest `id` from an arbitrary string.
-- Lowercases the input, replaces runs of invalid characters with `-`,
-- strips leading/trailing hyphens, and prepends `"ext-"` if the result
-- does not start with a letter or digit. Falls back to `"extension"`
-- when the input is empty or nil.
-- @tparam[opt] string value input string (e.g. an extension or directory name).
-- @treturn string normalized id matching `^[a-z0-9][a-z0-9._%-]*$`.
-- @usage
-- ExtensionManifest.defaultId("My ROM Validator!")  -- => "my-rom-validator"
-- ExtensionManifest.defaultId(nil)                  -- => "extension"
function M.defaultId(value)
	value = trim(value) or "extension"
	value = value:lower()
	value = value:gsub("[^a-z0-9._%-]+", "-")
	value = value:gsub("%-+", "-")
	value = value:gsub("^%-+", ""):gsub("%-+$", "")
	if value == "" then
		value = "extension"
	end
	if not value:match("^[a-z0-9]") then
		value = "ext-" .. value
	end
	return value
end

local function normalize_string_array(value, label)
	if value == nil then
		return {}
	end
	if type(value) ~= "table" then
		return nil, label .. " must be an array of strings"
	end
	local out = {}
	for i, item in ipairs(value) do
		local text = trim(item)
		if not text then
			return nil, string.format("%s[%d] must be a non-empty string", label, i)
		end
		out[#out + 1] = text
	end
	return out
end

local function normalize_provides(value)
	if value == nil then
		return {}
	end
	if type(value) ~= "table" then
		return nil, "provides must be an object"
	end
	local out = {}
	for _, key in ipairs({ "tabs", "routes", "commands", "settings", "status" }) do
		local normalized, err = normalize_string_array(value[key], "provides." .. key)
		if not normalized then
			return nil, err
		end
		if #normalized > 0 then
			out[key] = normalized
		end
	end
	return out
end

local function copy_table(value)
	local out = {}
	if type(value) == "table" then
		for k, v in pairs(value) do
			out[k] = v
		end
	end
	return out
end

--- Build a default manifest table when no `manifest.json` is present.
-- Used when an extension directory lacks a manifest file or the file
-- cannot be read. All fields are set to safe defaults derived from
-- `defaults`.
-- @tparam[opt] table defaults seed values; recognized keys: `id`, `name`,
--   `version`, `description`, `path`, `source`.
-- @treturn table manifest table with `manifest_source = "implicit"`.
function M.defaultManifest(defaults)
	defaults = defaults or {}
	return {
		schema_version = M.SCHEMA_VERSION,
		id = M.defaultId(defaults.id or defaults.name),
		name = defaults.name or defaults.id or "Extension",
		version = defaults.version or "0.0",
		description = defaults.description,
		group = defaults.group,
		capabilities = {},
		provides = {},
		manifest_path = defaults.path,
		manifest_source = defaults.source or "implicit",
	}
end

--- Validate and normalize a decoded manifest table.
-- Checks the schema version, normalizes string fields, validates the `id`
-- character pattern, and normalizes `capabilities` and `provides` arrays.
-- @tparam table manifest decoded manifest object (e.g. from `cjson.decode`).
-- @tparam[opt] table defaults fallback values for missing required fields;
--   same keys as `defaultManifest`.
-- @treturn[1] table normalized manifest table with `manifest_source = "file"`.
-- @treturn[2] nil on validation error.
-- @treturn[2] string error message.
function M.validate(manifest, defaults)
	defaults = defaults or {}
	if type(manifest) ~= "table" then
		return nil, "manifest must decode to an object"
	end

	local schema_version = tonumber(manifest.schema_version) or 1
	if schema_version ~= 1 and schema_version ~= 2 then
		return nil, string.format(
			"unsupported manifest schema_version %s (this host reads 1 to %d)",
			tostring(manifest.schema_version),
			M.SCHEMA_VERSION
		)
	end

	local platforms
	if manifest.platforms ~= nil then
		if schema_version < 2 then
			return nil, "platforms needs schema_version 2"
		end
		local list, perr = normalize_string_array(manifest.platforms, "platforms")
		if not list then return nil, perr end
		if #list == 0 then return nil, "platforms must list at least one platform" end
		for _, p in ipairs(list) do
			if not M.PLATFORMS[p] then
				return nil, "unknown platform '" .. p .. "' (use windows, linux or macos)"
			end
		end
		platforms = list
	end

	local host_api
	if manifest.host_api ~= nil then
		if schema_version < 2 then
			return nil, "host_api needs schema_version 2"
		end
		host_api = tonumber(manifest.host_api)
		if not host_api or host_api < 1 or host_api % 1 ~= 0 then
			return nil, "host_api must be a whole number of at least 1"
		end
	end

	local explicit_id = trim(manifest.id)
	if explicit_id and not explicit_id:match(ID_PATTERN) then
		return nil, "manifest id must contain only lowercase letters, digits, '.', '_' or '-'"
	end
	local id = explicit_id or M.defaultId(defaults.id or defaults.name)

	local name = trim(manifest.name) or defaults.name
	if not name then
		return nil, "manifest name is required"
	end

	local version = trim(manifest.version) or defaults.version
	if not version then
		return nil, "manifest version is required"
	end

	local capabilities, cap_err = normalize_string_array(manifest.capabilities, "capabilities")
	if not capabilities then
		return nil, cap_err
	end

	local provides, provides_err = normalize_provides(manifest.provides)
	if not provides then
		return nil, provides_err
	end

	return {
		schema_version = schema_version,
		id = id,
		name = name,
		version = version,
		description = trim(manifest.description),
		-- Default tab group. Advisory only: core.classes.TabGroups applies it the
		-- first time a tab is seen and never again, so a user who regroups the tab
		-- is not overruled on the next launch.
		group = trim(manifest.group),
		capabilities = capabilities,
		provides = provides,
		-- nil means "every platform".
		platforms = platforms,
		host_api = host_api,
		manifest_path = defaults.path,
		manifest_source = defaults.source or "file",
	}
end

--- Can this extension run on `os_name`?
-- @tparam table manifest A validated manifest.
-- @tparam string os_name `"windows"`, `"linux"` or `"macos"` (`core.platform.os`).
-- @treturn boolean
function M.supports(manifest, os_name)
	if type(manifest) ~= "table" or manifest.platforms == nil then return true end
	for _, p in ipairs(manifest.platforms) do
		if p == os_name then return true end
	end
	return false
end

--- Load and validate a manifest from a JSON file on disk.
-- Returns a default manifest (via `defaultManifest`) when `path` is nil,
-- empty, or the file cannot be opened.
-- @tparam string path absolute or relative path to `manifest.json`.
-- @tparam[opt] table defaults fallback values forwarded to `validate` /
--   `defaultManifest`; same keys as `defaultManifest`.
-- @treturn[1] table normalized manifest table.
-- @treturn[2] nil when JSON decoding or schema validation fails.
-- @treturn[2] string error message.
function M.load(path, defaults)
	defaults = copy_table(defaults)
	defaults.path = path
	if type(path) ~= "string" or path == "" then
		return M.defaultManifest(defaults)
	end

	local f = io.open(path, "rb")
	if not f then
		return M.defaultManifest(defaults)
	end
	local raw = f:read("*a")
	f:close()

	local ok, decoded = pcall(cjson.decode, raw)
	if not ok then
		return nil, "manifest decode failed: " .. tostring(decoded)
	end
	defaults.source = "file"
	return M.validate(decoded, defaults)
end

--- Merge file-based manifest fields with runtime-declared extension metadata.
-- Applies overrides from `ext` (id, name, version) onto a shallow copy of
-- `manifest`, then back-fills any missing fields on `ext` from the merged
-- result. Also sets `ext.manifest` to the merged table.
--
-- Called by the host after loading an extension so that runtime-declared
-- metadata takes precedence over `manifest.json` values.
-- @tparam[opt] table manifest base manifest table, e.g. from `load`.
-- @tparam[opt] table ext extension object; `id`, `name`, `version`, and
--   `manifest` fields may be mutated in place.
-- @tparam[opt] table defaults forwarded to `defaultManifest` when `manifest` is nil.
-- @treturn table the merged manifest table (a shallow copy of `manifest`).
function M.mergeRuntime(manifest, ext, defaults)
	local merged = copy_table(manifest or M.defaultManifest(defaults))
	merged.capabilities = normalize_string_array(merged.capabilities, "capabilities") or {}
	merged.provides = copy_table(merged.provides)

	if type(ext) == "table" then
		if trim(ext.id) then
			merged.id = M.defaultId(ext.id)
		end
		if trim(ext.name) then
			merged.name = ext.name
		end
		if trim(ext.version) then
			merged.version = ext.version
		end
		if trim(ext.group) then
			merged.group = trim(ext.group)
		end
		ext.id = ext.id or merged.id
		ext.name = ext.name or merged.name
		ext.version = ext.version or merged.version
		ext.manifest = merged
	end

	return merged
end

return M
