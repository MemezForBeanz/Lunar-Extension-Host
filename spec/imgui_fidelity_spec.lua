-- The ImGui host against IUP's own rules: ordered input, the generic mouse callbacks,
-- internal children, font strings, dialog resizing and the sizes IUP's drivers compute.
local Null = require("core.imgui.backend.Null")

local function host(opts)
	local Runtime = require("core.imgui.Runtime")
	local B = Null.new(opts)
	Runtime.init(B)
	local Element = require("core.imgui.Element")
	Element.globals.DEFAULTFONT = "Segoe UI, 9"
	return require("core.imgui.iup"), Runtime, B, Element
end

local function show(iup, R, child, size)
	local d = iup.dialog({ iup.vbox({ child }), RASTERSIZE = size or "300x200" })
	iup.Show(d)
	R.frame()
	return d
end

describe("imgui ordered input", function()
	it("clicks a button whose press and release arrive in one frame (a tap)", function()
		local iup, R, B = host()
		local fired = 0
		local b = iup.flatbutton({ TITLE = "Go", RASTERSIZE = "80x30" })
		function b:flat_action() fired = fired + 1; return iup.DEFAULT end
		show(iup, R, b)
		B.queue({ events = {
			{ type = "move", x = 20, y = 10 },
			{ type = "press", button = 1, x = 20, y = 10 },
			{ type = "release", button = 1, x = 20, y = 10 },
		} })
		R.frame()
		assert.equal(1, fired)
	end)

	it("clicks at the press position even when the pointer leaves in the same frame", function()
		local iup, R, B = host()
		local fired = 0
		local b = iup.flatbutton({ TITLE = "Go", RASTERSIZE = "80x30" })
		function b:flat_action() fired = fired + 1; return iup.DEFAULT end
		show(iup, R, b)
		B.queue({ events = {
			{ type = "move", x = 20, y = 10 },
			{ type = "press", button = 1, x = 20, y = 10 },
			{ type = "release", button = 1, x = 20, y = 10 },
			{ type = "leave" },
		} })
		R.frame()
		assert.equal(1, fired)
	end)

	it("routes two clicks on two buttons in one frame to each, in order", function()
		local iup, R, B = host()
		local order = {}
		local a = iup.flatbutton({ TITLE = "A", RASTERSIZE = "80x30" })
		local b = iup.flatbutton({ TITLE = "B", RASTERSIZE = "80x30" })
		function a:flat_action() order[#order + 1] = "a"; return iup.DEFAULT end
		function b:flat_action() order[#order + 1] = "b"; return iup.DEFAULT end
		show(iup, R, iup.hbox({ a, b }))
		B.queue({ events = {
			{ type = "move", x = 100, y = 10 }, { type = "press", button = 1 }, { type = "release", button = 1 },
			{ type = "move", x = 20, y = 10 }, { type = "press", button = 1 }, { type = "release", button = 1 },
		} })
		R.frame()
		assert.same({ "b", "a" }, order)
	end)

	it("types keys between clicks in the order they happened", function()
		local iup, R, B = host()
		local log = {}
		local t = iup.text({ RASTERSIZE = "100x20" })
		function t:k_any(c) log[#log + 1] = c; return iup.DEFAULT end
		show(iup, R, t)
		B.queue({ events = {
			{ type = "move", x = 10, y = 5 }, { type = "press", button = 1 }, { type = "release", button = 1 },
			{ type = "char", char = "x" },
		} })
		R.frame()
		assert.same({ string.byte("x") }, log)
	end)
end)

describe("imgui generic mouse callbacks", function()
	it("gives a plain label BUTTON_CB with IUP's arguments", function()
		local iup, R, B = host()
		local got
		local l = iup.label({ TITLE = "status", RASTERSIZE = "60x20" })
		function l:button_cb(button, pressed, x, y, status) got = got or { button, pressed, x, y, status }; return iup.DEFAULT end
		show(iup, R, l)
		B.queue({ events = { { type = "move", x = 12, y = 7 }, { type = "press", button = 1 } } })
		R.frame()
		assert.equal(string.byte("1"), got[1])
		assert.equal(1, got[2])
		assert.equal(12, got[3])
		assert.equal(7, got[4])
		assert.equal("string", type(got[5]))
	end)

	it("does not fire BUTTON_CB twice on a class that handles it", function()
		local iup, R, B = host()
		local n = 0
		local c = iup.canvas({ RASTERSIZE = "60x20" })
		function c:button_cb() n = n + 1; return iup.DEFAULT end
		show(iup, R, c)
		B.queue({ events = { { type = "move", x = 5, y = 5 }, { type = "press", button = 1 } } })
		R.frame()
		assert.equal(1, n)
	end)
end)

describe("imgui internal children", function()
	it("keeps an internal first child first, as iChildTreeInsert does", function()
		local iup, _, _, Element = host()
		local box = iup.vbox({})
		local sash = iup.fill({})
		Element.appendInternal(box, sash, true)
		local a, b = iup.fill({}), iup.fill({})
		iup.Append(box, a)
		iup.Insert(box, nil, b) -- before the first child: after the internal one
		assert.equal(sash, iup.GetChild(box, 0))
		assert.equal(b, iup.GetChild(box, 1))
		assert.equal(a, iup.GetChild(box, 2))
		assert.equal(3, iup.GetChildCount(box))
		assert.same({ b, a }, Element.userChildren(box))
	end)
end)

describe("imgui font strings", function()
	local Fonts = require("core.imgui.Fonts")
	local cases = {
		{ "HPE Graphik Medium, 10", "HPE Graphik", 10, false, false },
		{ "Segoe UI, Bold 10", "Segoe UI", 10, true, false },
		{ "Times:BOLD,ITALIC:12", "Times", 12, true, true },
		{ "Arial, -12", "Arial", -12, false, false },
		{ "Segoe UI Semibold, 11", "Segoe UI Semibold", 11, false, false },
		{ "Consolas, Bold Italic 10", "Consolas", 10, true, true },
	}
	for _, c in ipairs(cases) do
		it("parses '" .. c[1] .. "' the way iupGetFontInfo does", function()
			local p = Fonts.parse(c[1])
			assert.equal(c[2], p.face)
			assert.equal(c[3], p.size)
			assert.equal(c[4], p.bold)
			assert.equal(c[5], p.italic)
		end)
	end

	it("rounds a point size to whole pixels like iupWIN_PT2PIXEL", function()
		host()
		Fonts.dpi = 96
		assert.equal(13, Fonts.get("Segoe UI, 10").px)
		assert.equal(15, Fonts.get("Segoe UI, 11").px)
	end)
end)

describe("imgui dialogs", function()
	it("calls RESIZE_CB before laying out, so sizes it sets apply at once", function()
		local iup, R, B = host()
		local inner = iup.fill({ RASTERSIZE = "10x10" })
		local d = iup.dialog({ iup.vbox({ inner }) })
		function d:resize_cb(w, h)
			iup.SetAttribute(inner, "RASTERSIZE", (w - 20) .. "x10")
			return iup.DEFAULT
		end
		iup.Show(d)
		R.frame()
		B.queue({ w = 500, h = 300 })
		R.frame()
		assert.equal("480x10", iup.GetAttribute(inner, "RASTERSIZE"))
		assert.equal("500x300", iup.GetAttribute(d, "CLIENTSIZE"))
	end)

	it("lays a dialog out on Refresh, so a size read back right after is the new one", function()
		local iup, R = host()
		show(iup, R, iup.fill({})) -- the main window; the panel is a dialog of its own
		local canvas = iup.canvas({ EXPAND = "YES" })
		local d = iup.dialog({ iup.vbox({ iup.fill({ RASTERSIZE = "x40" }), canvas }), RASTERSIZE = "300x200", BORDER = "NO" })
		iup.Show(d)
		R.frame()
		assert.equal("300x160", iup.GetAttribute(canvas, "RASTERSIZE"))
		iup.SetAttribute(d, "RASTERSIZE", "300x340")
		iup.Refresh(d)
		-- no frame in between: ActivityPanel measures this way to size its window
		assert.equal("300x300", iup.GetAttribute(canvas, "RASTERSIZE"))
	end)

	it("reports an automatic name for an unnamed current tab, and the handle name once set", function()
		local iup = host()
		local a, b = iup.vbox({}), iup.vbox({})
		local tabs = iup.flattabs({ a, b })
		local v = iup.GetAttribute(tabs, "VALUE")
		assert.matches("^_IUP_NAME%(", v)
		assert.equal(a, iup.GetHandle(v))
		assert.equal(a, iup.GetAttributeHandle(tabs, "VALUE"))
	end)
end)

describe("imgui text natural size", function()
	it("follows iTextComputeNaturalSizeMethod and the Windows driver", function()
		local iup, _, _, Element = host()
		local Layout = require("core.imgui.Layout")
		local Fonts = require("core.imgui.Fonts")
		local t = iup.text({ VISIBLECOLUMNS = "10", BORDER = "NO", PADDING = "4x9" })
		local f = Fonts.forElement(t)
		local _, ch = f:charsize()
		local ww = f:measure("WWWWWWWWWW")
		local w, h = Layout.natural(t)
		assert.equal(ww + 8, w)   -- horizontal padding only
		assert.equal(ch, h)       -- winTextSetPaddingAttrib drops the vertical part
		local bordered = iup.text({ VISIBLECOLUMNS = "5" })
		local bw, bh = Layout.natural(bordered)
		assert.equal(math.floor(5 * ww / 10) + 6, bw)
		assert.equal(ch + 6, bh)
		local _ = Element
	end)
end)
