local Harness = require("spec.support.imgui_extension_harness")

local CASES = {
	{ "extensions/media/init.lua", "extensions/media", 1, 5, 28, 30, 1 },
	{ "extensions/media-server/init.lua", "extensions/media-server", 0, 1, 0, 6, 1 },
	{ "extensions/lsp-csharp/init.lua", nil, 1, 1, 0, 6, 1 },
	{ "extensions/lsp-python/init.lua", nil, 1, 1, 0, 6, 1 },
	{ "plugins/lsp-c/init.lua", nil, 1, 1, 0, 6, 1 },
	{ "plugins/lsp-lua/init.lua", nil, 1, 1, 0, 6, 1 },
	{ "exampleplugins/hello.lua", nil, 1, 1, 1, 8, 1 },
}

describe("bundled extensions on the ImGui host", function()
	for _, case in ipairs(CASES) do
		it("builds and paints " .. case[1], function()
			local count, clicked, warnings, routes, _, report = Harness.run(case[1], case[2])
			assert.are.equal(case[3], count)
			assert.is_true(clicked >= case[5])
			assert.is_true(report.pages >= case[4])
			assert.is_true(report.callbacks >= case[6])
			assert.is_true(report.texts >= case[7])
			assert.is_true(routes >= 0)
			assert.are.same({}, warnings)
		end)
	end

	if os.getenv("LUNAR_MEDIA_DEMO") == "1" then
		it("exercises the media demo library", function()
			local count, clicked, warnings, _, _, report = Harness.run("extensions/media/init.lua", "extensions/media")
			assert.are.equal(1, count)
			assert.is_true(clicked >= 28)
			assert.is_true(report.pages >= 5)
			assert.is_true(report.callbacks >= 30)
			assert.is_true(report.texts >= 1)
			assert.are.same({}, warnings)
		end)
	end
end)
