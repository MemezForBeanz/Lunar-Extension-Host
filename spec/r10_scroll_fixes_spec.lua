-- Round 10: the narrow captures' scroll and cut-off fixes, and the narrow page header.
local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local Element = require("core.imgui.Element")
local Layout = require("core.imgui.Layout")

describe("round 10 scroll fixes on the ImGui host", function()
	local iup
	before_each(function()
		R.init(Null.new())
		iup = require("core.imgui.iup")
	end)

	it("scrolls a native text box a few pixels short of its last line to that line", function()
		local t = iup.multiline{ VALUE = "one\ntwo\nthree", BORDER = "NO", SCROLLBAR = "NO", EXPAND = "YES" }
		local box = iup.flatscrollbox{ t, NATIVETEXTSCROLL = "YES", FLATSCROLLBAR = "VERTICAL", EXPAND = "YES" }
		local _, ch
		local dlg = iup.dialog{ iup.vbox{ box, MARGIN = "0x0", GAP = "0" }, RASTERSIZE = "300x100", BORDER = "NO" }
		iup.Show(dlg); R.frame()
		_, ch = require("core.imgui.Fonts").forElement(t):charsize()
		-- a view one pixel short of three lines: the range is that one pixel
		iup.SetAttribute(dlg, "RASTERSIZE", "300x" .. (3 * ch - 1)); iup.Refresh(dlg); R.frame(); R.frame()
		local ymax, dy = tonumber(iup.GetAttribute(box, "YMAX")), tonumber(iup.GetAttribute(box, "DY"))
		assert.is_true(ymax > dy and ymax - dy < ch)
		iup.SetAttribute(box, "POSY", tostring(ymax - dy)); R.frame()
		local first = tonumber(iup.GetAttribute(t, "FIRSTVISIBLELINE"))
		local shown = require("core.imgui.widgets.text").mlVisibleLines(t, Element.state(t))
		assert.is_true(first + shown - 1 >= 3)
		iup.SetAttribute(box, "POSY", "0"); R.frame()
		assert.equal("1", iup.GetAttribute(t, "FIRSTVISIBLELINE"))
	end)

	it("keeps the shown page's minimum height in a KEEPPAGEMIN strip, and nothing without it", function()
		local function strip(keep)
			local page = iup.vbox{ iup.label{ TITLE = "x", MINSIZE = "40x90", EXPAND = "YES" }, EXPAND = "YES" }
			local tabs = iup.flattabs{ page, KEEPPAGEMIN = keep, EXPAND = "YES" }
			local dlg = iup.dialog{ iup.vbox{ tabs }, RASTERSIZE = "300x300", BORDER = "NO" }
			iup.Show(dlg); R.frame()
			return tabs, page
		end
		local kept, page = strip("YES")
		local bar = Element.state(kept).h - Element.state(page).h
		assert.equal(90 + bar, Layout.minContent(kept, false))
		assert.equal(0, Layout.minContent(kept, true))
		local plain = strip(nil)
		assert.equal(0, Layout.minContent(plain, false))
	end)
end)

describe("round 10 page and shell fixes", function()
	local iup
	before_each(function()
		iup = { DEFAULT = 0 }
		for _, kind in ipairs({ "scrollbox", "text", "flatlabel", "flatbutton", "vbox", "hbox", "fill", "split", "zbox", "flatframe" }) do
			iup[kind] = function(attrs) attrs.kind = kind; return attrs end
		end
		iup.SetAttribute = function(w, k, v) w[k] = v end
		iup.GetAttribute = function(w, k) return w[k] end
		iup.ResetAttribute = function(w, k) w[k] = nil end
		iup.Refresh = function() end
		iup.Detach = function() end
		iup.GetClassName = function(w) return w.kind end
		iup.GetChild = function(w, n) return w[n + 1] end
	end)

	it("takes an empty pane's hidden placeholder out of the content's size", function()
		local Kit = require("core.ui.Kit")
		local pane, set_empty = Kit.emptyPane(iup, { content = iup.vbox{}, title = "Nothing" })
		local placeholder = pane[1]
		set_empty(false)
		assert.equals("IGNORE", placeholder.FLOATING)
		assert.equals("1", pane.VALUEPOS)
		set_empty(true)
		assert.equals("NO", placeholder.FLOATING)
	end)

	it("ends the dock summary in an ellipsis with the sentence as its tip", function()
		local Kit = require("core.ui.Kit")
		local page = Kit.page(iup, { dock = { widget = iup.vbox{}, summary = "No output" } })
		assert.equals("YES", page.dockSummary.TEXTELLIPSIS)
		page:setDockSummary("error", "Parse stopped at byte 0x18: invalid instruction")
		assert.equals("Parse stopped at byte 0x18: invalid instruction", page.dockSummary.TIP)
	end)

	it("folds Configure under More when the narrow header would cut the state line", function()
		local Kit = require("core.ui.Kit")
		local page = Kit.page(iup, { title = "Scan Chain", config = { widget = iup.vbox{} }, main = iup.vbox{},
			primary = { title = "Parse" } })
		local widths = { [page.title] = 120, [page.configure] = 100, [page.overflow] = 70, [page.primary] = 104 }
		function page:measure(w) return widths[w] or 0 end
		page:fit(700)
		assert.equals("NO", page.configure.FLOATING)
		assert.is_false(page.configureFolded)
		page:fit(480)
		assert.is_true(page.configureFolded)
		assert.equals("YES", page.configure.FLOATING)
		assert.equals("NO", page.overflow.FLOATING)
	end)

	it("stops the terminal where the panes' minimum begins, never below its own", function()
		local ViewLayout = require("core.ui.ViewLayout")
		local terminal = { setHeight = function(self, v) self.height = v end }
		local bar = { setReveal = function() end }
		local fake = { SetAttribute = function() end, Refresh = function() end, timer = function() return {} end }
		local layout = ViewLayout.new({ iup = fake, root = {}, rail = bar, status = bar, terminal = terminal })
		local room = 200
		layout:setRoom(function() return room end)
		layout:toggleTerminal()
		assert.equals(200, terminal.height)
		room = 40
		layout:setTerminalHeight(260)
		assert.equals(120, terminal.height)
		room = nil
		layout:setTerminalHeight(260)
		assert.equals(260, terminal.height)
	end)
end)
