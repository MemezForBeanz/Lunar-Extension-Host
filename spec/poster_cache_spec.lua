local PosterCache = require("core.ui.PosterCache")

describe("PosterCache", function()
	it("reports a host without the decoder instead of failing", function()
		local cache, why = PosterCache.new()
		assert.is_nil(cache)
		assert.truthy(why)
	end)

	it("passes options through to the native module", function()
		local seen
		package.preload["media_native"] = function()
			return { cache = function(opts) seen = opts; return "cache" end }
		end
		package.loaded["media_native"] = nil
		local cache = PosterCache.new({ max_mb = 64 })
		package.preload["media_native"] = nil
		package.loaded["media_native"] = nil
		assert.equals("cache", cache)
		assert.equals(64, seen.max_mb)
	end)
end)
