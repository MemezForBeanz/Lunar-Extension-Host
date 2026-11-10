local lfs = require("lfs")
local Harness = require("spec.support.imgui_extension_harness")

local root = os.getenv("LUNAR_ORGPACKS_DIR") or "../lunar-orgpacks"
local CASES = {
	{ "hpe/extensions/buildqueue", 1 },
	{ "hpe/extensions/iloredfish", 1 },
	{ "hpe/extensions/logparser", 1 },
	{ "hpe/extensions/scanchainparser", 1 },
	{ "hpe/extensions/hpe-theme", 1 },
	{ "microchip/extensions/blackduck", 1 },
	{ "microchip/extensions/microchip-theme", 1 },
	{ "microchip/extensions/timeclock", 1 },
}

describe("organization packs on the ImGui host", function()
	for _, case in ipairs(CASES) do
		local rel = case[1]
		it("builds and paints " .. rel, function()
			local dir = root .. "/" .. rel
			if not lfs.attributes(dir, "mode") then
				pending("set LUNAR_ORGPACKS_DIR to run org-pack UI smoke tests")
				return
			end
			local count, clicked, warnings, routes = Harness.run(dir .. "/init.lua", dir)
			assert.are.equal(case[2], count)
			assert.is_true(clicked >= 0)
			assert.is_true(routes >= 0)
			assert.are.same({}, warnings)
		end)
	end
end)
