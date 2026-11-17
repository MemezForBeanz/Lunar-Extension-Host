-- Round 8: overflowing content always scrolls, whatever was hidden when it was laid out;
-- content that fits shows no thumb.
local function state(Element, e) return Element.state(e) end

local function vertical_bar(Element, box)
	local bars = state(Element, box).data.scrollbars
	return bars and bars[1]
end

-- The viewport's visible rect, in dialog coordinates.
local function viewport(iup, Element, box)
	local s = state(Element, box)
	return s.y, s.y + tonumber(iup.GetAttribute(box, "DY"))
end

describe("scroll range of content laid out while hidden", function()
	local iup, Layout, Element

	before_each(function()
		iup = require("core.lui.test").boot({})
		Layout = require("core.imgui.Layout")
		Element = require("core.imgui.Element")
	end)

	-- A page (vbox) holding a scroll box; the page plays the tab page that is hidden
	-- until the user opens it.
	local function fixture(kind, rows, page_attrs)
		local children = {}
		for i = 1, rows do children[i] = iup.canvas{RASTERSIZE = "120x40"} end
		children.MARGIN, children.GAP = "0x0", "0"
		local content = iup.vbox(children)
		local box = iup[kind]{content, EXPAND = "YES", SCROLLBAR = "VERTICAL", FLATSCROLLBAR = "VERTICAL"}
		local page = iup.vbox{box, SHRINK = "YES", VISIBLE = page_attrs and page_attrs.VISIBLE or "NO"}
		Layout.run(page, 200, 100)
		return page, box, content, children[rows]
	end

	for _, kind in ipairs{"flatscrollbox", "scrollbox"} do
		it(kind .. " keeps its range when its page is shown after the first layout", function()
			local page, box = fixture(kind, 10)
			iup.SetAttribute(page, "VISIBLE", "YES")
			Layout.run(page, 200, 100)
			assert.equal(400, tonumber(iup.GetAttribute(box, "YMAX")))
			assert.is_true(tonumber(iup.GetAttribute(box, "DY")) < 400)
		end)

		it(kind .. " scrolls to the end and shows the last child", function()
			local page, box, _, last = fixture(kind, 10)
			iup.SetAttribute(page, "VISIBLE", "YES")
			Layout.run(page, 200, 100)
			iup.SetAttribute(box, "SCROLLTO", "BOTTOM")
			Layout.run(page, 200, 100)
			local top, bottom = viewport(iup, Element, box)
			local ls = state(Element, last)
			assert.is_true(ls.y >= top, "last child starts inside the viewport")
			assert.equal(bottom, ls.y + ls.h)
		end)

		it(kind .. " reports no overflow for content that fits", function()
			local page, box = fixture(kind, 2)
			iup.SetAttribute(page, "VISIBLE", "YES")
			Layout.run(page, 200, 100)
			assert.is_true(tonumber(iup.GetAttribute(box, "YMAX")) <= tonumber(iup.GetAttribute(box, "DY")))
		end)
	end

	it("flatscrollbox shows a thumb for overflow and none for content that fits", function()
		local page, box = fixture("flatscrollbox", 10)
		iup.SetAttribute(page, "VISIBLE", "YES")
		Layout.run(page, 200, 100)
		assert.equal("YES", iup.GetAttribute(vertical_bar(Element, box), "VISIBLE"))
		local small_page, small = fixture("flatscrollbox", 2)
		iup.SetAttribute(small_page, "VISIBLE", "YES")
		Layout.run(small_page, 200, 100)
		assert.equal("NO", iup.GetAttribute(vertical_bar(Element, small), "VISIBLE"))
	end)

	it("flatscrollbox reaches the end by the wheel", function()
		local page, box, _, last = fixture("flatscrollbox", 10)
		iup.SetAttribute(page, "VISIBLE", "YES")
		Layout.run(page, 200, 100)
		for _ = 1, 40 do require("core.imgui.widgets.flatscrollbar").on_wheel(box, -1) end
		Layout.run(page, 200, 100)
		assert.equal(400 - tonumber(iup.GetAttribute(box, "DY")), tonumber(iup.GetAttribute(box, "POSY")))
		local _, bottom = viewport(iup, Element, box)
		local ls = state(Element, last)
		assert.equal(bottom, ls.y + ls.h)
	end)

	it("flatscrollbox still ignores hidden sections inside its content", function()
		local page, box, content = fixture("flatscrollbox", 2, { VISIBLE = "YES" })
		iup.Append(content, iup.canvas{RASTERSIZE = "120x900", VISIBLE = "NO"})
		iup.SetAttribute(page, "VISIBLE", "NO")
		Layout.run(page, 200, 100)
		iup.SetAttribute(page, "VISIBLE", "YES")
		Layout.run(page, 200, 100)
		assert.equal(80, tonumber(iup.GetAttribute(box, "YMAX")))
		assert.equal("NO", iup.GetAttribute(vertical_bar(Element, box), "VISIBLE"))
	end)

	it("flatscrollbox keeps the end in view when the measured range is shorter than the allocation", function()
		local page, box, content = fixture("flatscrollbox", 10, { VISIBLE = "YES" })
		local tail = iup.canvas{RASTERSIZE = "120x300"}
		iup.Append(content, tail)
		Layout.run(page, 200, 100)
		iup.SetAttribute(box, "SCROLLTO", "BOTTOM")
		Layout.run(page, 200, 100)
		iup.SetAttribute(tail, "VISIBLE", "NO")
		Layout.run(page, 200, 100)
		local ymax, dy = tonumber(iup.GetAttribute(box, "YMAX")), tonumber(iup.GetAttribute(box, "DY"))
		assert.equal(400, ymax)
		assert.equal(ymax - dy, tonumber(iup.GetAttribute(box, "POSY")))
	end)
end)

