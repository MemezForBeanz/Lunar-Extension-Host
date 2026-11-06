local Layout = require("core.ui.ViewLayout")
local Director = require("core.classes.MotionDirector")

local function fixture(saved, enabled)
	local iup = { DEFAULT = 0 }
	function iup.timer() return {} end
	function iup.SetAttribute(w, k, v) w[k] = v end
	function iup.Refresh() end
	local clock = { time = 0 }
	local director = Director:new({ iup = iup, enabled = enabled, clock = function() return clock.time end, respect_system = false })
	local settings = { values = saved or {} }
	function settings:get(k) return self.values[k] end
	function settings:set(k, v) self.values[k] = v end
	function settings:save() end
	local function bar()
		return { setReveal = function(self, v) self.reveal = v end }
	end
	local rail, status, terminal = bar(), bar(), { setHeight = function(self, v) self.height = v end }
	local layout = Layout.new({ iup = iup, root = {}, settings = settings, motion = director,
		rail = rail, status = status, terminal = terminal })
	return layout, director, clock, rail, status, terminal, settings
end

describe("view layout", function()
	it("recomputes the page budget with each bar frame, before the layout runs", function()
		local layout, dir, clock = fixture()
		local order, refreshes = {}, 0
		layout:setBudget(function() order[#order + 1] = "budget" end)
		local refresh = layout._iup.Refresh
		layout._iup.Refresh = function(...)
			refreshes = refreshes + 1
			order[#order + 1] = "refresh"
			if refresh then return refresh(...) end
		end
		layout:toggleBars()
		clock.time = 2; dir:tick()
		assert.is_true(refreshes > 0)
		assert.equal("budget", order[1])
		assert.equal("refresh", order[2])
		assert.equal("budget", order[#order - 1])
	end)

	it("restores independent bar and terminal visibility and height", function()
		local layout, _, _, rail, status, terminal = fixture({ view_bars_visible = false, terminal_open = true, terminal_height = 321 })
		assert.is_false(layout:barsVisible()); assert.is_true(layout:terminalVisible())
		assert.equal(0, rail.reveal); assert.equal(0, status.reveal); assert.equal(321, terminal.height)
	end)
	it("animates both bars in lockstep and saves the target immediately", function()
		local layout, dir, clock, rail, status, _, settings = fixture()
		local changes = 0; layout:onChange(function() changes = changes + 1 end)
		layout:toggleBars(); assert.is_false(settings.values.view_bars_visible); assert.equal(1, changes)
		clock.time = 0.07; dir:tick()
		assert.is_true(rail.reveal > 0 and rail.reveal < 1); assert.equal(rail.reveal, status.reveal)
		clock.time = 1; dir:tick(); assert.equal(0, rail.reveal)
	end)
	it("reverses from the current frame without jumping or stacking animations", function()
		local layout, dir, clock, rail = fixture()
		layout:toggleBars(); clock.time = 0.07; dir:tick()
		local at = rail.reveal
		layout:toggleBars(); assert.equal(at, rail.reveal)
		clock.time = 0.09; dir:tick(); assert.is_true(rail.reveal >= at)
		clock.time = 2; dir:tick(); assert.equal(1, rail.reveal)
	end)
	it("reverses a terminal reveal from its current height", function()
		local layout, dir, clock, _, _, terminal = fixture()
		layout:toggleTerminal(); clock.time = 0.08; dir:tick()
		local at = terminal.height; assert.is_true(at > 0 and at < 260)
		layout:toggleTerminal(); assert.equal(at, terminal.height)
		clock.time = 2; dir:tick(); assert.equal(0, terminal.height)
	end)
	it("settles synchronously with motion disabled", function()
		local layout, _, _, rail, status, terminal = fixture(nil, false)
		layout:toggleBars(); assert.equal(0, rail.reveal); assert.equal(0, status.reveal)
		layout:toggleTerminal(); assert.equal(260, terminal.height)
		layout:toggleBars(); assert.equal(1, rail.reveal)
	end)
	it("dragging cancels the reveal and saves only on release", function()
		local layout, dir, clock, _, _, terminal, settings = fixture()
		layout:toggleTerminal(); layout:setTerminalHeight(400)
		clock.time = 2; dir:tick(); assert.equal(400, terminal.height)
		assert.is_nil(settings.values.terminal_height)
		layout:saveTerminalHeight(); assert.equal(400, settings.values.terminal_height)
	end)
end)
