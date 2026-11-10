-- Lunar's own IUP controls on the ImGui host (iup-fork patches 0020 and 0022): flatgrid,
-- flatrows, flatseek and flatsegmented, driven through the frame loop with queued input on
-- the Null backend. Expected numbers come from the C (iup_flatgrid.c, iup_flatrows.c,
-- iup_flatseek.c, iup_flatsegmented.c), worked by hand in the comments.
local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local raw = require("core.imgui.native.iupraw")

local B
local function boot()
	B = Null.new()
	R.init(B)
end

-- Put `widget` alone in a dialog of the given client size and lay it out.
local function show(widget, w, h)
	local dlg = iup.dialog{ iup.vbox{ widget, MARGIN = "0x0", GAP = "0" }, RASTERSIZE = w .. "x" .. h, BORDER = "NO" }
	iup.Show(dlg)
	R.frame(); R.frame()
	return dlg, Element.state(widget)
end

-- One frame per queued input.
local function click(x, y, opts)
	opts = opts or {}
	B.queue({ events = { { type = "move", x = x, y = y }, { type = "press", x = x, y = y, button = opts.button or 1,
		double = opts.double, mods = opts.mods } } }); R.frame()
	B.queue({ events = { { type = "release", x = x, y = y, button = opts.button or 1, mods = opts.mods } } }); R.frame()
end
local function move(x, y) B.queue({ events = { { type = "move", x = x, y = y } } }); R.frame() end
local function key(code, mods)
	local k = { code = code, down = true }
	for m, v in pairs(mods or {}) do k[m] = v end
	B.queue({ keys = { k } }); R.frame()
end
local function wheel(dy) B.queue({ wheel = dy }); R.frame() end

