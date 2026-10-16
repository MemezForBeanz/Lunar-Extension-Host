--- Specs for `core.lib.SplitMotion`.
--
-- The module is deliberately small, and these specs pin the two decisions in it:
--
--   * `LAYOUTDRAG=NO` is set. This is the fix. IUP's default runs
--     `IupRefreshChildren` AND `IupFlush` on every mouse-move sample
--     (`iup_split.c`, `iSplitMotion_CB`), and the flush -- draining the message
--     queue from inside a mouse handler, so children repaint one at a time as
--     they move -- is what caused the tearing.
--   * The relayout runs on EVERY sample, so the panes track the divider
--     continuously. An earlier version throttled it to ~30 fps and the panes
--     visibly jumped to catch up with the bar; these specs exist partly so that
--     cannot come back unnoticed.
--
-- The relayout must also stay scoped: `IupRefresh` lays out the whole dialog
-- whatever widget it is handed, which on a drag would be enormous.

local SplitMotion = require("core.lib.SplitMotion")

local function fake_split()
	return { attrs = {} }
end

local function fake_iup()
	local iup = { DEFAULT = 0, refreshes = 0, child_refreshes = 0, flushes = 0 }
	function iup.SetAttribute(w, name, value) w.attrs[name] = value end
	function iup.GetAttribute(w, name) return w.attrs[name] end
	function iup.Refresh() iup.refreshes = iup.refreshes + 1 end
	function iup.RefreshChildren() iup.child_refreshes = iup.child_refreshes + 1 end
	function iup.Flush() iup.flushes = iup.flushes + 1 end
	return iup
end

local function attach(opts)
	local split, iup = fake_split(), fake_iup()
	SplitMotion.attach(iup, split, opts)
	return split, iup
end

describe("SplitMotion", function()
	it("disables IUP's per-sample relayout and flush", function()
		local split = select(1, attach())
		assert.are.equal("NO", split.attrs.LAYOUTDRAG)
	end)

	it("relayouts on every drag sample", function()
		-- Not throttled, deliberately. Rationing this makes the panes jump to
		-- catch up with a divider bar that has already moved, which is a worse
		-- artefact than the tearing it was meant to avoid.
		local split, iup = attach()
		for _ = 1, 25 do split:valuechanged_cb() end
		assert.are.equal(25, iup.child_refreshes)
	end)

	it("never lays out the whole dialog", function()
		-- IupRefresh would relayout the entire application per mouse sample.
		local split, iup = attach()
		for _ = 1, 25 do split:valuechanged_cb() end
		assert.are.equal(0, iup.refreshes)
	end)

	it("never flushes the message queue", function()
		-- The actual cause of the tearing. Nothing in this module may reintroduce
		-- a synchronous pump on the drag path.
		local split, iup = attach()
		for _ = 1, 25 do split:valuechanged_cb() end
		assert.are.equal(0, iup.flushes)
	end)

	it("notifies an on_change hook after each relayout", function()
		local seen = 0
		local split = select(1, attach({ on_change = function() seen = seen + 1 end }))
		split:valuechanged_cb()
		split:valuechanged_cb()
		assert.are.equal(2, seen)
	end)

	it("survives a throwing on_change hook", function()
		-- The hook belongs to the caller; a fault in it must not break dragging.
		local split = select(1, attach({ on_change = function() error("boom") end }))
		assert.has_no.errors(function() split:valuechanged_cb() end)
	end)
end)
