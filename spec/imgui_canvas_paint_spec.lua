-- spec/imgui_canvas_paint_spec.lua -- a canvas's ACTION runs when IUP would paint it.
--
-- iupwin_canvas.c calls ACTION from WM_PAINT: when the canvas first shows, changes size or
-- scroll position, or is invalidated (IupUpdate/IupRedraw, a visual attribute on it or an
-- ancestor). Every other frame of this host replays what the last ACTION drew, moved to
-- wherever the canvas is now, so a callback with side effects runs as often as on IUP.

local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")

describe("canvas ACTION follows IUP's paints", function()
	local B, cv, calls, lead, dlg
	before_each(function()
		B = Null.new({ w = 400, h = 300 })
		R.init(B)
		calls = 0
		cv = iup.canvas{ RASTERSIZE = "50x30", BORDER = "NO", EXPAND = "NO" }
		function cv:action()
			calls = calls + 1
			iup.DrawBegin(cv)
			iup.SetAttribute(cv, "DRAWSTYLE", "FILL")
			iup.SetAttribute(cv, "DRAWCOLOR", "200 10 10")
			iup.DrawRectangle(cv, 2, 3, 12, 13)
			iup.DrawEnd(cv)
			return iup.DEFAULT
		end
		lead = iup.label{ TITLE = "a" }
		dlg = iup.dialog{ iup.vbox{ iup.hbox{ lead, cv, GAP = "0", MARGIN = "0x0" }, iup.label{ TITLE = "other" } },
			RASTERSIZE = "400x300" }
		iup.Show(dlg); R.frame()
	end)

	-- the red rectangle's x and y in the last frame
	local function red()
		local Color = require("core.imgui.Color")
		local want = Color.parse("200 10 10")
		for _, c in ipairs(B.lastFrame()) do
			if c[1] == "rect_filled" and c[6] == want then return c[2], c[3] end
		end
	end

	it("paints on show, then replays the same drawing without calling ACTION", function()
		assert.equal(1, calls)
		local x, y = red()
		R.frame(); R.frame()
		assert.equal(1, calls)
		local x2, y2 = red()
		assert.equal(x, x2); assert.equal(y, y2)
	end)

	it("paints again after IupUpdate and IupRedraw", function()
		iup.Update(cv); R.frame()
		assert.equal(2, calls)
		iup.Redraw(dlg, 1); R.frame()
		assert.equal(3, calls)
		R.frame()
		assert.equal(3, calls)
	end)

	it("paints again for a visual attribute on it or an ancestor, not on another element", function()
		iup.SetAttribute(cv, "BGCOLOR", "0 0 0"); R.frame()
		assert.equal(2, calls)
		iup.SetAttribute(dlg, "FGCOLOR", "10 10 10"); R.frame()
		assert.equal(3, calls)
		iup.SetAttribute(iup.GetChild(iup.GetChild(dlg, 0), 1), "FGCOLOR", "1 2 3"); R.frame()
		assert.equal(3, calls)
		-- the draw state is set inside paints, never a reason to paint
		iup.SetAttribute(cv, "DRAWCOLOR", "1 1 1"); R.frame()
		assert.equal(3, calls)
	end)

	it("replays moved when only its position changes", function()
		local x, y = red()
		iup.SetAttribute(lead, "TITLE", "a much longer title"); R.frame(); R.frame()
		local x2, y2 = red()
		assert.equal(1, calls)
		assert.is_true(x2 > x)
		assert.equal(y, y2)
		assert.equal(Element.state(cv).x + 2, x2)
	end)

	it("paints again when its size changes", function()
		iup.SetAttribute(cv, "RASTERSIZE", "80x30"); iup.Refresh(dlg); R.frame()
		assert.equal(2, calls)
	end)

	it("paints again for scroll state and passes positions to ACTION", function()
		local pos
		cv.action = function(_, x, y) calls = calls + 1; pos = { x, y } end
		iup.SetAttribute(cv, "POSX", "7")
		iup.SetAttribute(cv, "POSY", "11")
		R.frame(); R.frame()
		assert.equal(2, calls)
		assert.same({ 7, 11 }, pos)
		iup.SetAttribute(cv, "DX", "4"); R.frame(); R.frame()
		assert.equal(3, calls)
	end)

	it("honours a redraw requested inside ACTION on the next frame", function()
		cv.action = function()
			calls = calls + 1
			if calls == 2 then iup.Update(cv) end
		end
		iup.Update(cv); R.frame()
		assert.equal(2, calls)
		R.frame(); R.frame()
		assert.equal(3, calls)
	end)

	it("does not replace the frame cache when capturing a compositor snapshot", function()
		local dc = R.dc()
		local cache = Element.state(cv).data.paint
		dc:record(false)
		R.paint(cv, dc)
		local snapshot = dc:stop()
		assert.is_true(#snapshot > 0)
		assert.equal(2, calls)
		assert.equal(cache, Element.state(cv).data.paint)
		R.frame()
		assert.equal(2, calls)
		assert.is_not_nil(red())
	end)

	it("paints again when it shows after not being drawn", function()
		iup.SetAttribute(cv, "VISIBLE", "NO"); R.frame(); R.frame()
		local before = calls
		iup.SetAttribute(cv, "VISIBLE", "YES"); R.frame()
		assert.equal(before + 1, calls)
	end)

	it("repaints an earlier sibling changed by a later canvas ACTION", function()
		local later = iup.canvas{ RASTERSIZE = "30x30", EXPAND = "NO" }
		function later:action() iup.SetAttribute(cv, "FGCOLOR", "10 20 30") end
		iup.Append(iup.GetChild(dlg, 0), later)
		R.frame()
		local before = calls
		R.frame()
		assert.equal(before + 1, calls)
		R.frame()
		assert.equal(before + 1, calls)
	end)

	it("settles when ACTION repeatedly sets an unchanged visual attribute", function()
		function cv:action()
			calls = calls + 1
			iup.SetAttribute(cv, "FGCOLOR", "10 20 30")
		end
		iup.Update(cv); R.frame(); R.frame()
		local before = calls
		R.frame(); R.frame()
		assert.equal(before, calls)
	end)
end)
