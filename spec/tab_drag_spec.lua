-- spec/tab_drag_spec.lua — core.classes.TabOrder drop targeting.
--
-- The drop rule is browser-style: the middle half of a tab means "combine with
-- me", the outer quarters mean "insert beside me". Deciding which needs the
-- dragged pointer's position WITHIN the target tab, and IupFlatTabs exposes no
-- per-tab rectangle — the width of a tab depends on its title, font, padding,
-- image and close button. TabOrder therefore bisects ConvertXYToPos outward from
-- the pointer to find the tab's edges rather than reimplementing
-- iFlatTabsGetTabSize in Lua and letting it drift.
--
-- These tests pin that arithmetic against a strip with known tab boundaries: the
-- bisection has to land on the real edges, and each zone has to map to the right
-- operation. Getting it wrong is the difference between reordering a tab and
-- silently swallowing it into a group.

local TabOrder = require("core.classes.TabOrder")

-- A strip 300x200 whose tab band is the top 24px, with three tabs:
--   pos 0 : x   0..99    (a plain tab)
--   pos 1 : x 100..199   (a plain tab)
--   pos 2 : x 200..249   (a GROUP tab)
-- and empty bar past x=250.
local BAND, WIDTH, HEIGHT = 24, 300, 200
local LAYOUT = {
	{ from = 0,   to = 99  },
	{ from = 100, to = 199 },
	{ from = 200, to = 249 },
}

