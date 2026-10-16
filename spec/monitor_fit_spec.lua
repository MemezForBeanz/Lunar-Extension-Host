local MonitorFit = require("core.ui.MonitorFit")

local function fake(attrs)
	local log = {}
	local iup = {
		GetAttribute = function(_, k) return attrs[k] end,
		SetAttribute = function(_, k, v) attrs[k] = v; log[#log + 1] = k .. "=" .. tostring(v) end,
		Show = function() log[#log + 1] = "Show" end,
		GetGlobal = function(k) return attrs["global:" .. k] end,
	}
	return iup, log
end

local SHORT = { left = 0, top = 0, right = 1920, bottom = 1040 }

describe("MonitorFit", function()
	it("sizes for a monitor and ignores the same rect again", function()
		local iup, log = fake({ RASTERSIZE = "1200x800", MAXIMIZED = "NO" })
		local fit = MonitorFit.new({ iup = iup, dialog = {} })
		assert.are.equal("sized", fit:apply(SHORT))
		assert.are.same({ "MAXSIZE=65535x1080", "MINSIZE=700x500" }, log)
		assert.are.equal("same", fit:apply({ left = 0, top = 0, right = 1920, bottom = 1040 }))
		assert.are.equal(2, #log)
	end)

	it("clamps a restored window that is taller than the new monitor", function()
		local attrs = { RASTERSIZE = "2400x1400", MAXIMIZED = "NO" }
		local fit = MonitorFit.new({ iup = fake(attrs), dialog = {} })
		assert.are.equal("clamped", fit:apply(SHORT))
		assert.are.equal("1920x1040", attrs.RASTERSIZE)
	end)

	it("restores and re-maximizes, with a Show after each PLACEMENT", function()
		local iup, log = fake({ RASTERSIZE = "2400x1400", MAXIMIZED = "YES" })
		local fit = MonitorFit.new({ iup = iup, dialog = {} })
		assert.are.equal("remaximized", fit:apply(SHORT))
		assert.are.same({ "PLACEMENT=NORMAL", "Show", "PLACEMENT=MAXIMIZED", "Show" },
			{ log[3], log[4], log[5], log[6] })
	end)

	it("leaves a maximized window alone within the resize-border slack", function()
		local fit = MonitorFit.new({ iup = fake({ RASTERSIZE = "1938x1078", MAXIMIZED = "YES" }), dialog = {} })
		assert.are.equal("sized", fit:apply(SHORT))
	end)

	it("does nothing on refit without FFI", function()
		local iup, log = fake({})
		MonitorFit.new({ iup = iup, dialog = {} }):refit()
		assert.are.same({}, log)
	end)

	it("computes startup sizes from SCREENSIZE", function()
		local s = MonitorFit.startup(fake({ ["global:SCREENSIZE"] = "1280x680" }))
		assert.are.equal("65535x" .. (s.work_h + 40), s.maxsize)
		assert.truthy(s.minsize:match("^%d+x%d+$"))
		assert.is_table(s.taskbar)
	end)
end)
