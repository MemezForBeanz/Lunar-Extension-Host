local StatusBar = require("core.ui.StatusBar")

-- A bar without the native widgets: just the label, IUP and a motion director
-- that runs frames only when told to, so a fade can be interrupted.
local function bar()
	local label = { FGCOLOR = "60 60 60", BGCOLOR = "240 240 240" }
	local running = {}
	local iup = {
		SetAttribute = function(w, k, v) w[k] = v end,
		GetAttribute = function(w, k) return w[k] end,
	}
	local motion = {
		animate = function(_, spec)
			-- Supersede whatever ran on this target, as MotionDirector does.
			for _, r in ipairs(running) do
				if not r.done then r.done = true; r.spec.on_done(false) end
			end
			running[#running + 1] = { spec = spec }
		end,
	}
	local sb = setmetatable({ _iup = iup, _label = label, _motion = motion }, StatusBar)
	local function frame(v)
		local r = running[#running]
		r.spec.on_frame(v)
		if v >= 1 then r.done = true; r.spec.on_done(true) end
	end
	return sb, label, frame
end

describe("StatusBar.setStatus", function()
	it("fades the text in from the bar colour to its resting colour", function()
		local sb, label, frame = bar()
		sb:setStatus("Building")
		assert.are.equal("Status: Building", label.TITLE)
		frame(0)
		assert.are.equal("240 240 240", label.FGCOLOR)
		frame(1)
		assert.are.equal("60 60 60", label.FGCOLOR)
	end)

	it("keeps the resting colour when a fade is interrupted", function()
		local sb, label, frame = bar()
		sb:setStatus("one")
		frame(0.5)                     -- mid-fade: FGCOLOR is an in-between colour
		sb:setStatus("two")
		frame(1)
		assert.are.equal("60 60 60", label.FGCOLOR)
		sb:setStatus("three")          -- and the next fade starts from the right place
		frame(1)
		assert.are.equal("60 60 60", label.FGCOLOR)
	end)

	it("just sets the text when there is no director", function()
		local sb, label = bar()
		sb._motion = nil
		sb:setStatus("Ready")
		assert.are.equal("Status: Ready", label.TITLE)
		assert.are.equal("60 60 60", label.FGCOLOR)
	end)
end)
