-- Unique per call: busted reseeds math.random, so a random name alone can hand
-- two tests (or two runs) the same temp folder.
local __unique_seq = 0
local function __unique_suffix()
	__unique_seq = __unique_seq + 1
	return string.format("%d_%d_%d", os.time(), __unique_seq, math.random(1e9))
end

local lfs = require("lfs")
local cjson = require("cjson")
local SettingsManager = require("core.classes.SettingsManager")

-- Point APPDATA at a fresh temp folder for the duration of `fn` (luajit has no
-- setenv, and SettingsManager reads APPDATA in initialize()).
local function with_appdata(json, fn)
	local dir = os.getenv("TEMP") .. "\\lunar_layers_spec_" .. __unique_suffix()
	lfs.mkdir(dir)
	lfs.mkdir(dir .. "\\Lunar Extension Host")
	local path = dir .. "\\Lunar Extension Host\\settings.json"
	if json then
		local f = assert(io.open(path, "w"))
		f:write(cjson.encode(json))
		f:close()
	end
	local real = os.getenv
	os.getenv = function(k)
		if k == "APPDATA" then return dir end
		return real(k)
	end
	local ok, err = pcall(fn, path)
	os.getenv = real
	if not ok then error(err, 0) end
end

local function read_json(path)
	local f = assert(io.open(path, "r"))
	local data = cjson.decode(f:read("*a"))
	f:close()
	return data
end

local PROFILE = {
	id = "acme",
	settings = { backend_url = "https://lunar.acme.example", theme = "classic", update_share = "\\\\acme\\lunar" },
	locked = { backend_url = true },
}

