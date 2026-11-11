-- Clicks reach a flat scroll box's content wherever its (internal, ZORDER=TOP) bars are
-- not showing: the bars sit above the content only where they are drawn.
local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")

local B
local function click(x, y)
	B.queue({ events = { { type = "move", x = x, y = y }, { type = "press", x = x, y = y, button = 1 } } }); R.frame()
	B.queue({ events = { { type = "release", x = x, y = y, button = 1 } } }); R.frame()
end

describe("flat scroll box hit testing", function()
	before_each(function() B = Null.new(); R.init(B) end)

	local function run(content_h)
		local hits = 0
		local btn = iup.flatbutton{ TITLE = "Play", RASTERSIZE = "120x40" }
		function btn:flat_action() hits = hits + 1 end
		local inner = iup.vbox{ iup.fill{ RASTERSIZE = "x" .. content_h }, iup.hbox{ iup.fill{}, btn }, MARGIN = "0x0", GAP = "0" }
		local box = iup.flatscrollbox{ inner, RASTERSIZE = "400x300" }
		local dlg = iup.dialog{ iup.vbox{ box, MARGIN = "0x0" }, RASTERSIZE = "500x400", BORDER = "NO" }
		iup.Show(dlg); R.frame(); R.frame()
		local st = Element.state(btn)
		return hits, st, function() click(st.x + st.w - 3, st.y + st.h / 2); return hits end
	end

	it("delivers a click near the right edge when everything fits (no bars)", function()
		local _, _, go = run(50)
		local hits = go()
		assert.equal(1, hits)
	end)

	it("delivers a click left of a showing vertical bar", function()
		local _, st, go = run(50)
		B.queue({}); R.frame()
		click(st.x + 5, st.y + st.h / 2)
		assert.is_true(go() >= 1)
	end)
end)
