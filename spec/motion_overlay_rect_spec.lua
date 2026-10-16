-- spec/motion_overlay_rect_spec.lua — resolving a widget's screen rectangle.
--
-- Everything the overlay composites is positioned from `rectOf`, so an error here
-- does not fail loudly: the animation runs, over the wrong pixels.
--
-- That is exactly how this regressed. `POSITION` was read as though it were
-- dialog-relative; IUP reports it relative to the **immediate parent**. A page of
-- the root tab strip and a page nested inside a group's sub-strip therefore both
-- report `1,27` -- each being 1,27 within its own tabs control -- and both resolved
-- to the same rectangle near the top of the window.
--
-- The visible symptom was oddly specific: switching between groups looked correct,
-- but switching between two extensions inside a group made the **top-level tab
-- bar** appear to slide. Both follow from the same cause. A group's page IS the
-- sub-strip, which owns a native window and answers `SCREENPOSITION` directly, so
-- that path never touched the broken arithmetic; an extension's page is a
-- window-less container, so it did, and the overlay ended up covering and
-- capturing the tab strips themselves.
--
-- `anchorOffset` is the traversal that was wrong. It takes the IUP binding as an
-- argument and touches no FFI, so it is testable here with a fake widget tree.

local MotionOverlay = require("core.ui.MotionOverlay")

-- A fake IUP whose widgets are plain tables:
--   { pos = "x,y", screen = "x,y" | nil, parent = <widget>, class = "..." }
-- `screen` is nil for the layout-only containers that caused the bug.
local function fake_iup()
	local iup = {}
	function iup.GetAttribute(w, name)
		if name == "POSITION" then return w.pos end
		if name == "SCREENPOSITION" then return w.screen end
		if name == "RASTERSIZE" then return w.raster end
		return nil
	end
	function iup.GetParent(w) return w.parent end
	function iup.GetClassName(w) return w.class or "vbox" end
	return iup
end

-- The shape that produced the bug: a dialog, a root tab strip that owns a window,
-- one plain page, and a group page which is itself a tab strip with its own pages.
local function tree()
	local dlg      = { class = "dialog", pos = "0,0", screen = "200,200" }
	local box      = { class = "vbox",   pos = "0,0",  parent = dlg }
	local root     = { class = "flattabs", pos = "0,60", screen = "208,291", parent = box }
	local page1    = { class = "vbox",   pos = "1,27", parent = root }
	local substrip = { class = "flattabs", pos = "1,27", screen = "209,318", parent = root }
	local subpage  = { class = "vbox",   pos = "1,27", parent = substrip }
	return { dlg = dlg, box = box, root = root,
	         page1 = page1, substrip = substrip, subpage = subpage }
end

describe("MotionOverlay.anchorOffset", function()
	it("anchors a page on the nearest ancestor that owns a window", function()
		local t = tree()
		local anchor, kind, ax, ay = MotionOverlay.anchorOffset(fake_iup(), t.subpage)
		assert.are.equal(t.substrip, anchor)
		assert.are.equal("screen", kind)
		assert.are.equal(1, ax)
		assert.are.equal(27, ay)
	end)

	it("does not place a nested page where a root page sits", function()
		-- The bug in one assertion: both report POSITION 1,27, and the old code
		-- added that to the dialog origin for each, collapsing them onto the same
		-- rectangle.
		local t = fake_iup()
		local w = tree()
		local a1, _, x1, y1 = MotionOverlay.anchorOffset(t, w.page1)
		local a2, _, x2, y2 = MotionOverlay.anchorOffset(t, w.subpage)
		assert.are_not.equal(a1, a2)
		-- Same local offset, but measured from different anchors -- which is the
		-- whole point.
		assert.are.equal(x1, x2)
		assert.are.equal(y1, y2)
	end)

	it("accumulates through window-less ancestors", function()
		-- A page wrapped in a scroll host wrapped in a box (which is what
		-- HostAPI:addTab actually builds) must sum every step, not just the last.
		local w = tree()
		local mid  = { class = "vbox", pos = "3,5",  parent = w.substrip }
		local leaf = { class = "vbox", pos = "7,11", parent = mid }
		local anchor, kind, ax, ay = MotionOverlay.anchorOffset(fake_iup(), leaf)
		assert.are.equal(w.substrip, anchor)
		assert.are.equal("screen", kind)
		assert.are.equal(10, ax)
		assert.are.equal(16, ay)
	end)

	it("anchors on the dialog when nothing between owns a window", function()
		-- Reported as "dialog" rather than "screen" because a dialog's
		-- SCREENPOSITION is its OUTER window -- title bar and border included --
		-- so the caller has to ask for the client origin instead.
		local w = tree()
		local anchor, kind, ax, ay = MotionOverlay.anchorOffset(fake_iup(), w.box)
		assert.are.equal(w.dlg, anchor)
		assert.are.equal("dialog", kind)
		assert.are.equal(0, ax)
		assert.are.equal(0, ay)
	end)

	it("gives up rather than hanging on a cyclic tree", function()
		-- A malformed tree would otherwise spin inside a repaint, on the UI thread.
		local a = { class = "vbox", pos = "1,1" }
		local b = { class = "vbox", pos = "1,1", parent = a }
		a.parent = b
		assert.is_nil(MotionOverlay.anchorOffset(fake_iup(), b))
	end)

	it("returns nil for a widget with no parent", function()
		assert.is_nil(MotionOverlay.anchorOffset(fake_iup(),
			{ class = "vbox", pos = "0,0" }))
	end)
end)

describe("MotionOverlay.screenPos", function()
	it("reads a widget that owns a window", function()
		local x, y = MotionOverlay.screenPos(fake_iup(), tree().root)
		assert.are.equal(208, x)
		assert.are.equal(291, y)
	end)

	it("reports nil for a layout-only container", function()
		-- The condition the whole fallback exists for.
		assert.is_nil(MotionOverlay.screenPos(fake_iup(), tree().subpage))
	end)

	it("handles negative coordinates", function()
		-- A maximised window sits at -8,-8 on Windows 10/11, so this is the
		-- ordinary case rather than an edge case.
		local w = { class = "flattabs", pos = "0,0", screen = "-8,-8" }
		local x, y = MotionOverlay.screenPos(fake_iup(), w)
		assert.are.equal(-8, x)
		assert.are.equal(-8, y)
	end)
end)