local function make_case()
	local strip = { id = "strip", cls = "flattabs" }
	local children = {
		{ id = "tab0", cls = "vbox" },
		{ id = "tab1", cls = "vbox" },
		{ id = "group", cls = "flattabs", is_group = true },
	}

	local iup = { DEFAULT = 0, BUTTON1 = 1 }

	-- The Lua binding allocates a fresh userdata on every push, so a handle
	-- fetched twice is two different Lua objects (core.lib.handle). GetChild here
	-- hands out a new proxy each call to reproduce that; without it the self-drop
	-- guard passes in the suite and fails in the product, which is how a plain
	-- click on a tab ended up wrapping it in a new group.
	local backing = setmetatable({}, { __mode = "k" })
	local function real(w) return w and (backing[w] or w) or nil end
	local function proxy(w)
		if w == nil then return nil end
		local p = setmetatable({}, { __index = w })
		backing[p] = w
		return p
	end
	iup._real = real

	function iup.GetAttribute(w, name)
		w = real(w)
		if name == "_IUPLUNAR_HANDLEID" then return w.handleid end
		if w ~= strip then return nil end
		if name == "SCREENPOSITION" then return "0,0" end
		if name == "RASTERSIZE" then return WIDTH .. "x" .. HEIGHT end
		if name == "CLIENTSIZE" then return WIDTH .. "x" .. (HEIGHT - BAND) end
		return nil
	end

	function iup.ConvertXYToPos(_, x, y)
		if y < 0 or y >= BAND or x < 0 or x >= WIDTH then return -1 end
		for i, span in ipairs(LAYOUT) do
			-- Exclusive bounds mirror iFlatTabsFindTab, which leaves a 1px seam
			-- between adjacent tabs.
			if x > span.from and x < span.to then return i - 1 end
		end
		return -1
	end

	function iup.GetChild(_, index) return proxy(children[index + 1]) end
	function iup.SetAttribute(w, name, value)
		w = real(w)
		if name == "_IUPLUNAR_HANDLEID" then w.handleid = value end
		if name == "RUN" then w.running = (value == "YES") end
	end
	function iup.GetClassName(w) return real(w).cls end
	function iup.Refresh() end

	-- Timers are collected so a test can fire them deliberately: the drop is
	-- applied on a one-shot timer, not inside the button callback.
	local timers = {}
	function iup.timer(def)
		local t = { def = def, running = false }
		timers[#timers + 1] = t
		return t
	end
	local function fire_timers()
		for _, t in ipairs(timers) do
			if t.running and t.action_cb then t.action_cb(t) end
		end
	end

	local order = TabOrder:new({ iup = iup })
	order:setGroups({
		stripsDeepestFirst = function() return { strip } end,
		isGroupStrip = function(_, w) return w ~= nil and real(w).is_group == true end,
		stripOf = function() return nil end,
	})

	return order, strip, children, real, fire_timers
end

describe("TabOrder drop targeting", function()
	local order, strip, children, unwrap

	before_each(function()
		order, strip, children, unwrap = make_case()
	end)

	local function drop(x, dragged)
		return order:_resolveDrop(strip, x, BAND / 2, dragged or children[3])
	end

	it("finds a tab's real edges by bisecting the control's hit test", function()
		local left, right = order:_tabBounds(strip, 1, 150, BAND / 2, WIDTH)
		assert.are.equal(101, left)
		assert.are.equal(198, right)
	end)

	it("treats the middle of a plain tab as combine-into-a-new-group", function()
		local result = drop(50)
		assert.are.equal(children[1], unwrap(result.merge))
		assert.is_nil(result.into)
	end)

	it("treats the middle of a group tab as add-to-that-group", function()
		-- The reported bug: this resolved as `merge`, so dropping an extension on
		-- an existing group built a NEW group wrapping the old one instead of
		-- adding the extension to it.
		local result = drop(225, children[1])
		assert.are.equal(children[3], unwrap(result.into))
		assert.is_nil(result.merge)
	end)

	it("ignores a click that lands on the tab being dragged", function()
		-- A press and release on the same tab is an ordinary CLICK. The guard for
		-- it compared handles with `==`, which is never true across two pushes, so
		-- every click resolved as dropping the tab onto itself and wrapped it in a
		-- brand new group.
		local pressed = order:_child(strip, 0)   -- a fresh handle, as on press
		local result = order:_resolveDrop(strip, 50, BAND / 2, pressed)
		assert.is_nil(result)
	end)

	it("ignores a click on a group tab, rather than nesting it in itself", function()
		local pressed = order:_child(strip, 2)
		local result = order:_resolveDrop(strip, 225, BAND / 2, pressed)
		assert.is_nil(result)
	end)

	it("treats the outer quarters as insert before and after", function()
		-- Tab 1 spans 101..198; a quarter is ~24px.
		assert.are.equal(2, drop(110).index)   -- left quarter  -> before pos 1
		assert.are.equal(3, drop(190).index)   -- right quarter -> after  pos 1
		assert.are.equal(strip, drop(110).strip)
	end)

	it("appends when dropped on the empty part of the bar", function()
		local result = drop(280)
		assert.are.equal(strip, result.strip)
		assert.is_nil(result.index)
	end)

	it("ignores a drop below the tab bar, in the page area", function()
		assert.is_nil(order:_resolveDrop(strip, 50, BAND + 40, children[3]))
	end)

	it("ignores a drop onto the tab being dragged", function()
		assert.is_nil(drop(50, children[1]))
	end)
end)

-- The gestures as the user performs them, driven through the real callbacks
-- rather than by calling _resolveDrop directly. Both bugs below were invisible to
-- the drop-targeting tests above, because both live in the press/move/release
-- sequencing rather than in the geometry.
describe("TabOrder gestures", function()
	local order, strip, children, unwrap, fire_timers, applied

	before_each(function()
		order, strip, children, unwrap, fire_timers = make_case()
		applied = {}
		order:setGroups({
			stripsDeepestFirst = function() return { strip } end,
			isGroupStrip = function(_, w) return w ~= nil and unwrap(w).is_group == true end,
			stripOf = function() return nil end,
			moveInto = function(_, w, target, index)
				applied[#applied + 1] = { op = "moveInto", widget = unwrap(w),
					target = unwrap(target), index = index }
				return true
			end,
			groupTogether = function(_, first, second)
				applied[#applied + 1] = { op = "groupTogether", first = unwrap(first),
					second = unwrap(second) }
			end,
		})
		order:install(strip)
	end)

	local function press(x) strip.flat_button_cb(strip, 1, 1, x, BAND / 2, "") end
	local function move(x)  strip.flat_motion_cb(strip, x, BAND / 2, "") end
	local function release(x) strip.flat_button_cb(strip, 1, 0, x, BAND / 2, "") end

	it("does nothing at all for a plain click", function()
		-- THE reported bug: clicking between tabs silently combined them into a
		-- group. The press switches the active tab, which can shift the strip's
		-- scroll position and move every tab, so the release hit-tests to a
		-- different tab at the same pixel. Only travel distinguishes drag from
		-- click.
		press(50)
		release(50)
		fire_timers()
		assert.are.equal(0, #applied)
	end)

	it("does nothing for a click that wobbles a pixel or two", function()
		press(50)
		move(52)
		release(52)
		fire_timers()
		assert.are.equal(0, #applied)
	end)

	it("does nothing when the release lands on a different tab without travel", function()
		-- Exactly the scroll-shift case: no motion events at all, yet the release
		-- resolves to another tab.
		press(50)
		release(150)
		fire_timers()
		assert.are.equal(0, #applied)
	end)

	it("acts once the pointer has actually travelled", function()
		press(50)
		move(150)
		release(150)
		fire_timers()
		assert.are.equal(1, #applied)
		assert.are.equal("groupTogether", applied[1].op)
		assert.are.equal(children[2], applied[1].first)
		assert.are.equal(children[1], applied[1].second)
	end)

	it("applies the drop on a timer, not inside the button callback", function()
		-- Rearranging the widget tree from inside FLAT_BUTTON_CB destroys and
		-- recreates native windows while the strip is still dispatching the mouse
		-- event, and while IupFlatTabs' own handler is still to run against the
		-- children being moved. That crashed the process about half the time.
		press(50)
		move(150)
		release(150)
		assert.are.equal(0, #applied)   -- nothing yet: the callback has returned
		fire_timers()
		assert.are.equal(1, #applied)
	end)
end)
