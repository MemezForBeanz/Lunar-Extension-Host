local Harness = require("spec.support.imgui_extension_harness")

local CASES = {
	{ "extensions/media/init.lua", "extensions/media", 1 },
	{ "extensions/media-server/init.lua", "extensions/media-server", 0 },
	{ "extensions/lsp-csharp/init.lua", nil, 1 },
	{ "extensions/lsp-python/init.lua", nil, 1 },
	{ "plugins/lsp-c/init.lua", nil, 1 },
	{ "plugins/lsp-lua/init.lua", nil, 1 },
	{ "exampleplugins/hello.lua", nil, 1 },
}

describe("bundled extensions on the ImGui host", function()
	for _, case in ipairs(CASES) do
		it("builds and paints " .. case[1], function()
			local count, clicked, warnings, routes = Harness.run(case[1], case[2])
			assert.are.equal(case[3], count)
			assert.is_true(clicked >= 0)
			assert.is_true(routes >= 0)
			assert.are.same({}, warnings)
		end)
	end
end)