describe("media title page scroll range", function()
	local iup, Layout, Element, old_path, old_raw

	before_each(function()
		old_path, old_raw = package.path, package.loaded.iupraw
		package.path = "extensions/media/?.lua;" .. old_path
		package.loaded.iupraw = require("core.imgui.native.iupraw")
		require("core.imgui.Runtime").init(require("core.imgui.backend.Null").new())
		iup = require("core.imgui.iup")
		Layout = require("core.imgui.Layout")
		Element = require("core.imgui.Element")
	end)
	after_each(function() package.path, package.loaded.iupraw = old_path, old_raw end)

	local function title_page()
		local film = { title = "Low Tide Radio", kind = "movie", year = 2018, minutes = 89,
			genres = { "Thriller" }, people = { "Ana Reyes" }, codec = "H.264", audio = "AAC 2.0",
			overview = "A radio operator hears a broadcast that should have stopped forty years ago." }
		local pool = { film }
		for i = 1, 8 do pool[#pool + 1] = { title = "Other " .. i, kind = "movie", year = 2017, genres = { "Thriller" } } end
		local api = require("ui.title").new({ iup = iup }, {
			pool = function() return pool end, on_back = function() end,
			on_play = function() end, on_mark = function() end, art = function() return nil end, decide = function() end, poster = function() return nil end,
		})
		return api, film
	end

	-- The page sits in a tab (zbox) behind another page, is filled while hidden, and only
	-- then becomes the visible one, as when a poster is opened from the library.
	local function shown_after_hidden(width, height)
		local api, film = title_page()
		local other = iup.vbox{ iup.canvas{ RASTERSIZE = "10x10" } }
		local tabs = iup.zbox{ other, api.widget, SHRINK = "YES" }
		iup.SetAttribute(tabs, "VALUE_HANDLE", other)
		Layout.run(tabs, width, height)
		api.setWidth(width)
		api.open(film)
		Layout.run(tabs, width, height)
		iup.SetAttribute(tabs, "VALUE_HANDLE", api.widget)
		Layout.run(tabs, width, height)
		local page = require("core.ui.Page").fromWidget(api.widget)
		return tabs, page.main
	end

	it("overflows at a narrow size, with a thumb, and reaches its last section", function()
		local tabs, box = shown_after_hidden(1000, 560)
		local ymax, dy = tonumber(iup.GetAttribute(box, "YMAX")), tonumber(iup.GetAttribute(box, "DY"))
		assert.is_true(ymax > dy, "range " .. ymax .. " exceeds the view " .. dy)
		assert.equal("YES", iup.GetAttribute(Element.state(box).data.scrollbars[1], "VISIBLE"))
		iup.SetAttribute(box, "SCROLLTO", "BOTTOM")
		Layout.run(tabs, 1000, 560)
		local body = iup.GetChild(box, 2) or iup.GetChild(box, 0)
		local last
		for i = iup.GetChildCount(body) - 1, 0, -1 do
			local child = iup.GetChild(body, i)
			if iup.GetAttribute(child, "FLOATING") ~= "YES" then last = child; break end
		end
		local bs, ls = Element.state(box), Element.state(last)
		assert.is_true(ls.y >= bs.y, "last section starts inside the view")
		assert.is_true(ls.y + ls.h <= bs.y + dy, "last section ends inside the view")
	end)

	it("shows no thumb at full width when everything fits", function()
		local _, box = shown_after_hidden(1800, 1000)
		local ymax, dy = tonumber(iup.GetAttribute(box, "YMAX")), tonumber(iup.GetAttribute(box, "DY"))
		assert.is_true(ymax <= dy, "range " .. ymax .. " fits the view " .. dy)
		assert.equal("NO", iup.GetAttribute(Element.state(box).data.scrollbars[1], "VISIBLE"))
	end)
end)

describe("scroll range of controls with internal parts", function()
	it("counts a trailing grid, whose only children are its own scroll bars", function()
		local iup = require("core.lui.test").boot({})
		local Layout = require("core.imgui.Layout")
		local Element = require("core.imgui.Element")
		local grid = iup.flatgrid{RASTERSIZE = "120x300"}
		local internal = 0
		for _, child in ipairs(Element.state(grid).children) do
			if Element.state(child).internal then internal = internal + 1 end
		end
		assert.is_true(internal > 0 and internal == #Element.state(grid).children)
		local content = iup.vbox{iup.canvas{RASTERSIZE = "120x40"}, grid, MARGIN = "0x0", GAP = "0"}
		local box = iup.flatscrollbox{content, EXPAND = "YES", FLATSCROLLBAR = "VERTICAL"}
		Layout.run(box, 200, 100)
		assert.equal(340, tonumber(iup.GetAttribute(box, "YMAX")))
	end)
end)
