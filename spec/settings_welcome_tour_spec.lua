local lfs = require("lfs")
local cjson = require("cjson")
local SettingsManager = require("core.classes.SettingsManager")
local box = require("spec.support.config_sandbox")
local J = box.join

-- What an org profile's legacy_config_dir passes in.
local LEGACY = { legacy_dir_name = "Old Tool" }

-- A fresh per-user config root, optionally seeded with a settings.json, so the
-- specs exercise real load/save round-trips without touching the user's config.
local function sandbox(json)
	local dir = box.new_root("lunar_settings_spec")
	box.mkdir(box.app_dir(dir))
	if json then
		local f = assert(io.open(J(box.app_dir(dir), "settings.json"), "w"))
		f:write(json)
		f:close()
	end
	return dir
end

describe("SettingsManager welcome tour flags", function()
	local with_appdata = box.with_root

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
			local f = assert(io.open(J(box.app_dir(dir), "settings.json"), "r"))
			local written = cjson.decode(f:read("*a"))
			f:close()
			assert.is_true(written.welcome_tour_dismissed)
		end)
	end)

	it("copies the org's legacy config folder on first run", function()
		local dir = box.new_root("lunar_settings_spec")
		local legacy = J(dir, "Old Tool")
		lfs.mkdir(legacy)
		lfs.mkdir(J(legacy, "logparser"))
		local f = assert(io.open(J(legacy, "settings.json"), "w"))
		f:write(cjson.encode({ theme = "classic", welcome_tour_completed = true }))
		f:close()
		f = assert(io.open(J(legacy, "logparser", "history.jsonl"), "w"))
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
				lfs.attributes(J(box.app_dir(dir), "logparser", "history.jsonl"), "mode"))
			-- The old folder is left in place for the old build to keep using.
			assert.are.equal("file", lfs.attributes(J(legacy, "settings.json"), "mode"))

			-- Second run: the new folder exists, so nothing is copied again.
			assert.is_nil(SettingsManager:new(LEGACY).migrated_from)
		end)
	end)

	it("copies nothing when no legacy folder name is given", function()
		local dir = box.new_root("lunar_settings_spec")
		lfs.mkdir(J(dir, "Old Tool"))
		with_appdata(dir, function()
			local s = SettingsManager:new()
			assert.is_nil(s.migrated_from)
			assert.are.equal(box.app_dir(dir), s:getConfigDir())
		end)
	end)

	it("retries the folder copy on the next run after a failed copy", function()
		local dir = box.new_root("lunar_settings_spec")
		local legacy = J(dir, "Old Tool")
		lfs.mkdir(legacy)
		lfs.mkdir(J(legacy, "history"))
		local f = assert(io.open(J(legacy, "settings.json"), "w"))
		f:write(cjson.encode({ theme = "classic" }))
		f:close()
		f = assert(io.open(J(legacy, "history", "runs.jsonl"), "w"))
		f:write("{}\n")
		f:close()
		local new_dir = box.app_dir(dir)

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
			assert.are.equal("file", lfs.attributes(J(new_dir, "history", "runs.jsonl"), "mode"))
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
