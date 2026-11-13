-- IupFlatList as iup_flatlist.c behaves: the item array, the id attributes, sizes,
-- selection, keys, drag and drop, and the native frame and bars.
local iup = require("core.imgui.iup")
local Element = require("core.imgui.Element")
local Classes = require("core.imgui.Classes")
local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Draw = require("core.imgui.Draw")

local function setup()
	Fonts.backend = Null.new(); Fonts.reset()
end

local function placed(list, w, h)
	local st = Element.state(list)
	st.x, st.y, st.w, st.h = 0, 0, w, h
	Classes.get("flatlist").place(list, st, {})
	return st
end

local function press(list, st, lx, ly, mods, double)
	local status = iup._status({ shift = mods and mods.shift, ctrl = mods and mods.ctrl, b1 = true, double = double })
	Classes.get("flatlist").event(list, st, { type = "press", button = 1, lx = lx, ly = ly, status = status, double = double }, {})
	Classes.get("flatlist").event(list, st, { type = "release", button = 1, lx = lx, ly = ly, status = iup._status({}) }, {})
end

describe("imgui flatlist port (iup_flatlist.c)", function()
	before_each(setup)

	it("REMOVEITEM=ALL empties the item array, whatever wrote the items", function()
		local list = iup.flatlist{}
		for i, v in ipairs({ "one", "two", "three" }) do iup.SetAttribute(list, tostring(i), v) end
		assert.are.equal("3", iup.GetAttribute(list, "COUNT"))
		iup.SetAttribute(list, "REMOVEITEM", "ALL")
		assert.are.equal("0", iup.GetAttribute(list, "COUNT"))
		iup.SetAttribute(list, "APPENDITEM", "fresh")
		assert.are.equal("1", iup.GetAttribute(list, "COUNT"))
		assert.are.equal("fresh", iup.GetAttribute(list, "1"))
		assert.is_nil(Element.own(list, "1")) -- not an attribute: iupAttribGet finds nothing
	end)

	it("iFlatListSetIdValueAttrib: a gap fills with empty items, nil removes the rest", function()
		local list = iup.flatlist{}
		iup.SetAttribute(list, "3", "c")
		assert.are.equal("3", iup.GetAttribute(list, "COUNT"))
		assert.is_nil(iup.GetAttribute(list, "1"))
		iup.SetAttribute(list, "1", "a")
		iup.SetAttribute(list, "2", nil)
		assert.are.equal("1", iup.GetAttribute(list, "COUNT"))
		assert.are.equal("a", iup.GetAttribute(list, "1"))
	end)

	it("keeps per-item IMAGE, colours, tip and font with the item through inserts and removes", function()
		local img = iup.image{ WIDTH = 20, HEIGHT = 30, PIXELS = string.rep("0", 600), "0 0 0" }
		local list = iup.flatlist{ "a", "b" }
		iup.SetAttributeId(list, "IMAGE", 2, img)
		iup.SetAttributeId(list, "ITEMFGCOLOR", 2, "1 2 3")
		iup.SetAttributeId(list, "ITEMTIP", 2, "tip b")
		iup.SetAttribute(list, "INSERTITEM1", "z")
		assert.are.equal("b", iup.GetAttribute(list, "3"))
		assert.are.equal("1 2 3", iup.GetAttribute(list, "ITEMFGCOLOR3"))
		assert.are.equal("tip b", iup.GetAttribute(list, "ITEMTIP3"))
		assert.is_nil(iup.GetAttribute(list, "ITEMFGCOLOR1"))
		iup.SetAttribute(list, "REMOVEITEM", "1")
		assert.are.equal("1 2 3", iup.GetAttribute(list, "ITEMFGCOLOR2"))
		-- an id past the end is ignored, as the C setters do
		iup.SetAttributeId(list, "ITEMBGCOLOR", 9, "9 9 9")
		assert.is_nil(iup.GetAttribute(list, "ITEMBGCOLOR9"))
	end)

	it("line height is the tallest item's icon size (image, text and padding), at least the char height", function()
		local list = iup.flatlist{ "a", "b", BORDER = "NO", PADDING = "2x2", FOCUSFEEDBACK = "NO" }
		local st = placed(list, 100, 100)
		local _, ch = Fonts.get(iup.GetAttribute(list, "FONT")):charsize()
		local _, th = Draw.measureText(Fonts.get(iup.GetAttribute(list, "FONT")), "a")
		assert.are.equal(math.max(ch, th + 4), st.data.line_height)
		local img = iup.image{ WIDTH = 20, HEIGHT = 30, PIXELS = string.rep("0", 600), "0 0 0" }
		iup.SetAttributeId(list, "IMAGE", 1, img)
		st = placed(list, 100, 100)
		assert.are.equal(34, st.data.line_height) -- 30 + 2 * 2
		assert.are.equal("34", iup.GetAttribute(list, "LINEY"))
		-- SPACING adds between rows, and to LINEY
		iup.SetAttribute(list, "SPACING", "3")
		st = placed(list, 100, 100)
		assert.are.equal("37", iup.GetAttribute(list, "LINEY"))
		-- FOCUSFEEDBACK (the default) and CANFOCUS leave 2 px around each item for the focus rect
		iup.SetAttribute(list, "FOCUSFEEDBACK", "YES")
		st = placed(list, 100, 100)
		assert.are.equal(38, st.data.line_height)
	end)

	it("natural size: VISIBLELINES rows, the native frame (+2) and BORDERWIDTH", function()
		local list = iup.flatlist{ "a", "b", "c", VISIBLELINES = "2", SCROLLBAR = "NO" }
		local st = Element.state(list)
		local w, h = Classes.get("flatlist").natural(list, st, {})
		placed(list, 100, 100)
		local lh = st.data.line_height
		assert.are.equal(2 * lh + 2, h)
		iup.SetAttribute(list, "BORDER", "NO")
		iup.SetAttribute(list, "BORDERWIDTH", "1")
		local w2, h2 = Classes.get("flatlist").natural(list, st, {})
		assert.are.equal(2 * lh + 2, h2)
		assert.are.equal(w, w2)
		-- with a vertical bar and fewer visible lines than items, the bar's width is added
		iup.SetAttribute(list, "SCROLLBAR", "YES")
		local w3 = Classes.get("flatlist").natural(list, st, {})
		assert.are.equal(w2 + 17, w3)
	end)

	it("VALUE: nil when nothing is selected, the item number otherwise; VALUESTRING", function()
		local list = iup.flatlist{ "alpha", "beta" }
		assert.is_nil(iup.GetAttribute(list, "VALUE"))
		iup.SetAttribute(list, "VALUESTRING", "beta")
		assert.are.equal("2", iup.GetAttribute(list, "VALUE"))
		assert.are.equal("beta", iup.GetAttribute(list, "VALUESTRING"))
		iup.SetAttribute(list, "VALUE", "7") -- out of range: unchanged
		assert.are.equal("2", iup.GetAttribute(list, "VALUE"))
	end)

	it("multiple selection: plain, ctrl toggles, shift selects the interval from the last plain click", function()
		local list = iup.flatlist{ "a", "b", "c", "d", MULTIPLE = "YES", BORDER = "NO" }
		local seen = {}
		list.multiselect_cb = function(_, s) seen[#seen + 1] = s end
		local st = placed(list, 100, 200)
		local lh = st.data.line_height
		press(list, st, 5, 2)
		assert.are.equal("+---", iup.GetAttribute(list, "VALUE"))
		press(list, st, 5, 2 * lh + 2, { shift = true })
		assert.are.equal("+++-", iup.GetAttribute(list, "VALUE"))
		press(list, st, 5, lh + 2, { ctrl = true })
		assert.are.equal("+-+-", iup.GetAttribute(list, "VALUE"))
		-- no ctrl: the old selection is cleared first, so item 1 comes back as '+'
		assert.are.equal("+++x", seen[2])
		assert.are.equal("x-xx", seen[3])
	end)

	it("single selection fires FLAT_ACTION for the old item (0) then the new (1), then VALUECHANGED_CB", function()
		local list = iup.flatlist{ "a", "b", BORDER = "NO" }
		local seen = {}
		list.flat_action = function(_, text, pos, state) seen[#seen + 1] = text .. pos .. state end
		list.valuechanged_cb = function() seen[#seen + 1] = "changed" end
		local st = placed(list, 100, 100)
		press(list, st, 5, 2)
		press(list, st, 5, st.data.line_height + 2)
		press(list, st, 5, st.data.line_height + 2) -- the same item again: nothing
		assert.are.same({ "a11", "changed", "a10", "b21", "changed" }, seen)
	end)

	it("DBLCLICK_CB gets the item and its text on a double press", function()
		local list = iup.flatlist{ "a", "b", BORDER = "NO" }
		local got
		list.dblclick_cb = function(_, pos, text) got = { pos, text } end
		local st = placed(list, 100, 100)
		press(list, st, 5, st.data.line_height + 2, nil, true)
		assert.are.same({ 2, "b" }, got)
	end)

	it("the type-ahead is the element's K_ANY: it finds the next title by its first letter", function()
		local list = iup.flatlist{ "apple", "banana", "blueberry", "cherry", BORDER = "NO" }
		local st = placed(list, 100, 100)
		Classes.get("flatlist").event(list, st, { type = "focus" }, {})
		assert.are.equal(iup.CONTINUE, Element.call(list, "K_ANY", string.byte("b")))
		assert.are.equal("2", iup.GetAttribute(list, "VALUE"))
		Element.call(list, "K_ANY", string.byte("b"))
		assert.are.equal("3", iup.GetAttribute(list, "VALUE"))
		-- an application's K_ANY replaces it, as IupSetCallback does
		list.k_any = function() return iup.DEFAULT end
		Element.call(list, "K_ANY", string.byte("c"))
		assert.are.equal("3", iup.GetAttribute(list, "VALUE"))
	end)

	it("SHOWDRAGDROP moves the dragged item to the drop row and selects it", function()
		local list = iup.flatlist{ "a", "b", "c", SHOWDRAGDROP = "YES", BORDER = "NO" }
		local st = placed(list, 100, 200)
		local lh = st.data.line_height
		local fl = Classes.get("flatlist")
		fl.event(list, st, { type = "press", button = 1, lx = 5, ly = 2, status = iup._status({ b1 = true }) }, {})
		fl.event(list, st, { type = "move", lx = 5, ly = 2 * lh + 2, status = iup._status({ b1 = true }) }, {})
		fl.event(list, st, { type = "release", button = 1, lx = 5, ly = 2 * lh + 2, status = iup._status({}) }, {})
		assert.are.same({ "b", "a", "c" }, { iup.GetAttribute(list, "1"), iup.GetAttribute(list, "2"), iup.GetAttribute(list, "3") })
		assert.are.equal("2", iup.GetAttribute(list, "VALUE"))
	end)

	it("without FLATSCROLLBAR the native vertical bar shows once the rows overflow, and the wheel scrolls a line", function()
		local items = {}
		for i = 1, 30 do items[i] = "row " .. i end
		local list = iup.flatlist(items)
		local st = placed(list, 120, 100)
		assert.is_true(st.data.native_v)
		assert.are.equal(100 - 2, tonumber(iup.GetAttribute(list, "DY")) + 0) -- BORDER: the frame's 2 px
		Classes.get("flatlist").event(list, st, { type = "wheel", dy = -1, lx = 10, ly = 10 }, {})
		assert.are.equal(st.data.line_height, tonumber(iup.GetAttribute(list, "POSY")))
		-- a short list has no bar
		local short = iup.flatlist{ "x" }
		local ss = placed(short, 120, 100)
		assert.is_false(ss.data.native_v)
	end)

	it("draws the WS_BORDER frame and the item image", function()
		local img = iup.image{ WIDTH = 4, HEIGHT = 4, PIXELS = string.rep("1", 16), "0 0 0", "255 0 0" }
		local list = iup.flatlist{ "a" }
		iup.SetAttributeId(list, "IMAGE", 1, img)
		local st = placed(list, 80, 40)
		local backend = Null.new()
		local dc = Draw.new(backend); dc:begin(100, 60)
		Classes.get("flatlist").draw(list, st, dc, {})
		Classes.get("flatlist").drawAfter(list, st, dc, {})
		backend:frame_end()
		local frame, image
		for _, cmd in ipairs(backend:lastFrame()) do
			if cmd[1] == "rect" and cmd[2] == 0 and cmd[3] == 0 then frame = cmd end
			if cmd[1] == "image" then image = cmd end
		end
		assert.is_truthy(frame)
		assert.is_truthy(image)
	end)
end)