describe("SettingsManager layers", function()
	it("is neutral by default: no backend, no update share, verified TLS", function()
		with_appdata(nil, function()
			local s = SettingsManager:new()
			s:load()
			assert.are.equal("", s:get("backend_url"))
			assert.are.equal("", s:get("update_share"))
			assert.are.equal("peer", s:get("backend_tls_verify"))
			assert.is_nil(s:getProfile())
		end)
	end)

	it("resolves locked > user > org default > built-in default", function()
		with_appdata({ backend_url = "https://mine.example", theme = "classic_dark" }, function()
			local s = SettingsManager:new()
			s:load()
			s:applyProfile(PROFILE)
			assert.are.equal("https://lunar.acme.example", s:get("backend_url")) -- locked beats user
			assert.are.equal("classic_dark", s:get("theme"))                   -- user beats org default
			assert.are.equal("\\\\acme\\lunar", s:get("update_share"))          -- org default beats built-in
			assert.is_true(s:get("motion_enabled"))                            -- built-in
			assert.is_true(s:isLocked("backend_url"))
			assert.is_false(s:isLocked("theme"))
		end)
	end)

	it("refuses to set a locked key and never saves org values", function()
		with_appdata(nil, function(path)
			local s = SettingsManager:new()
			s:applyProfile(PROFILE)
			local ok, why = s:set("backend_url", "https://elsewhere")
			assert.is_false(ok)
			assert.are.equal("locked", why)
			assert.is_true(s:set("theme", "fluent"))
			assert.is_true(s:save())

			local saved = read_json(path)
			assert.are.equal("fluent", saved.theme)
			assert.is_nil(saved.backend_url)
			assert.is_nil(saved.update_share)
		end)
	end)

	it("keeps extension settings that are not in the built-in defaults", function()
		with_appdata(nil, function()
			local s = SettingsManager:new()
			s:set("scanner.url", "https://scanner.example")
			s:save()
			local again = SettingsManager:new()
			again:load()
			assert.are.equal("https://scanner.example", again:get("scanner.url"))
		end)
	end)

	-- A profile that retires the address its org's older builds saved as a default.
	local RETIRING = {
		id = "acme",
		settings = { backend_url = "https://lunar.acme.example" },
		locked = {},
		retired = { backend_url = { ["https://192.0.2.10:8000"] = true } },
	}

	it("drops a default the org profile retired from a pre-Lunar settings file", function()
		with_appdata({ backend_url = "https://192.0.2.10:8000", backend_sync_enabled = true }, function(path)
			local s = SettingsManager:new()
			s:load()
			s:applyProfile(RETIRING)
			assert.are.equal("https://lunar.acme.example", s:get("backend_url"))
			local saved = read_json(path)
			assert.is_nil(saved.backend_url)
			assert.is_true(saved.backend_sync_enabled)
		end)
	end)

	it("keeps a retired value when no profile retires it", function()
		with_appdata({ backend_url = "https://192.0.2.10:8000" }, function()
			local s = SettingsManager:new()
			s:load()
			s:applyProfile(nil)
			assert.are.equal("https://192.0.2.10:8000", s:get("backend_url"))
		end)
	end)

	it("keeps a deliberately cleared backend URL across restarts", function()
		with_appdata(nil, function()
			local s = SettingsManager:new()
			s:applyProfile({ id = "acme", settings = { backend_url = "https://lunar.acme.example" }, locked = {} })
			s:set("backend_url", "")
			assert.is_true(s:save())

			local again = SettingsManager:new()
			again:load()
			again:applyProfile({ id = "acme", settings = { backend_url = "https://lunar.acme.example" }, locked = {} })
			assert.are.equal("", again:get("backend_url"))
		end)
	end)

	it("still retires on a later launch when the first one ran without the pack", function()
		with_appdata({ backend_url = "https://192.0.2.10:8000" }, function(path)
			local first = SettingsManager:new()
			first:load()
			first:applyProfile(nil)
			assert.is_true(read_json(path).pending_retirement)

			local second = SettingsManager:new()
			second:load()
			second:applyProfile(RETIRING)
			assert.are.equal("https://lunar.acme.example", second:get("backend_url"))
			local saved = read_json(path)
			assert.is_nil(saved.backend_url)
			assert.is_nil(saved.pending_retirement)
		end)
	end)

	it("keeps the retirement pending when its save fails", function()
		with_appdata({ backend_url = "https://192.0.2.10:8000" }, function(path)
			local s = SettingsManager:new()
			s:load()
			s.save = function() return false end
			s:applyProfile(RETIRING)
			assert.are.equal("https://192.0.2.10:8000", s:get("backend_url"))
			assert.is_true(read_json(path).pending_retirement)

			local again = SettingsManager:new()
			again:load()
			again:applyProfile(RETIRING)
			assert.is_nil(read_json(path).backend_url)
		end)
	end)

	it("retires values only from a pre-Lunar file, so a later choice sticks", function()
		with_appdata({ settings_schema = 2, backend_url = "https://192.0.2.10:8000" }, function()
			local s = SettingsManager:new()
			s:load()
			s:applyProfile(RETIRING)
			assert.are.equal("https://192.0.2.10:8000", s:get("backend_url"))
		end)
	end)

	it("replaces an existing settings file on save", function()
		with_appdata({ theme = "classic" }, function(path)
			local s = SettingsManager:new()
			s:load()
			s:set("theme", "fluent")
			assert.is_true(s:save())
			s:set("theme", "classic_dark")
			assert.is_true(s:save())
			assert.are.equal("classic_dark", read_json(path).theme)
			assert.is_nil(io.open(path .. ".tmp", "r"))
		end)
	end)

	it("recovers from a save interrupted before the swap", function()
		with_appdata(nil, function(path)
			local f = assert(io.open(path .. ".tmp", "w"))
			f:write(cjson.encode({ theme = "fluent", settings_schema = 2 }))
			f:close()
			local s = SettingsManager:new()
			s:load()
			assert.are.equal("fluent", s:get("theme"))
		end)
	end)

	it("keeps a backend address the user chose", function()
		with_appdata({ backend_url = "https://team.example:8000" }, function()
			local s = SettingsManager:new()
			s:load()
			assert.are.equal("https://team.example:8000", s:get("backend_url"))
		end)
	end)
end)
