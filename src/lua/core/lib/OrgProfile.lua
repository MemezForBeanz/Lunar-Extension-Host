--- Organization profiles: which company a Lunar install belongs to, and what that
-- company configures (its tool group, logo, endpoints, default and locked settings).
--
-- Lunar looks the same for every org: a profile doesn't rename or recolour the
-- app. The org shows up as a tab group holding its pack's tools (`tool_group`,
-- e.g. "Acme Tools"), a small logo in the status bar, and its settings
-- (which may pick a default theme the pack ships).
--
-- A profile is **data only**: a folder holding `profile.json` plus its assets. It
-- never contains code. Profiles are installed by an administrator (an org's
-- MSI/deb, or a copy step) into a protected location:
--
--   * Windows: `%ProgramData%\Lunar Extension Host\profiles\<id>\profile.json`
--   * Linux:   `/etc/lunar/profiles/<id>/profile.json`
--
-- `LUNAR_PROFILE_DIR` adds one more root for development. A user can set that
-- variable, so profiles found there are **untrusted**: they apply their defaults
-- but their `locked` list is ignored.
--
-- **Selection**, first match wins:
--
--   1. An explicit assignment: `policy.json` (`{ "profile": "<id>" }`) beside the
--      trusted `profiles` folder.
--   2. The machine's DNS domain matching exactly one profile's `match.domains`
--      (exact name or a subdomain of it).
--   3. Otherwise the neutral profile (`nil`): plain Lunar, no org settings.
--
-- Detection only *chooses configuration*. It authenticates nothing, and since
-- extensions run unrestricted code it is not a security boundary either; the
-- protected install location is what keeps a user from replacing an org's policy.
-- So the trusted root is checked, not assumed: the system folder, `profiles`,
-- `policy.json`, and everything inside each pack (walked, links refused) must be
-- changeable by administrators only (`core.platform.admin_only`). On a default
-- Windows install ordinary users can create folders under `%ProgramData%`, so the
-- installer must create `Lunar Extension Host` with admin-only access; anything
-- that fails the check is ignored and reported in the diagnostics.
--
-- @module core.lib.OrgProfile

local M = {}

--- Profile schema version this build understands.
M.SCHEMA = 1

local SEP = package.config:sub(1, 1)
local ID_PATTERN = "^[a-z0-9][a-z0-9%-]*$"
local MAX_GROUP = 64

local function join(...)
	return table.concat({ ... }, SEP)
end

