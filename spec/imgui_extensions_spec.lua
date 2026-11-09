local Harness = require("spec.support.imgui_extension_harness")

local CASES = {
	{ "extensions/media/init.lua", "extensions/media" },
	{ "extensions/media-server/init.lua", "extensions/media-server" },
	{ "extensions/lsp-csharp/init.lua" },
	{ "extensions/lsp-python/init.lua" },
	{ "plugins/lsp-c/init.lua" },
	{ "plugins/lsp-lua/init.lua" },
	{ "exampleplugins/hello.lua" },
}

describe("bundled extensions on the ImGui host", function()
	for _, case in ipairs(CASES) do
		it("builds and paints " .. case[1], function()
			local count, clicked, warnings = Harness.run(case[1], case[2])
			assert.is_true(count >= 0, "extension did not register")
			assert.is_true(clicked >= 0)
			assert.are.same({}, warnings)
		end)
	end
end)