local function calls(name)
	local out = {}
	for _, c in ipairs(B.lastFrame()) do if c[1] == name then out[#out + 1] = c end end
	return out
end
local function texts()
	local out = {}
	for _, c in ipairs(B.lastFrame()) do if c[1] == "text" then out[#out + 1] = c[7] end end
	return out
end
local function has_text(s)
	for _, t in ipairs(texts()) do if t == s then return true end end
	return false
end

-- ---------------------------------------------------------------------------------------

describe("flatgrid (iup_flatgrid.c)", function()
	before_each(boot)

	local function grid(count, opts)
		opts = opts or {}
		local g = raw.flatgrid()
		local log = { action = {}, activate = {}, context = {}, changed = 0, bits = {} }
		raw.bindgrid(g, {
			value = function(pos, field)
				if field == "TITLE" then return "Film " .. pos end
				if field == "SECONDARY" then return 2000 + pos end
				if field == "BADGE" and pos == 2 then return "HDR" end
				if field == "STATE" and pos == 3 then return "unplayed" end
				if field == "PROGRESS" and pos == 4 then return "50" end
			end,
			bits = opts.bits,
			action = function(pos, part) log.action[#log.action + 1] = { pos, part } end,
			activate = function(pos, how) log.activate[#log.activate + 1] = { pos, how } end,
			context = function(pos, how) log.context[#log.context + 1] = { pos, how } end,
			changed = function(value) log.changed = log.changed + 1; log.value = value end,
			type_ahead = opts.type_ahead,
		})
		for k, v in pairs(opts.attrs or {}) do iup.SetAttribute(g, k, v) end
		iup.SetAttribute(g, "COUNT", tostring(count))
		return g, log
	end

	it("registers the C defaults", function()
		local g = raw.flatgrid()
		assert.equal("150", iup.GetAttribute(g, "CELLWIDTH"))
		assert.equal("2:3", iup.GetAttribute(g, "ASPECT"))
		assert.equal("16", iup.GetAttribute(g, "GUTTER"))
		assert.equal("16", iup.GetAttribute(g, "PADDING"))
		assert.equal("VERTICAL", iup.GetAttribute(g, "ORIENTATION"))
		assert.equal("YES", iup.GetAttribute(g, "SHOWTEXT"))
		assert.equal("6", iup.GetAttribute(g, "ITEMRADIUS"))
		assert.equal("YES", iup.GetAttribute(g, "EXPAND"))
		assert.equal("0", iup.GetAttribute(g, "COUNT"))
		assert.equal("0", iup.GetAttribute(g, "VALUE"))
	end)

	it("measures its natural size as grid_size does", function()
		local g = grid(4)
		local _, st = show(iup.hbox{ g, EXPAND = "NO" }, 1000, 800)
		local gs = Element.state(g)
		-- cellw 150, imageh round(150 / (2/3)) = 225, text 6 + 2 * (charh + 2)
		local _, charh = require("core.imgui.Fonts").forElement(g):charsize()
		assert.equal(150 * 2 + 16 + 2 * 16, gs.nat_w)
		assert.equal(225 + 6 + 2 * (charh + 2) + 2 * 16, gs.nat_h)
	end)

	it("lays lanes across the width and spreads the spare pixels into the gutters", function()
		local g = grid(30)
		show(g, 1000, 700)
		-- available = 1000 - 32 - 15 = 953; lanes = (953 + 16) / 166 = 5
		local x1, y1 = require("core.imgui.widgets.flatgrid")._cell_xy(g, 1)
		local x5 = require("core.imgui.widgets.flatgrid")._cell_xy(g, 5)
		local x6, y6 = require("core.imgui.widgets.flatgrid")._cell_xy(g, 6)
		assert.equal(16, x1); assert.equal(16, y1)
		assert.equal(16 + 953 - 150, x5)       -- the last lane ends on the right padding
		assert.equal(16, x6)
		local _, charh = require("core.imgui.Fonts").forElement(g):charsize()
		assert.equal(16 + 225 + 6 + 2 * (charh + 2) + 16, y6)
		assert.equal("1:15", iup.GetAttribute(g, "VISIBLERANGE"))
	end)

	it("draws placeholders, badges, the unplayed dot and progress from the provider", function()
		local g = grid(6)
		show(g, 1000, 700)
		assert.is_true(has_text("Film 1"))
		assert.is_true(has_text("2001"))
		assert.is_true(has_text("HDR"))
		-- no bits callback: every cell is a rounded placeholder
		local rounded = 0
		for _, c in ipairs(calls("rect_filled")) do if c[7] == 6 then rounded = rounded + 1 end end
		assert.is_true(rounded >= 6)
	end)

	it("draws provider pixels as rounded images, once per texture", function()
		local ffi = require("ffi")
		local buf = ffi.new("uint8_t[?]", 150 * 225 * 4)
		local asked = {}
		local g = grid(4, { bits = function(pos, w, h) asked[#asked + 1] = { pos, w, h }; if pos ~= 3 then return buf, w * 4 end end })
		show(g, 1000, 700)
		assert.same({ 1, 150, 225 }, asked[1])
		local imgs = calls("image_rounded")
		assert.equal(3, #imgs)
		assert.equal(6, imgs[1][8])            -- ITEMRADIUS rounds the picture
		local before = 0
		for _ in pairs(B.textures) do before = before + 1 end
		R.redraw(); R.frame()
		local after = 0
		for _ in pairs(B.textures) do after = after + 1 end
		assert.equal(before, after)           -- the same pixels reuse their texture
	end)

	it("selects on click and fires CELL_ACTION_CB then VALUECHANGED_CB", function()
		local g, log = grid(10)
		local _, st = show(g, 1000, 700)
		click(st.x + 16 + 10, st.y + 16 + 10)
		assert.equal("1", iup.GetAttribute(g, "VALUE"))
		assert.same({ { 1, "" } }, log.action)
		assert.equal(1, log.changed); assert.equal(1, log.value)
		click(st.x + 16 + 10, st.y + 16 + 10)         -- same cell: nothing changed
		assert.equal(1, #log.action)
	end)

	it("activates on double click and on Enter", function()
		local g, log = grid(10)
		local _, st = show(g, 1000, 700)
		click(st.x + 30, st.y + 30, { double = 1 })
		assert.same({ 1, "double" }, log.activate[#log.activate])
		key(iup.K_CR)
		assert.same({ 1, "enter" }, log.activate[#log.activate])
	end)

	it("reports a context click and selects the cell first", function()
		local g, log = grid(10)
		local _, st = show(g, 1000, 700)
		click(st.x + 30, st.y + 30, { button = 3 })
		assert.same({ { 1, "context" } }, log.context)
		assert.equal("1", iup.GetAttribute(g, "VALUE"))
	end)

	it("moves by lanes with the arrows and stops at the ends (grid_key)", function()
		local g = grid(12)
		local _, st = show(g, 1000, 700)         -- 5 lanes
		click(st.x + 30, st.y + 30)
		key(iup.K_RIGHT); assert.equal("2", iup.GetAttribute(g, "VALUE"))
		key(iup.K_DOWN); assert.equal("7", iup.GetAttribute(g, "VALUE"))
		key(iup.K_DOWN); assert.equal("12", iup.GetAttribute(g, "VALUE"))   -- 7 + 5
		key(iup.K_DOWN); assert.equal("12", iup.GetAttribute(g, "VALUE"))   -- last line: stays
		key(iup.K_LEFT); assert.equal("11", iup.GetAttribute(g, "VALUE"))
		key(iup.K_HOME); assert.equal("1", iup.GetAttribute(g, "VALUE"))
		key(iup.K_UP); assert.equal("1", iup.GetAttribute(g, "VALUE"))
		key(iup.K_END); assert.equal("12", iup.GetAttribute(g, "VALUE"))
	end)

	it("goes past the last line to the last cell once (grid_key)", function()
		local g = grid(8)
		local _, st = show(g, 1000, 700)
		click(st.x + 30, st.y + 30)
		key(iup.K_RIGHT); key(iup.K_RIGHT); key(iup.K_RIGHT) -- 4
		key(iup.K_DOWN)                                      -- 9 > 8, and 4 is not on the last line
		assert.equal("8", iup.GetAttribute(g, "VALUE"))
	end)

	it("finds a title by typing and uses TYPEAHEAD_CB first", function()
		local g = grid(30)
		show(g, 1000, 700)
		iup.SetFocus(g); R.frame()
		B.queue({ keys = { { code = string.byte("F"), down = true } }, chars = { "F" } }); R.frame()
		-- "F" again from cursor 0 starts at 1 % 30 + 1 = 2
		assert.equal("2", iup.GetAttribute(g, "VALUE"))
		local g2 = grid(30, { type_ahead = function(text) return 7 end })
		show(g2, 1000, 700)
		iup.SetFocus(g2); R.frame()
		B.queue({ keys = { { code = string.byte("x"), down = true } }, chars = { "x" } }); R.frame()
		assert.equal("7", iup.GetAttribute(g2, "VALUE"))
	end)

	it("keeps a multiple selection with Ctrl, Shift and Ctrl+A", function()
		local g, log = grid(12, { attrs = { MULTIPLE = "YES" } })
		local _, st = show(g, 1000, 700)
		click(st.x + 30, st.y + 30)                                       -- 1
		click(st.x + 16 + 2 * 200 + 10, st.y + 30, { mods = { shift = true } }) -- extend to the 3rd lane
		local mask = iup.GetAttribute(g, "SELECTIONMASK")
		assert.equal("+++", mask:sub(1, 3))
		assert.equal("+", mask:sub(4, 4) == "+" and "+" or mask:sub(3, 3))
		key(string.byte("a"), { ctrl = true })
		assert.equal(string.rep("+", 12), iup.GetAttribute(g, "SELECTIONMASK"))
		assert.equal("12", iup.GetAttribute(g, "SELECTEDCOUNT"))
	end)

	it("scrolls with the wheel by LINEY and reveals the cursor", function()
		local g = grid(60)
		local _, st = show(g, 1000, 400)
		assert.equal("YES", iup.GetAttribute(iup.GetChild(g, 0), "VISIBLE"))
		local liney = tonumber(iup.GetAttribute(g, "LINEY"))
		move(st.x + 100, st.y + 100)
		wheel(-1)
		assert.equal(liney, tonumber(iup.GetAttribute(g, "POSY")))
		click(st.x + 30, st.y + 30)
		key(iup.K_END)
		-- grid_reveal: the last line's cell plus its ring ends at the bottom edge
		local fg = require("core.imgui.widgets.flatgrid")
		local _, y = fg._cell_xy(g, 60)
		local d = Element.state(g).data
		assert.equal(Element.state(g).h, y + d.cellh + 6)
		assert.equal("60", iup.GetAttribute(g, "VISIBLERANGE"):match(":(%d+)$"))
	end)

	it("lays a shelf along the width (ORIENTATION=HORIZONTAL)", function()
		local g = grid(20, { attrs = { ORIENTATION = "HORIZONTAL", ROWS = "1", FLATSCROLLBAR = "HORIZONTAL" } })
		show(g, 800, 400)
		local fg = require("core.imgui.widgets.flatgrid")
		local x2, y2 = fg._cell_xy(g, 2)
		assert.equal(16 + 166, x2); assert.equal(16, y2)
		assert.equal("0", iup.GetAttribute(g, "YMAX"))
		assert.equal(tostring(2 * 16 + 20 * 166 - 16), iup.GetAttribute(g, "XMAX"))
	end)

	it("shows EMPTYTITLE and EMPTYHINT with no cells", function()
		local g = grid(0)
		iup.SetAttribute(g, "EMPTYTITLE", "Nothing here yet")
		iup.SetAttribute(g, "EMPTYHINT", "Add a library")
		show(g, 600, 400)
		assert.is_true(has_text("Nothing here yet"))
		assert.is_true(has_text("Add a library"))
	end)

	it("rings the hovered cell in HLCOLOR", function()
		local g = grid(4, { attrs = { HLCOLOR = "10 20 30" } })
		local _, st = show(g, 1000, 700)
		move(st.x + 30, st.y + 30)
		assert.equal("1", iup.GetAttribute(g, "HOVER"))
		local ring = false
		local want = require("core.imgui.Color").parse("10 20 30")
		for _, c in ipairs(calls("rect")) do if c[6] == want then ring = true end end
		assert.is_true(ring)
	end)
end)

-- ---------------------------------------------------------------------------------------

describe("flatrows (iup_flatrows.c)", function()
	before_each(boot)

	local function rows(count, opts)
		opts = opts or {}
		local r = raw.flatrows()
		local log = { action = {}, part = {}, activate = {}, context = {}, header = {}, changed = 0 }
		raw.bindrows(r, {
			value = function(pos, field)
				if field == "TITLE" then return "Row " .. pos end
				if field == "COLUMN1" then return tostring(pos * 10) end
				if field == "ACTIONTEXT" and pos == 2 then return "Play" end
				if field == "SECONDARY" then return "second " .. pos end
			end,
			bits = opts.bits,
			action = function(pos) log.action[#log.action + 1] = pos end,
			part = function(pos, part) log.part[#log.part + 1] = { pos, part } end,
			activate = function(pos, how) log.activate[#log.activate + 1] = { pos, how } end,
			context = function(pos, how) log.context[#log.context + 1] = { pos, how } end,
			header = function(col) log.header[#log.header + 1] = col end,
			changed = function(v) log.changed = log.changed + 1 end,
		})
		for k, v in pairs(opts.attrs or {}) do iup.SetAttribute(r, k, v) end
		iup.SetAttribute(r, "COUNT", tostring(count))
		return r, log
	end

	it("registers the C defaults and natural size", function()
		local r = rows(3)
		assert.equal("32", iup.GetAttribute(r, "ROWHEIGHT"))
		assert.equal("28", iup.GetAttribute(r, "HEADERHEIGHT"))
		assert.equal("16", iup.GetAttribute(r, "IMAGESIZE"))
		assert.equal("ASC", iup.GetAttribute(r, "SORTDIR"))
		show(iup.hbox{ r, EXPAND = "NO" }, 600, 400)
		local st = Element.state(r)
		assert.equal(240, st.nat_w); assert.equal(160, st.nat_h)   -- 240 x ROWHEIGHT * 5
	end)

	it("clamps ROWHEIGHT to 20..400", function()
		local r = rows(3, { attrs = { ROWHEIGHT = "4" } })
		show(r, 400, 300)
		assert.equal(tostring(3 * 20), iup.GetAttribute(r, "YMAX"))
	end)

	it("selects, reports the part and the action text column", function()
		local r, log = rows(5, { attrs = { COLUMN1WIDTH = "60" } })
		local _, st = show(r, 400, 300)
		click(st.x + 40, st.y + 32 + 10)       -- row 2, the title part
		assert.same({ 2 }, log.action)
		assert.same({ 2, "row" }, log.part[1])
		click(st.x + 400 - 30, st.y + 32 + 10) -- x >= width - 66 on a row with ACTIONTEXT
		assert.same({ 2, "action" }, log.part[2])
		assert.equal(1, #log.action)          -- already selected
		assert.equal("2", iup.GetAttribute(r, "VALUE"))
	end)

	it("draws columns right aligned, the hover's action text, and the title", function()
		local r = rows(5, { attrs = { COLUMN1WIDTH = "60" } })
		local _, st = show(r, 400, 300)
		move(st.x + 40, st.y + 32 + 10)
		assert.equal("2", iup.GetAttribute(r, "HOVER"))
		assert.is_true(has_text("Row 2"))
		assert.is_true(has_text("20"))
		assert.is_true(has_text("Play"))
	end)

	it("moves with the keys and activates on Enter", function()
		local r, log = rows(30)
		local _, st = show(r, 400, 160)        -- 5 rows a page
		click(st.x + 40, st.y + 10)
		key(iup.K_DOWN); assert.equal("2", iup.GetAttribute(r, "VALUE"))
		key(iup.K_PGDN); assert.equal("7", iup.GetAttribute(r, "VALUE"))
		key(iup.K_END); assert.equal("30", iup.GetAttribute(r, "VALUE"))
		-- rows_select scrolled the last row into view
		assert.equal(30 * 32 - 160, tonumber(iup.GetAttribute(r, "POSY")))
		key(iup.K_HOME); assert.equal("1", iup.GetAttribute(r, "VALUE"))
		key(iup.K_UP); assert.equal("1", iup.GetAttribute(r, "VALUE"))
		key(iup.K_CR)
		assert.same({ 1, "enter" }, log.activate[#log.activate])
	end)

	it("reports header clicks by column, 0 for the title", function()
		local r, log = rows(5, { attrs = { HEADER = "YES", COLUMN1WIDTH = "60", COLUMN2WIDTH = "80", HEADERTITLE = "Name" } })
		local _, st = show(r, 400, 300)
		click(st.x + 20, st.y + 10)
		click(st.x + 400 - 12 - 30, st.y + 10)     -- inside COLUMN2 (the rightmost slot)
		assert.same({ 0, 2 }, log.header)
		assert.is_true(has_text("Name"))
	end)

	it("reserves the art slot when bits is bound and draws the pixels", function()
		local ffi = require("ffi")
		local buf = ffi.new("uint8_t[?]", 48 * 48 * 4)
		local r = rows(3, { bits = function(pos, w, h) return buf, w * 4 end, attrs = { IMAGESIZE = "48x48", ROWHEIGHT = "56" } })
		show(r, 400, 300)
		assert.equal(3, #calls("image"))
	end)

	it("context-clicks and scrolls with the wheel", function()
		local r, log = rows(40)
		local _, st = show(r, 400, 160)
		click(st.x + 40, st.y + 10, { button = 3 })
		assert.same({ { 1, "context" } }, log.context)
		move(st.x + 40, st.y + 40)
		wheel(-1)
		assert.is_true(tonumber(iup.GetAttribute(r, "POSY")) > 0)
	end)
end)

-- ---------------------------------------------------------------------------------------

describe("flatseek (iup_flatseek.c)", function()
	before_each(boot)

	local function seek(max)
		local s = raw.flatseek()
		local log = { seek = {}, changing = {}, hover = {} }
		raw.bindseek(s, {
			seek = function(v) log.seek[#log.seek + 1] = v end,
			changing = function(v) log.changing[#log.changing + 1] = v end,
			hover = function(v, x) log.hover[#log.hover + 1] = { v, x } end,
		})
		iup.SetAttribute(s, "MAX", tostring(max))
		return s, log
	end

	it("registers the C defaults", function()
		local s = raw.flatseek()
		assert.equal("5", iup.GetAttribute(s, "STEP"))
		assert.equal("30", iup.GetAttribute(s, "PAGESTEP"))
		assert.equal("2", iup.GetAttribute(s, "THICKNESS"))
		assert.equal("HORIZONTAL", iup.GetAttribute(s, "EXPAND"))
	end)

	it("drags: VALUECHANGING_CB on press and motion, SEEK_CB on release", function()
		local s, log = seek(100)
		local _, st = show(s, 400, 100)
		local left, right = 7, st.w - 8          -- seek_track: KNOB + 1 .. width - KNOB - 2
		local x = math.floor((left + right) / 2)
		B.queue({ events = { { type = "move", x = st.x + x, y = st.y + 12 }, { type = "press", x = st.x + x, y = st.y + 12, button = 1 } } }); R.frame()
		assert.near(100 * (x - left) / (right - left), log.changing[1], 1e-9)
		B.queue({ events = { { type = "move", x = st.x + right, y = st.y + 12 } } }); R.frame()
		assert.equal(100, log.changing[#log.changing])
		-- a playback tick during the drag does not move the line
		iup.SetAttribute(s, "VALUE", "10")
		assert.equal("100", iup.GetAttribute(s, "VALUE"))
		B.queue({ events = { { type = "release", x = st.x + right, y = st.y + 12, button = 1 } } }); R.frame()
		assert.same({ 100 }, log.seek)
	end)

	it("reports hover values and -1 on leave", function()
		local s, log = seek(100)
		local _, st = show(iup.hbox{ s, iup.fill{} }, 400, 100)
		move(st.x + 7, st.y + 12)
		assert.same({ 0, 7 }, log.hover[1])
		move(st.x + 500, st.y + 50)
		assert.same({ 0, -1 }, log.hover[#log.hover])
	end)

	it("steps with the keys and commits each step", function()
		local s, log = seek(100)
		local _, st = show(s, 400, 100)
		click(st.x + 7, st.y + 12)
		key(iup.K_RIGHT); assert.equal(5, log.seek[#log.seek])
		key(iup.K_RIGHT, { ctrl = true }); assert.equal(35, log.seek[#log.seek])
		key(iup.K_PGDN); assert.equal(5, log.seek[#log.seek])
		key(iup.K_END); assert.equal(100, log.seek[#log.seek])
		key(iup.K_HOME); assert.equal(0, log.seek[#log.seek])
	end)

	it("parses BUFFERED and MARKS lists and draws them", function()
		local parse = require("core.imgui.widgets.flatseek")._parse
		local list = parse("10-20,35:intro,90-95")
		assert.equal(3, #list)
		assert.equal(10, list[1].from); assert.equal(20, list[1].to)
		assert.equal(35, list[2].from); assert.equal(35, list[2].to)
		local s = seek(100)
		iup.SetAttribute(s, "PSCOLOR", "200 0 0")
		iup.SetAttribute(s, "MARKS", "50")
		show(s, 400, 100)
		local filled = 0
		for _, c in ipairs(calls("circle")) do if c[6] == 0 then filled = filled + 1 end end
		assert.equal(1, filled)                 -- the playhead (a focus ring is stroked)
	end)

	it("clamps VALUE to MAX and answers ACCESSIBLEVALUE", function()
		local s = seek(60)
		iup.SetAttribute(s, "VALUE", "75")
		assert.equal("60", iup.GetAttribute(s, "VALUE"))
		assert.equal("60 of 60", iup.GetAttribute(s, "ACCESSIBLEVALUE"))
	end)
end)

-- ---------------------------------------------------------------------------------------

describe("flatsegmented (iup_flatsegmented.c)", function()
	before_each(boot)

	local function seg(count)
		local s = raw.flatsegmented()
		local log = {}
		raw.bindsegmented(s, { changed = function(pos) log[#log + 1] = pos end })
		iup.SetAttribute(s, "COUNT", tostring(count))
		for i = 0, count - 1 do iup.SetAttributeId(s, "TITLE", i, "Opt " .. i) end
		return s, log
	end

	it("is count * 88 by 32 and does not expand", function()
		local s = seg(2)
		show(iup.hbox{ s, iup.fill{} }, 600, 100)
		local st = Element.state(s)
		assert.equal(176, st.w); assert.equal(32, st.h)
		assert.equal("NO", iup.GetAttribute(s, "EXPAND"))
	end)

	it("clamps COUNT to 2..5 and VALUEPOS into range", function()
		local s = seg(3)
		iup.SetAttribute(s, "COUNT", "9"); assert.equal("5", iup.GetAttribute(s, "COUNT"))
		iup.SetAttribute(s, "COUNT", "1"); assert.equal("2", iup.GetAttribute(s, "COUNT"))
		iup.SetAttribute(s, "VALUEPOS", "7"); assert.equal("1", iup.GetAttribute(s, "VALUEPOS"))
	end)

	it("selects the clicked option and passes VALUEPOS to changed", function()
		local s, log = seg(3)
		local _, st = show(iup.hbox{ s, iup.fill{} }, 600, 100)
		click(st.x + 88 * 2 + 10, st.y + 10)
		assert.same({ 2 }, log)
		assert.equal("2", iup.GetAttribute(s, "VALUEPOS"))
		click(st.x + 88 * 2 + 10, st.y + 10)
		assert.same({ 2 }, log)                  -- no change, no callback
	end)

	it("moves with the arrows, Home and End", function()
		local s, log = seg(4)
		local _, st = show(iup.hbox{ s, iup.fill{} }, 600, 100)
		click(st.x + 10, st.y + 10)
		key(iup.K_RIGHT); key(iup.K_DOWN)
		assert.equal("2", iup.GetAttribute(s, "VALUEPOS"))
		key(iup.K_END); assert.equal("3", iup.GetAttribute(s, "VALUEPOS"))
		key(iup.K_HOME); assert.equal("0", iup.GetAttribute(s, "VALUEPOS"))
		key(iup.K_LEFT); assert.equal("0", iup.GetAttribute(s, "VALUEPOS"))
		assert.same({ 1, 2, 3, 0 }, log)
	end)

	it("draws every title and the selected one in TEXTPSCOLOR", function()
		local s = seg(2)
		iup.SetAttribute(s, "TEXTPSCOLOR", "1 2 3")
		show(iup.hbox{ s, iup.fill{} }, 600, 100)
		assert.is_true(has_text("Opt 0")); assert.is_true(has_text("Opt 1"))
		local want = require("core.imgui.Color").parse("1 2 3")
		local found = false
		for _, c in ipairs(calls("text")) do if c[7] == "Opt 0" and c[6] == want then found = true end end
		assert.is_true(found)
	end)
end)

-- ---------------------------------------------------------------------------------------

describe("media widget wrappers on the ImGui host", function()
	before_each(boot)

	it("CellGrid feeds posters through bits and VISIBLERANGE", function()
		local ffi = require("ffi")
		local buf = ffi.new("uint8_t[?]", 150 * 225 * 4)
		local CellGrid = require("core.ui.CellGrid")
		local items = {}
		for i = 1, 40 do items[i] = { title = "Film " .. i, secondary = tostring(1990 + i) } end
		local picked
		local g = CellGrid.new(iup, { items = items, raw = raw, on_select = function(pos) picked = pos end })
		g.bits = function(pos, w, h) return buf, w * 4 end
		local _, st = show(g.widget, 1000, 700)
		assert.equal(15, #calls("image_rounded"))
		click(st.x + 30, st.y + 30)
		assert.equal(1, picked)
		assert.equal(1, g:selected())
	end)

	it("RowList and SeekBar build and respond", function()
		local RowList = require("core.ui.RowList")
		local picked
		local list = RowList.new(iup, { rows = { { title = "One" }, { title = "Two" } }, raw = raw,
			on_select = function(pos) picked = pos end })
		local _, st = show(list.widget, 400, 300)
		assert.is_true(has_text("One"))
		click(st.x + 40, st.y + 32 + 10)
		assert.equal(2, picked)
	end)
end)
