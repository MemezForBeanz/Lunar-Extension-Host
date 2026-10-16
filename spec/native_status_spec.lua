local NativeStatus = require("core.lib.NativeStatus")

local function requirer(missing)
	return function(name)
		if missing[name] then error("module '" .. name .. "' not found:\n\tno field package.preload", 0) end
		return {}
	end
end

describe("NativeStatus", function()
	it("reports every module on when all load", function()
		local rows = NativeStatus.probe(requirer({}), true)
		assert.are.equal(#NativeStatus.MODULES, #rows)
		for _, r in ipairs(rows) do assert.are.equal("on", r.state) end
		local line, missing = NativeStatus.summary(rows, { themeapply = true, ffi = true })
		assert.is_false(missing)
		assert.truthy(line:find("native: ffi, iupraw, themeapply", 1, true))
		assert.falsy(line:find("OFF", 1, true))
	end)

	it("names what is off, with the first line of the error", function()
		local rows = NativeStatus.probe(requirer({ svgicon = true }), true)
		local line, missing = NativeStatus.summary(rows)
		assert.is_true(missing)
		assert.truthy(line:find("OFF: svgicon", 1, true))
		local report = table.concat(NativeStatus.lines(rows), "\n")
		assert.truthy(report:find("svgicon     off  SVG icons  [module 'svgicon' not found:]", 1, true))
	end)

	it("treats Windows-only modules as n/a elsewhere", function()
		local rows = NativeStatus.probe(requirer({ winredraw = true }), false)
		local _, missing = NativeStatus.summary(rows)
		assert.is_false(missing)
		assert.truthy(table.concat(NativeStatus.lines(rows), "\n"):find("winredraw   n/a", 1, true))
	end)

	it("flags theme fast paths the probe turned off", function()
		local rows = NativeStatus.probe(requirer({}), true)
		local theme = { themeapply = false, ffi = false, error = "probe failed: FFI get/set mismatch" }
		local line, missing = NativeStatus.summary(rows, theme)
		assert.is_true(missing)
		assert.truthy(line:find("theme fast paths (probe failed: FFI get/set mismatch)", 1, true))
		local report = table.concat(NativeStatus.lines(rows, theme), "\n")
		assert.truthy(report:find("theme fast paths: partial: themeapply off, IupFFI off", 1, true))
	end)
end)
