local lfs = require("lfs")
local Harness = require("spec.support.imgui_extension_harness")

local root = os.getenv("LUNAR_ORGPACKS_DIR") or "../lunar-orgpacks"
local CASES = {
	{ "hpe/extensions/buildqueue" },
	{ "hpe/extensions/iloredfish" },
	{ "hpe/extensions/logparser" },
	{ "hpe/extensions/scanchainparser" },
	{ "hpe/extensions/hpe-theme" },
	{ "microchip/extensions/blackduck" },
	{ "microchip/extensions/microchip-theme" },
	{ "microchip/extensions/timeclock" },
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
			local count, clicked, warnings = Harness.run(dir .. "/init.lua", dir)
			assert.is_true(count >= 0)
			assert.is_true(clicked >= 0)
			assert.are.same({}, warnings)
		end)
	end
end)
