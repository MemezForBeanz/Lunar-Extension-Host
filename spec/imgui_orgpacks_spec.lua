local lfs = require("lfs")
local Harness = require("spec.support.imgui_extension_harness")

-- LUNAR_ORGPACKS_DIR points at a lunar-orgpacks checkout; a sibling checkout is the default
local root = os.getenv("LUNAR_ORGPACKS_DIR") or "../lunar-orgpacks"
local CASES = {
	{ "hpe/extensions/buildqueue", 1, 1, 3, 10, 1 },
	{ "hpe/extensions/iloredfish", 1, 1, 0, 9, 1 },
	{ "hpe/extensions/logparser", 1, 1, 0, 7, 1 },
	{ "hpe/extensions/scanchainparser", 1, 1, 2, 13, 1 },
	{ "hpe/extensions/hpe-theme", 1, 1, 0, 6, 1 },
	{ "microchip/extensions/blackduck", 1, 2, 10, 16, 1 }, -- council redesign: two pages
	{ "microchip/extensions/microchip-theme", 1, 1, 0, 6, 1 },
	{ "microchip/extensions/timeclock", 1, 1, 14, 16, 1 },
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
			local count, clicked, warnings, routes, _, report = Harness.run(dir .. "/init.lua", dir)
			assert.are.equal(case[2], count)
			assert.is_true(report.pages >= case[3])
			assert.is_true(clicked >= case[4])
			assert.is_true(report.callbacks >= case[5])
			assert.is_true(report.texts >= case[6])
			assert.is_true(routes >= 0)
			assert.are.same({}, warnings)
		end)
	end
end)
