local R = require("core.imgui.Runtime")
local Null = require("core.imgui.backend.Null")
local iup = require("core.imgui.iup")

-- The idle loop (Runtime.step) and a reactive background whose next draw is due.
describe("the idle loop with a scene due", function()
	local B, saved_bg
	before_each(function()
		B = Null.new({ w = 400, h = 300 })
		R.init(B)
		iup.Show(iup.dialog{ iup.label{ TITLE = "x" }, RASTERSIZE = "400x300" })
		R.frame(); R.frame()
		saved_bg = package.loaded["core.ui.Background"]
	end)
	after_each(function() package.loaded["core.ui.Background"] = saved_bg end)

	local function run(due_in)
		local ticks, frames, waits = 0, 0, {}
		package.loaded["core.ui.Background"] = {
			due = function() return R.now() + due_in end,
			tick = function() ticks = ticks + 1; return true end,
		}
		-- a native wait: false when it timed out with no message
		B.wait = function(t) waits[#waits + 1] = t; B.advance(t); return false end
		local real = R.frame
		R.frame = function(...) frames = frames + 1; return real(...) end
		R.step(true)
		R.frame = real
		return ticks, frames, waits
	end

	it("presents the scene alone when it is already due and no input is pending", function()
		local ticks, frames, waits = run(-0.01)
		assert.same({ 0 }, waits)   -- a zero wait: it still polls for input
		assert.equal(1, ticks)
		assert.equal(0, frames)
	end)

	it("presents the scene alone when it falls due during the wait", function()
		local ticks, frames = run(0.02)
		assert.equal(1, ticks)
		assert.equal(0, frames)
	end)
end)