-- Default file access; tests pass their own through `opts.fs`.
local default_fs = {
	read = function(path)
		local f = io.open(path, "rb")
		if not f then return nil end
		local s = f:read("*a")
		f:close()
		return s
	end,
	-- Returns the sub-folder names, plus an error when the folder exists but can't
	-- be listed (lfs.dir raises on access denied; that must not abort startup).
	dirs = function(path)
		local ok_lfs, lfs = pcall(require, "lfs")
		local out = {}
		if not ok_lfs or lfs.attributes(path, "mode") ~= "directory" then return out end
		local ok, err = pcall(function()
			for name in lfs.dir(path) do
				if name ~= "." and name ~= ".."
					and lfs.attributes(path .. SEP .. name, "mode") == "directory" then
					out[#out + 1] = name
				end
			end
		end)
		table.sort(out)
		if not ok then return out, tostring(err) end
		return out
	end,
	exists = function(path)
		local f = io.open(path, "rb")
		if f then f:close() return true end
		return false
	end,
	-- Every folder and file below `dir`, without following links (a link fails the
	-- admin-only check by itself). Capped, so a junction loop can't hang startup.
	walk = function(dir)
		local ok_lfs, lfs = pcall(require, "lfs")
		if not ok_lfs then return nil, "lfs unavailable" end
		local out, limit = {}, 20000
		local function visit(d)
			for name in lfs.dir(d) do
				if name ~= "." and name ~= ".." then
					local path = d .. SEP .. name
					out[#out + 1] = path
					if #out > limit then error("more than " .. limit .. " entries", 0) end
					local link = lfs.symlinkattributes and lfs.symlinkattributes(path, "mode")
					if link ~= "link" and lfs.attributes(path, "mode") == "directory" then visit(path) end
				end
			end
		end
		local ok, err = pcall(visit, dir)
		if not ok then return nil, tostring(err) end
		return out
	end,
	is_dir = function(path)
		local ok_lfs, lfs = pcall(require, "lfs")
		return ok_lfs and lfs.attributes(path, "mode") == "directory"
	end,
	-- Is this folder or file changeable by administrators only? Filled in below
	-- from core.platform; a test fs without it skips the check.
	secure = nil,
}

local function decode_json(text)
	local ok_cjson, cjson = pcall(require, "cjson")
	if not ok_cjson then return nil, "cjson unavailable" end
	local ok, data = pcall(cjson.decode, text)
	if not ok then return nil, "invalid JSON: " .. tostring(data) end
	if type(data) ~= "table" then return nil, "profile must be a JSON object" end
	return data
end

-- An asset path must stay inside the pack folder: relative, no `..`, no drive.
local function confined(rel)
	if type(rel) ~= "string" or rel == "" then return false end
	if rel:match("^[/\\]") or rel:match("^%a:") then return false end
	for seg in rel:gmatch("[^/\\]+") do
		if seg == ".." then return false end
	end
	return true
end

local function is_array_of_strings(t)
	if type(t) ~= "table" then return false end
	for k, v in pairs(t) do
		if type(k) ~= "number" or type(v) ~= "string" then return false end
	end
	return true
end

--- Check a decoded `profile.json` table and build the profile record.
-- @tparam table data Decoded JSON.
-- @tparam string dir The pack folder (used to resolve and confine assets).
-- @tparam[opt] table opts `{ trusted = bool, fs = table, dir_name = string }`.
-- @treturn[1] table The profile: `{ id, name, version, trusted, dir, domains,
--   tool_group, brand = { logo }, settings, locked, retired, legacy_config_dir }`.
--   `tool_group` is the tab group the pack's extensions open in (the file's
--   `tool_group`, else the profile name).
--   `locked` is a set (`key -> true`), empty when the profile is untrusted.
--   `retired` maps a setting key to a set of values older builds saved as
--   defaults (`retired_defaults` in the file; see `SettingsManager:applyProfile`).
--   `legacy_config_dir` is the org's pre-Lunar config folder name, if any.
-- @treturn[2] nil
-- @treturn[2] string Why the profile was rejected.
function M.validate(data, dir, opts)
	opts = opts or {}
	local fs = opts.fs or default_fs
	if type(data) ~= "table" then return nil, "profile must be a JSON object" end
	if data.schema ~= M.SCHEMA then
		return nil, string.format("unsupported schema %s (this build reads %d)",
			tostring(data.schema), M.SCHEMA)
	end
	if type(data.id) ~= "string" or not data.id:match(ID_PATTERN) then
		return nil, "id must be lowercase letters, digits and dashes"
	end
	if opts.dir_name and opts.dir_name ~= data.id then
		return nil, string.format("id %q does not match its folder %q", data.id, opts.dir_name)
	end
	if type(data.name) ~= "string" or data.name == "" then
		return nil, "name is required"
	end

	local domains = {}
	local match = data.match
	if match ~= nil then
		if type(match) ~= "table" or (match.domains ~= nil and not is_array_of_strings(match.domains)) then
			return nil, "match.domains must be a list of strings"
		end
		for _, d in ipairs(match.domains or {}) do
			d = d:lower():gsub("^%.+", "")
			if d ~= "" then domains[#domains + 1] = d end
		end
	end

	-- The tool group and logo are cosmetic, so a bad value is dropped with a
	-- warning; it must never cost the org its settings and locks.
	local brand, warnings = {}, {}
	local function warn(msg) warnings[#warnings + 1] = msg end

	-- The tab group the pack's extensions open in. One level: "/" nests groups.
	local tool_group = data.name
	if data.tool_group ~= nil then
		local g = data.tool_group
		if type(g) == "string" and g:match("%S") and #g <= MAX_GROUP and not g:find("[/\\%c]") then
			tool_group = g:match("^%s*(.-)%s*$")
		else
			warn("tool_group must be a name without slashes, up to " .. MAX_GROUP .. " characters; using the profile name")
		end
	end
	if tool_group:find("[/\\%c]") or #tool_group > MAX_GROUP then
		tool_group = data.id
	end

	local b = data.brand
	if b ~= nil and type(b) ~= "table" then
		warn("brand must be an object; ignored")
		b = nil
	end
	if b then
		for _, key in ipairs({ "product_name", "accent", "accent_fg" }) do
			if b[key] ~= nil then
				warn("brand." .. key .. " is no longer used: Lunar looks the same for every org")
			end
		end
		if b.logo ~= nil then
			if not confined(b.logo) or not b.logo:lower():match("%.svg$") then
				warn("brand.logo must be an .svg path inside the profile folder; ignored")
			else
				local path = dir .. SEP .. (b.logo:gsub("[/\\]", SEP))
				if fs.exists(path) then
					brand.logo = path
				else
					warn("brand.logo not found: " .. b.logo)
				end
			end
		end
	end

	local settings = {}
	if data.settings ~= nil then
		if type(data.settings) ~= "table" then return nil, "settings must be an object" end
		for k, v in pairs(data.settings) do
			if type(k) ~= "string" then return nil, "settings keys must be strings" end
			if type(v) == "function" or type(v) == "userdata" then
				return nil, "settings." .. k .. " has an unsupported type"
			end
			-- "pack:<relative path>" names a file shipped inside this pack (a CA
			-- certificate, a template) and becomes its absolute path.
			if type(v) == "string" and v:sub(1, 5) == "pack:" then
				local rel = v:sub(6)
				if not confined(rel) then
					return nil, "settings." .. k .. " must name a file inside the profile folder"
				end
				v = dir .. SEP .. (rel:gsub("[/\\]", SEP))
			end
			settings[k] = v
		end
	end

	-- Values older builds saved as defaults; SettingsManager drops them from a
	-- pre-Lunar settings file. Like branding, a bad entry is only a warning.
	local retired = {}
	if data.retired_defaults ~= nil then
		if type(data.retired_defaults) ~= "table" then
			warn("retired_defaults must be an object; ignored")
		else
			for k, list in pairs(data.retired_defaults) do
				local ok = type(k) == "string" and type(list) == "table"
				if ok then
					for i, v in pairs(list) do
						local tv = type(v)
						if type(i) ~= "number" or not (tv == "string" or tv == "number" or tv == "boolean") then
							ok = false
						end
					end
				end
				if ok then
					retired[k] = {}
					for _, v in ipairs(list) do retired[k][v] = true end
				else
					warn("retired_defaults." .. tostring(k) .. " must be a list of values; ignored")
				end
			end
		end
	end

	-- The per-user config folder name the org's pre-Lunar build used (a sibling of
	-- Lunar's own); SettingsManager copies it over on first run. A bare folder name,
	-- so it can't point anywhere else. Optional, so a bad value is only a warning.
	local legacy_config_dir
	if data.legacy_config_dir ~= nil then
		local v = data.legacy_config_dir
		if type(v) == "string" and v ~= "" and #v <= 128 and not v:find("[/\\:%c]")
			and v ~= "." and v ~= ".." then
			legacy_config_dir = v
		else
			warn("legacy_config_dir must be a plain folder name; ignored")
		end
	end

	local locked = {}
	if data.locked ~= nil then
		if not is_array_of_strings(data.locked) then return nil, "locked must be a list of setting keys" end
		for _, k in ipairs(data.locked) do
			if settings[k] == nil then
				return nil, "locked key " .. k .. " has no value in settings"
			end
			if opts.trusted then locked[k] = true end
		end
	end

	return {
		id = data.id,
		name = data.name,
		version = data.version,
		trusted = opts.trusted and true or false,
		dir = dir,
		domains = domains,
		tool_group = tool_group,
		brand = brand,
		settings = settings,
		locked = locked,
		retired = retired,
		legacy_config_dir = legacy_config_dir,
		warnings = warnings,
	}
end

--- Load and validate the profile in one pack folder.
-- @tparam string dir Pack folder (its name must equal the profile id).
-- @tparam[opt] table opts `{ trusted = bool, fs = table }`.
-- @treturn[1] table The profile (see `validate`).
-- @treturn[2] nil
-- @treturn[2] string Error.
function M.load(dir, opts)
	opts = opts or {}
	local fs = opts.fs or default_fs
	local text = fs.read(join(dir, "profile.json"))
	if not text then return nil, "no profile.json in " .. dir end
	local data, err = decode_json(text)
	if not data then return nil, err end
	local dir_name = dir:match("([^/\\]+)[/\\]*$")
	return M.validate(data, dir, { trusted = opts.trusted, fs = fs, dir_name = dir_name })
end

-- ---------------------------------------------------------------------------
-- System values. Both come from the OS through core.platform, NOT the
-- environment: a user can launch the app with ProgramData or USERDNSDOMAIN set to
-- anything, which would let them swap in their own "trusted" folder or fall back
-- to neutral and shed the org's locks.
-- ---------------------------------------------------------------------------

local ok_platform, platform = pcall(require, "core.platform")
if not ok_platform then platform = nil end
if platform and platform.admin_only then default_fs.secure = platform.admin_only end

--- This machine's DNS domain as the OS reports it, or nil.
-- @treturn string|nil
function M.system_dns_domain()
	return platform and platform.dns_domain() or nil
end

--- The folders profiles are installed into, most trusted first.
-- @tparam[opt] table opts `{ env = function, system_dir = string }` (tests
--   override both; by default the system folder comes from `core.platform`:
--   `%ProgramData%\Lunar Extension Host` or `/etc/lunar`).
-- @treturn table List of `{ dir = string, trusted = bool }`.
function M.roots(opts)
	opts = opts or {}
	local env = opts.env or os.getenv
	local roots = {}
	local sys = opts.system_dir or (platform and platform.system_dir())
	if sys and sys ~= "" then
		roots[#roots + 1] = { dir = join(sys, "profiles"), trusted = true }
	end
	local dev = env("LUNAR_PROFILE_DIR")
	if dev and dev ~= "" then
		roots[#roots + 1] = { dir = dev, trusted = false }
	end
	return roots
end
-- True when `domain` is `want` or a subdomain of it (label boundary, not substring).
local function domain_matches(domain, want)
	if domain == want then return true end
	return #domain > #want and domain:sub(-(#want + 1)) == "." .. want
end

local function domain_hits(list, domain)
	local hits = {}
	for _, p in ipairs(list) do
		for _, want in ipairs(p.domains) do
			if domain_matches(domain, want) then
				hits[#hits + 1] = p
				break
			end
		end
	end
	return hits
end

--- Find the profile this install should use.
-- @tparam[opt] table opts `{ env = function, fs = table, roots = table, domain = string,
--   dev_select = string }`. `domain` overrides the system DNS domain (tests,
--   diagnostics). `dev_select` picks a profile by id, trusted or not, ahead of
--   everything else; main.lua passes it only in a development build.
-- @treturn[1] table The selected profile.
-- @treturn[2] nil When the install should run neutral.
-- @treturn table Diagnostics: `{ reason = string, errors = { string, ... },
--   warnings = { string, ... }, available = { id, ... } }`. `reason` is one of
--   `"assigned"`, `"domain"`, `"none"`, `"ambiguous"` or `"assigned-missing"`.
function M.resolve(opts)
	opts = opts or {}
	local fs = opts.fs or default_fs
	local roots = opts.roots or M.roots({ env = opts.env })
	local info = { errors = {}, warnings = {}, available = {} }

	-- Trusted roots must be admin-only all the way down to each pack; anything a
	-- non-admin could have written is ignored. Returns true or false plus the reason.
	local function protected(paths)
		if not fs.secure then return true end
		for _, path in ipairs(paths) do
			local ok, why = fs.secure(path)
			if not ok then return false, path .. " is not admin-only (" .. tostring(why) .. ")" end
		end
		return true
	end
	local function parent_of(dir) return dir:match("^(.*)[/\\][^/\\]+[/\\]*$") end

	local trusted, untrusted, trusted_by_id, seen = {}, {}, {}, {}
	for _, root in ipairs(roots) do
		local names, derr = fs.dirs(root.dir)
		if derr then info.errors[#info.errors + 1] = root.dir .. ": cannot list (" .. derr .. ")" end
		if root.trusted and #names > 0 then
			local ok, why = protected({ parent_of(root.dir) or root.dir, root.dir })
			if not ok then
				info.errors[#info.errors + 1] = "ignoring installed profiles: " .. why
				names = {}
			end
		end
		-- Hidden folders (.git in a dev checkout of packs) are never packs.
		local visible = {}
		for _, name in ipairs(names) do
			if name:sub(1, 1) ~= "." then visible[#visible + 1] = name end
		end
		names = visible
		for _, name in ipairs(names) do
			local dir = join(root.dir, name)
			local p, err
			if root.trusted then
				-- The whole pack: profile.json, extension code, certificates, assets.
				local paths = { dir }
				if fs.walk then
					local all, werr = fs.walk(dir)
					if not all then err = dir .. ": cannot check (" .. tostring(werr) .. ")" end
					for _, path in ipairs(all or {}) do paths[#paths + 1] = path end
				else
					if fs.exists(join(dir, "profile.json")) then paths[#paths + 1] = join(dir, "profile.json") end
					if fs.is_dir and fs.is_dir(join(dir, "extensions")) then
						paths[#paths + 1] = join(dir, "extensions")
					end
				end
				if not err then
					local ok, why = protected(paths)
					if not ok then err = why end
				end
			end
			if not err then p, err = M.load(dir, { trusted = root.trusted, fs = fs }) end
			if not p then
				info.errors[#info.errors + 1] = name .. ": " .. err
			elseif not seen[p.id] then  -- a trusted root shadows a dev copy of the same id
				seen[p.id] = true
				info.available[#info.available + 1] = p.id
				for _, w in ipairs(p.warnings) do info.warnings[#info.warnings + 1] = p.id .. ": " .. w end
				if p.trusted then
					trusted[#trusted + 1] = p
					trusted_by_id[p.id] = p
				else
					untrusted[#untrusted + 1] = p
				end
			end
		end
	end

	-- 0. Development override (dev builds only; see main.lua).
	if type(opts.dev_select) == "string" and opts.dev_select ~= "" then
		for _, list in ipairs({ trusted, untrusted }) do
			for _, p in ipairs(list) do
				if p.id == opts.dev_select then
					info.reason = "dev-selected"
					return p, info
				end
			end
		end
		info.errors[#info.errors + 1] = "LUNAR_PROFILE names unknown profile " .. opts.dev_select
	end

	-- 1. Explicit assignment, read from and resolved against trusted roots only.
	for _, root in ipairs(roots) do
		local parent = root.trusted and parent_of(root.dir)
		local text = parent and fs.read(join(parent, "policy.json"))
		if text then
			local ok, why = protected({ parent, join(parent, "policy.json") })
			if not ok then
				info.errors[#info.errors + 1] = "ignoring policy.json: " .. why
				text = nil
			end
		end
		if text then
			local policy = decode_json(text)
			if type(policy) == "table" and type(policy.profile) == "string" then
				local p = trusted_by_id[policy.profile]
				if p then
					info.reason = "assigned"
					return p, info
				end
				info.reason = "assigned-missing"
				info.errors[#info.errors + 1] = "policy.json assigns profile " .. policy.profile
					.. ", which is not installed in a trusted location"
				return nil, info
			end
		end
	end

	-- 2. DNS domain. Trusted profiles are matched first, so a dev profile can't
	-- make an org's match ambiguous and knock the install back to neutral.
	local domain = opts.domain or M.system_dns_domain()
	if domain and domain ~= "" then
		domain = domain:lower():gsub("%.$", "")
		for _, list in ipairs({ trusted, untrusted }) do
			local hits = domain_hits(list, domain)
			if #hits == 1 then
				info.reason = "domain"
				return hits[1], info
			elseif #hits > 1 then
				info.reason = "ambiguous"
				return nil, info
			end
		end
	end

	info.reason = "none"
	return nil, info
end

return M