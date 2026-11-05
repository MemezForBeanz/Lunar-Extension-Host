local Download = require("core.lib.UpdateDownload")
local Updater = require("core.lib.Updater")
describe("update download metadata", function()
	it("refuses untrusted URLs, paths and missing hashes before starting a job", function()
		local good = { version = "1.5.0", name = "LunarExtensionHost-1.5.0.msi",
			url = Updater.RELEASES .. "/download/v1.5.0/LunarExtensionHost-1.5.0.msi", sha256 = string.rep("a", 64) }
		for _, change in ipairs({ { version = "../1.5.0" }, { version = "1.5.0.1" }, { name = "../evil.msi" },
			{ url = "https://other.example/installer.msi" }, { url = "http://github.com/installer.msi" },
			{ sha256 = "" }, { sha256 = string.rep("z", 64) } }) do
			local asset = {}
			for key, value in pairs(good) do asset[key] = value end
			for key, value in pairs(change) do asset[key] = value end
			local job, err = Download.start({ installer = asset, host = {
				startJob = function() error("invalid metadata must never start a download") end,
			} }, function() error("invalid metadata must never succeed") end)
			assert.is_nil(job)
			assert.equal("Invalid GitHub installer metadata", err)
		end
	end)
end)
