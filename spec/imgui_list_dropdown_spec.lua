-- iup.list DROPDOWN=YES on the ImGui host: the Win32 combo box IUP maps it to (the media
-- extension's Discover page uses one). Sizes follow iListComputeNaturalSizeMethod and
-- iupdrvListAddBorders; the look was measured on the IUP build (scripts/ui_textmargin.lua):
-- a 2 px sunken edge, the BGCOLOR field, a raised 17 px arrow button.
local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local Element = require("core.imgui.Element")
local Fonts = require("core.imgui.Fonts")
local iup = require("core.imgui.iup")

local B
local function boot() B = Null.new(); R.init(B) end
local function show(widget, w, h)
	local dlg = iup.dialog{ iup.vbox{ widget, MARGIN = "0x0", GAP = "0" }, RASTERSIZE = w .. "x" .. h, BORDER = "NO" }
	iup.Show(dlg)
	R.frame(); R.frame()
	return dlg, Element.state(widget)
end
local function press(x, y) B.queue({ events = { { type = "move", x = x, y = y }, { type = "press", x = x, y = y, button = 1 } } }); R.frame() end
local function release(x, y) B.queue({ events = { { type = "release", x = x, y = y, button = 1 } } }); R.frame() end
local function move(x, y) B.queue({ events = { { type = "move", x = x, y = y } } }); R.frame() end
local function key(code, mods)
	local k = { code = code, down = true }
	for m, v in pairs(mods or {}) do k[m] = v end
	B.queue({ keys = { k } }); R.frame()
end
local function fills(color)
	local n = 0
	for _, c in ipairs(B.lastFrame()) do
		if c[1] == "rect_filled" then
			local col = c[6]
			if type(col) == "string" and col == color then n = n + 1 end
		end
	end
	return n
end

describe("iup.list DROPDOWN=YES on the ImGui host", function()
	before_each(boot)

	it("is one line tall plus borders and as wide as VISIBLECOLUMNS + button", function()
		local l = iup.list{ "Movies", "Shows", DROPDOWN = "YES", VALUE = "1", VISIBLECOLUMNS = "24" }
		local _, st = show(l, 600, 200)
		local font = Fonts.forElement(l)
		local _, ch = font:charsize()
		assert.equal(ch + 8, st.h)
		assert.equal(math.floor(24 * font:measure("WWWWWWWWWW") / 10) + 8 + 3 + 17, st.w)
	end)

	it("sizes to the widest item without VISIBLECOLUMNS", function()
		local l = iup.list{ "a", "a much longer item", DROPDOWN = "YES" }
		local _, st = show(l, 600, 200)
		assert.equal(Fonts.forElement(l):measure("a much longer item") + 28, st.w)
	end)

	it("draws the selected item in the field and never as an open list", function()
		local l = iup.list{ "Movies", "Shows", DROPDOWN = "YES", VALUE = "2", VISIBLECOLUMNS = "10" }
		show(l, 600, 200)
		local texts = {}
		for _, c in ipairs(B.lastFrame()) do if c[1] == "text" then texts[#texts + 1] = c[7] end end
		assert.same({ "Shows" }, texts)
	end)

	it("opens a popup on click, picks with the mouse and fires ACTION, VALUECHANGED_CB, DROPDOWN_CB", function()
		local log = {}
		local l = iup.list{ "Movies", "Shows", "Music", DROPDOWN = "YES", VALUE = "1", VISIBLECOLUMNS = "10" }
		function l:action(text, item, state) log[#log + 1] = "action " .. text .. " " .. item .. " " .. state end
		function l:valuechanged_cb() log[#log + 1] = "changed " .. self.VALUE end
		function l:dropdown_cb(state) log[#log + 1] = "dropdown " .. state end
		local _, st = show(l, 600, 300)
		press(st.x + 10, st.y + 5); release(st.x + 10, st.y + 5)
		assert.equal(1, #R.overlays())
		local o = R.overlays()[1]
		assert.equal(st.y + st.h, o.y)
		local _, ch = Fonts.forElement(l):charsize()
		local row3 = o.y + 1 + 2 * ch + 2
		move(o.x + 10, row3)
		press(o.x + 10, row3); release(o.x + 10, row3)
		assert.equal(0, #R.overlays())
		assert.equal("3", iup.GetAttribute(l, "VALUE"))
		assert.same({ "dropdown 1", "action Movies 1 0", "action Music 3 1", "changed 3", "dropdown 0" }, log)
	end)

	it("steps the selection with Up/Down while closed and opens with Alt+Down", function()
		local l = iup.list{ "a", "b", "c", DROPDOWN = "YES", VALUE = "1" }
		show(l, 600, 200)
		iup.SetFocus(l); R.frame()
		key(iup.K_DOWN)
		assert.equal("2", iup.GetAttribute(l, "VALUE"))
		key(iup.K_END)
		assert.equal("3", iup.GetAttribute(l, "VALUE"))
		key(iup.K_UP)
		assert.equal("2", iup.GetAttribute(l, "VALUE"))
		key(iup.K_DOWN, { alt = true })
		assert.equal(1, #R.overlays())
		key(iup.K_ESC)
		assert.equal(0, #R.overlays())
		assert.equal("2", iup.GetAttribute(l, "VALUE"))
	end)

	it("paints the classic combo: sunken edge, BGCOLOR field, arrow button face", function()
		local l = iup.list{ "Movies", DROPDOWN = "YES", VALUE = "1", BGCOLOR = "27 29 35", FGCOLOR = "214 217 224" }
		show(l, 600, 200)
		local Color = require("core.imgui.Color")
		local function n(c) local v = 0; for _, call in ipairs(B.lastFrame()) do if call[1] == "rect_filled" and call[6] == Color.parse(c) then v = v + 1 end end; return v end
		assert.is_true(n("27 29 35") >= 1)       -- the field
		assert.is_true(n("240 240 240") >= 1)    -- the button face
		assert.is_true(n("160 160 160") >= 2)    -- the edge's outer top/left and the button's inner shadow
		assert.equal(4, n("0 0 0"))              -- the arrow: 7, 5, 3, 1 px rows
	end)
end)
