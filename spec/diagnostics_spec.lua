local Diagnostics = require("core.ui.Diagnostics")

local function base(over)
	local d = {
		fullsize = "1920x1080", screensize = "1920x1040", work = { w = 1920, h = 1040 },
		taskbar = { available = true, autohide = false, edge = "bottom", thickness = 40 },
		org_info = { reason = "dev-selected", available = { "acme", "globex" }, errors = {}, warnings = {} },
		dev_build = true,
		roots = { { source = "built-in", dir = "C:\\lunar\\plugins" } },
		loaded = { { source = "org:acme", name = "Queue" } },
		skipped = { { source = "built-in", id = "linuxonly", reason = "needs linux" } },
		window = { RASTERSIZE = "800x600" },
		layout = {},
		transition = { last = "animated" },
	}
	for k, v in pairs(over or {}) do d[k] = v end
	return d
end

describe("Diagnostics.window_report", function()
	it("reports the org pack, its tool group and the extensions", function()
		local text = Diagnostics.window_report(base({
			profile = { id = "acme", trusted = false, tool_group = "Acme Tools" },
		}))
		assert.truthy(text:find("profile             : acme (dev-selected, untrusted)", 1, true))
		assert.truthy(text:find("tool group          : Acme Tools", 1, true))
		assert.truthy(text:find("installed           : acme, globex", 1, true))
		assert.truthy(text:find("Extensions (dev build)", 1, true))
		assert.truthy(text:find("loaded  org:acme    : Queue", 1, true))
		assert.truthy(text:find("skipped built-in    : linuxonly (needs linux)", 1, true))
		assert.truthy(text:find("last                  : animated", 1, true))
	end)

	it("handles no profile, no monitor rect and an unavailable transition", function()
		local text = Diagnostics.window_report(base({ transition = "no overlay" }))
		assert.truthy(text:find("profile             : none (dev-selected)", 1, true))
		assert.truthy(text:find("tool group          : -", 1, true))
		assert.truthy(text:find("(startup primary-monitor values)", 1, true))
		assert.truthy(text:find("unavailable: no overlay", 1, true))
	end)

	it("adds the native modules section when given", function()
		local text = Diagnostics.window_report(base({ native = { "  ffi         on   LuaJIT FFI" } }))
		assert.truthy(text:find("Native modules\n  ffi         on   LuaJIT FFI", 1, true))
		assert.falsy(Diagnostics.window_report(base()):find("Native modules", 1, true))
	end)

	it("formats the current monitor's work area", function()
		local text = Diagnostics.window_report(base({ monitor = { left = 1920, top = 0, right = 3840, bottom = 1040 } }))
		assert.truthy(text:find("1920x1040 (1920,0 to 3840,1040)", 1, true))
	end)
end)
