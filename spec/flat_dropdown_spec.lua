-- core.ui.FlatDropdown: the owner-drawn dropdown every list choice uses, with the
-- fixes the Build Queue selectors arrived at.

local FlatDropdown = require("core.ui.FlatDropdown")

local function fake_iup()
	local iup = { DEFAULT = -2, BUTTON1 = 49, handles = {} }
	local function widget(kind) return function(attrs) attrs.kind = kind; return attrs end end
	iup.flatlist, iup.dropbutton = widget("flatlist"), widget("dropbutton")
	function iup.SetAttribute(w, k, v) w[k] = v end
	function iup.GetAttribute(w, k) return w[k] end
	function iup.SetHandle(name, w) iup.handles[name] = w end
	function iup.SetFocus(w) iup.focus = w end
	return iup
end

-- The user clicks row `index` (press then release at the same spot).
local function pick(dd, index)
	dd.list.VALUE = tostring(index)
	dd.list:valuechanged_cb()      -- IUP applies the selection on press
	dd.list:flat_button_cb(49, 1, 10, 10)
	dd.list:flat_button_cb(49, 0, 10, 10)
end

describe("FlatDropdown", function()
	it("is an owner-drawn dropbutton with a themed flat list, not a native combo", function()
		local iup = fake_iup()
		local dd = FlatDropdown.new(iup, { items = { "a", "b" }, value = 2, width = 120 })
		assert.are.equal("dropbutton", dd.widget.kind)
		assert.are.equal("flatlist", dd.list.kind)
		assert.are.equal("dropbutton", dd.widget.THEMEROLE)
		assert.are.equal("dropdown_list", dd.list.THEMEROLE)
		assert.are.equal("NO", dd.list.SCROLLBAR)
		assert.are.equal("120x", dd.widget.RASTERSIZE)
		assert.are.equal(dd.list, iup.handles[dd.widget.DROPCHILD])
		assert.are.equal("b", dd.widget.TITLE)
		assert.are.equal("2", dd.list.VALUE)
	end)

	it("gives every instance its own drop child", function()
		local iup = fake_iup()
		local a = FlatDropdown.new(iup, { items = { "x" } })
		local b = FlatDropdown.new(iup, { items = { "y" } })
		assert.are_not.equal(a.widget.DROPCHILD, b.widget.DROPCHILD)
		assert.are.equal(b.list, iup.handles[b.widget.DROPCHILD])
	end)

	it("shows the placeholder until something is selected", function()
		local dd = FlatDropdown.new(fake_iup(), { items = { "a" }, placeholder = "(none)" })
		assert.are.equal("(none)", dd.widget.TITLE)
		assert.is_nil(dd:value())
	end)

	it("reports a user's pick, updates the caption and closes the popup", function()
		local got = {}
		local dd = FlatDropdown.new(fake_iup(), { items = { "a", "b", "c" }, value = 1,
			on_change = function(i, label) got[#got + 1] = { i, label } end })
		pick(dd, 3)
		assert.are.same({ { 3, "c" } }, got)
		assert.are.equal("c", dd.widget.TITLE)
		assert.are.equal("c", dd.widget.TIP)
		assert.are.equal(3, dd:value())
		assert.are.equal("c", dd:label())
		assert.are.equal("NO", dd.widget.SHOWDROPDOWN)
	end)

	it("closes when the already-selected item is picked again (no VALUECHANGED)", function()
		local dd = FlatDropdown.new(fake_iup(), { items = { "a", "b" }, value = 1 })
		dd.list:flat_button_cb(49, 1, 5, 5)
		dd.list:flat_button_cb(49, 0, 5, 5)
		assert.are.equal("NO", dd.widget.SHOWDROPDOWN)
	end)

	it("doesn't close on a drag or on a click on the list's scrollbar", function()
		local dd = FlatDropdown.new(fake_iup(), { items = { "a", "b" } })
		dd.list.RASTERSIZE = "200x100"
		dd.list.YHIDDEN = "NO"                          -- the scrollbar is showing
		dd.list:flat_button_cb(49, 1, 10, 10)
		dd.list:flat_button_cb(49, 0, 10, 40)          -- dragged 30px
		assert.is_nil(dd.widget.SHOWDROPDOWN)
		dd.list:flat_button_cb(49, 1, 195, 20)
		dd.list:flat_button_cb(49, 0, 195, 20)         -- on the 12px scrollbar
		assert.is_nil(dd.widget.SHOWDROPDOWN)
	end)

	it("changes items and value from code without calling on_change", function()
		local calls = 0
		local dd = FlatDropdown.new(fake_iup(), { items = { "a", "b", "c" }, value = 3,
			on_change = function() calls = calls + 1 end })
		dd:setItems({ "x", "y" }, 2)
		assert.are.equal("x", dd.list["1"])
		assert.are.equal("y", dd.list["2"])
		assert.is_nil(dd.list["3"])                       -- truncated
		assert.are.equal("y", dd.widget.TITLE)
		dd:setValue(1)
		assert.are.equal("x", dd.widget.TITLE)
		dd:setValue(9)                                    -- out of range
		assert.is_nil(dd:value())
		assert.are.equal(0, calls)
	end)

	it("caps the open list's height so long lists scroll", function()
		local items = {}
		for i = 1, 40 do items[i] = "item " .. i end
		local dd = FlatDropdown.new(fake_iup(), { items = items, max_lines = 10 })
		assert.are.equal("10", dd.list.VISIBLELINES)
		dd:setItems({ "only" })
		assert.are.equal("1", dd.list.VISIBLELINES)
	end)

	it("treats the right edge as a row when the scrollbar is hidden", function()
		local dd = FlatDropdown.new(fake_iup(), { items = { "a", "b" } })
		dd.list.RASTERSIZE = "200x100"
		dd.list.YHIDDEN = "YES"
		dd.list:flat_button_cb(49, 1, 195, 20)
		dd.list:flat_button_cb(49, 0, 195, 20)
		assert.are.equal("NO", dd.widget.SHOWDROPDOWN)
	end)

	it("Enter in the open list closes it and returns focus to the button", function()
		local iup = fake_iup()
		local dd = FlatDropdown.new(iup, { items = { "a", "b" }, value = 1 })
		dd.list:k_cr()
		assert.are.equal("NO", dd.widget.SHOWDROPDOWN)
		assert.are.equal(dd.widget, iup.focus)
	end)

	it("steps through the choices with the arrow keys while closed", function()
		local got = {}
		local dd = FlatDropdown.new(fake_iup(), { items = { "a", "b", "c" }, value = 2,
			on_change = function(i) got[#got + 1] = i end })
		dd.widget.k_down()
		assert.are.equal(3, dd:value())
		assert.are.equal("3", dd.list.VALUE)
		assert.are.equal("c", dd.widget.TITLE)
		dd.widget.k_down()                                 -- already last: no event
		dd.widget.k_home()
		dd.widget.k_up()                                   -- already first
		dd.widget.k_end()
		assert.are.same({ 3, 1, 3 }, got)
	end)
end)
