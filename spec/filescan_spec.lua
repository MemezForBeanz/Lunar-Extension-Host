local lfs = require("lfs")
local filescan = require("core.lib.filescan")
local path = require("core.platform").path

describe("core.lib.filescan", function()
	it("walks files with shared depth and file filters", function()
		-- tree/: a/target.txt and b/target.txt at depth 1, plus one deeper than max_depth.
		local root = path:join(lfs.currentdir(), "spec", "fixtures", "tree")
		local files = filescan.walk(root, {
			max_depth = 2,
			accept_file = function(_, name)
				return name:lower() == "target.txt"
			end,
		})

		assert.are.equal(2, #files)
	end)

	it("time-slices work when called from a coroutine", function()
		local checkpoints = 0
		local co = coroutine.create(function()
			local checkpoint = filescan.newCheckpoint({
				max_ops_per_step = 1,
				budget_ms = 1000,
			})
			checkpoint()
			checkpoints = checkpoints + 1
		end)

		assert.is_true(coroutine.resume(co))
		assert.are.equal("suspended", coroutine.status(co))
		assert.is_true(coroutine.resume(co))
		assert.are.equal(1, checkpoints)
	end)
end)
