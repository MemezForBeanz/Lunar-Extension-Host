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

-- What an org profile's legacy_config_dir passes in.
local LEGACY = { legacy_dir_name = "Old Tool" }

-- SettingsManager resolves its file from %APPDATA%, so point APPDATA at a temp
-- dir to exercise real load/save round-trips without touching the user's config.
local function sandbox(json)
	local dir = os.getenv("TEMP") .. "\\lunar_settings_spec_" .. __unique_suffix()
	lfs.mkdir(dir)
	lfs.mkdir(dir .. "\\Lunar Extension Host")
	if json then
		local f = assert(io.open(dir .. "\\Lunar Extension Host\\settings.json", "w"))
		f:write(json)
		f:close()
	end
	local prev = os.getenv("APPDATA")
	return dir, prev
end

describe("SettingsManager welcome tour flags", function()
	local saved_appdata

	before_each(function()
		saved_appdata = os.getenv("APPDATA")
	end)

	local function with_appdata(dir, fn)
		-- luajit has no setenv; SettingsManager reads APPDATA at initialize()
		-- time, so stub os.getenv for the duration of the call.
		local real = os.getenv
		os.getenv = function(k)
			if k == "APPDATA" then return dir end
			return real(k)
		end
		local ok, err = pcall(fn)
		os.getenv = real
		if not ok then error(err, 0) end
	end

	it("round-trips the welcome tour flags through save and load", function()
		local dir = sandbox(nil)
		with_appdata(dir, function()
			local s = SettingsManager:new()
			s:load()
			s:set("welcome_tour_completed", true)
			s:save()

			local again = SettingsManager:new()
			again:load()
			assert.is_true(again:get("welcome_tour_completed"))
		end)
	end)

	it("migrates a legacy onboarding_dismissed flag", function()
		-- Mirrors a real settings.json written by the buggy build.
		local dir = sandbox(cjson.encode({
			theme = "classic",
			welcome_tour_completed = false,
			welcome_tour_dismissed = false,
			onboarding_dismissed = true,
			onboarding_completed = false,
			backend_url = "https://192.0.2.10:8000",
		}))
		with_appdata(dir, function()
			local s = SettingsManager:new()
			s:load()
			assert.is_true(s:get("welcome_tour_dismissed"))
		end)
	end)

	it("migrates a legacy onboarding_completed flag", function()
		local dir = sandbox(cjson.encode({
			welcome_tour_completed = false,
			onboarding_completed = true,
			backend_url = "https://192.0.2.10:8000",
		}))
		with_appdata(dir, function()
			local s = SettingsManager:new()
			s:load()
			assert.is_true(s:get("welcome_tour_completed"))
		end)
	end)

	it("persists the migration so it only happens once", function()
		local dir = sandbox(cjson.encode({
			onboarding_dismissed = true,
			backend_url = "https://192.0.2.10:8000",
		}))
		with_appdata(dir, function()
			SettingsManager:new():load()
			local f = assert(io.open(dir .. "\\Lunar Extension Host\\settings.json", "r"))
			local written = cjson.decode(f:read("*a"))
			f:close()
			assert.is_true(written.welcome_tour_dismissed)
		end)
	end)

	it("copies the org's legacy config folder on first run", function()
		local dir = os.getenv("TEMP") .. "\\lunar_settings_spec_" .. __unique_suffix()
		lfs.mkdir(dir)
		local legacy = dir .. "\\Old Tool"
		lfs.mkdir(legacy)
		lfs.mkdir(legacy .. "\\logparser")
		local f = assert(io.open(legacy .. "\\settings.json", "w"))
		f:write(cjson.encode({ theme = "classic", welcome_tour_completed = true }))
		f:close()
		f = assert(io.open(legacy .. "\\logparser\\history.jsonl", "w"))
		f:write("{}\n")
		f:close()

		with_appdata(dir, function()
			local s = SettingsManager:new(LEGACY)
			assert.are.equal(legacy, s.migrated_from)
			assert.is_true(s.migration_complete)
			s:load()
			assert.are.equal("classic", s:get("theme"))
			assert.is_true(s:get("welcome_tour_completed"))
			assert.are.equal("file",
				lfs.attributes(dir .. "\\Lunar Extension Host\\logparser\\history.jsonl", "mode"))
			-- The old folder is left in place for the old build to keep using.
			assert.are.equal("file", lfs.attributes(legacy .. "\\settings.json", "mode"))

			-- Second run: the new folder exists, so nothing is copied again.
			assert.is_nil(SettingsManager:new(LEGACY).migrated_from)
		end)
	end)

	it("copies nothing when no legacy folder name is given", function()
		local dir = os.getenv("TEMP") .. "\\lunar_settings_spec_" .. __unique_suffix()
		lfs.mkdir(dir)
		lfs.mkdir(dir .. "\\Old Tool")
		with_appdata(dir, function()
			local s = SettingsManager:new()
			assert.is_nil(s.migrated_from)
			assert.are.equal(dir .. "\\Lunar Extension Host", s:getConfigDir())
		end)
	end)

	it("retries the folder copy on the next run after a failed copy", function()
		local dir = os.getenv("TEMP") .. "\\lunar_settings_spec_" .. __unique_suffix()
		lfs.mkdir(dir)
		local legacy = dir .. "\\Old Tool"
		lfs.mkdir(legacy)
		lfs.mkdir(legacy .. "\\history")
		local f = assert(io.open(legacy .. "\\settings.json", "w"))
		f:write(cjson.encode({ theme = "classic" }))
		f:close()
		f = assert(io.open(legacy .. "\\history\\runs.jsonl", "w"))
		f:write("{}\n")
		f:close()
		local new_dir = dir .. "\\Lunar Extension Host"

		with_appdata(dir, function()
			-- Fail the copy of one file, as a locked file or a full disk would.
			local real_open = io.open
			io.open = function(path, mode)
				if mode == "wb" and path:find("runs.jsonl", 1, true) then return nil, "locked" end
				return real_open(path, mode)
			end
			local ok, failed = pcall(SettingsManager.new, SettingsManager, LEGACY)
			io.open = real_open
			assert(ok, failed)

			assert.is_false(failed.migration_complete)
			assert.are.equal(legacy, failed:getConfigDir())  -- keeps working off the old folder
			assert.is_nil(lfs.attributes(new_dir))            -- no half-copied folder left behind
			assert.is_nil(lfs.attributes(new_dir .. ".migrating"))

			local retry = SettingsManager:new(LEGACY)
			assert.is_true(retry.migration_complete)
			assert.are.equal(new_dir, retry:getConfigDir())
			assert.are.equal("file", lfs.attributes(new_dir .. "\\history\\runs.jsonl", "mode"))
		end)
	end)

	it("leaves the flags alone when no legacy keys are present", function()
		local dir = sandbox(cjson.encode({
			welcome_tour_completed = false,
			welcome_tour_dismissed = false,
			backend_url = "https://192.0.2.10:8000",
		}))
		with_appdata(dir, function()
			local s = SettingsManager:new()
			s:load()
			assert.is_false(s:get("welcome_tour_completed"))
			assert.is_false(s:get("welcome_tour_dismissed"))
		end)
	end)
end)
