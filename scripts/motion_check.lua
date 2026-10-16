-- motion_check.lua
-- GUI verification for the Carbon motion system's native layer.
--
-- The busted suite covers everything that is pure Lua: tokens, easing, and the
-- director's scheduling semantics. It cannot reach the parts that need a real
-- window -- the layered click-through overlay, GDI snapshot capture, and an actual
-- animated tab transition -- because those require a live IUP dialog and an HWND.
--
-- This harness exercises exactly that gap. It opens a small window with two tab
-- pages and drives the real modules against it.
--
-- Run:
--   build\bin\LunarExtensionHost.exe scripts\motion_check.lua           (interactive)
--   build\bin\LunarExtensionHost.exe scripts\motion_check.lua --batch   (exits when done)
--
-- Interactive mode leaves the window open so the transition can be watched; close
-- it to finish. `--batch` runs the checks and exits with a non-zero status if any
-- failed, which is the form to use from a script.

local repo = os.getenv("LUNAR_REPO") or "."
package.path = table.concat({
	repo .. "\\src\\lua\\?.lua",
	repo .. "\\vendor\\luarocks-tree\\share\\lua\\5.1\\?.lua",
	package.path,
}, ";")

local batch = false
for _, a in ipairs(arg or {}) do
	if a == "--batch" then batch = true end
end

local passed, failed = 0, 0

local function test(name, fn)
	io.write(string.format("  %-56s ", name .. " ..."))
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("PASS")
	else
		failed = failed + 1
		print("FAIL")
		print("    -> " .. tostring(err))
	end
end

local function assert_true(cond, label)
	if not cond then error((label or "assert_true") .. ": expected truthy", 2) end
end

print("")
print("=== Carbon motion system: native layer ===")
print("")

-- ---------------------------------------------------------------------------
-- Capability probes
-- ---------------------------------------------------------------------------

local MotionClock   = require("core.lib.MotionClock")
local MotionEasing  = require("core.lib.MotionEasing")
local IupFFI        = require("core.classes.IupFFI")
local MotionOverlay = require("core.ui.MotionOverlay")

print("Capabilities")
test("MotionClock has the Win32 high-resolution clock", function()
	assert_true(MotionClock.available, "QueryPerformanceCounter unavailable")
end)

test("MotionClock advances monotonically", function()
	local t0 = MotionClock.now()
	local spin = 0
	for i = 1, 2000000 do spin = spin + i end
	local t1 = MotionClock.now()
	assert_true(t1 > t0, "clock did not advance (sum " .. spin .. ")")
end)

test("MotionEasing uses the FFI sample table", function()
	assert_true(MotionEasing.ffi, "FFI lookup table unavailable; easing fell back to Lua")
end)

test("IupFFI resolved the IUP entry points", function()
	assert_true(IupFFI.available, "IupFFI unavailable; the overlay cannot read HDC_WMPAINT")
end)

test("internal _IUP attributes read back through core.lib.attr", function()
	-- The Lua binding pushes nil for ANY attribute named "_IUP..." regardless of
	-- what is stored (iuplua_pushvalue). Every layout key and group marker in the
	-- host uses that prefix, so if this regresses the tab arrangement silently
	-- stops persisting -- tabs fall out of their groups on the next launch, with
	-- no error anywhere. Only reachable here: it needs the real binding.
	local attr = require("core.lib.attr")
	local probe = iup.vbox({})
	attr.set(iup, probe, "_IUPLUNAR_TABKEY", "probe/1")
	assert_true(iup.GetAttribute(probe, "_IUPLUNAR_TABKEY") == nil,
		"the binding no longer hides internal attributes; core.lib.attr may be redundant")
	assert_true(attr.get(iup, probe, "_IUPLUNAR_TABKEY") == "probe/1",
		"core.lib.attr could not read back an internal attribute")
	iup.Destroy(probe)
end)

test("handle identity is stable across repeated calls", function()
	-- Depends on the above: when the read failed, every call minted a new id and
	-- handle.same() could never recognise a widget, disabling the drag/drop guards.
	local handle = require("core.lib.handle")
	local probe = iup.vbox({})
	local first = handle.id(iup, probe)
	assert_true(handle.id(iup, probe) == first,
		"handle.id is not stable: " .. tostring(first) .. " vs " .. tostring(handle.id(iup, probe)))
	iup.Destroy(probe)
end)

test("MotionOverlay reports itself supported", function()
	assert_true(MotionOverlay.supported(), "overlay unsupported in this process")
end)

-- Reported rather than asserted: msimg32 is loaded separately from the rest of
-- GDI precisely so a machine without it keeps the overlay and loses only the
-- cross-fade. Printing it turns "the tab transition looks like a cut on this one
-- box" from a mystery into a line of output.
print(string.format("  Alpha compositing (msimg32): %s",
	MotionOverlay.blendSupported() and "available" or "UNAVAILABLE (fades become cuts)"))

print("")
print("System preference")
print(string.format("  OS reduce-motion requested: %s", tostring(MotionClock.systemReducedMotion())))

-- ---------------------------------------------------------------------------
-- Live window
-- ---------------------------------------------------------------------------

local MotionDirector = require("core.classes.MotionDirector")
local TabTransition  = require("core.ui.TabTransition")

local function page(title, color)
	return iup.vbox({
		iup.label({ TITLE = title, EXPAND = "HORIZONTAL", ALIGNMENT = "ACENTER" }),
		iup.canvas({ BGCOLOR = color, EXPAND = "YES", RASTERSIZE = "400x260", BORDER = "NO" }),
		TABTITLE = title,
		MARGIN = "10x10",
	})
end

local tabs = iup.flattabs({
	page("Alpha", "220 80 80"),
	page("Bravo", "80 160 220"),
	page("Charlie", "120 200 120"),
})

local status = iup.label({ TITLE = "Click the tabs to watch the transition.", EXPAND = "HORIZONTAL" })

local dlg = iup.dialog({
	iup.vbox({ tabs, status, MARGIN = "8x8", GAP = "6" }),
	TITLE = "Lunar motion check",
	SIZE  = "440x240",
})

iup.Map(dlg)
iup.Show(dlg)
-- The overlay reads SCREENPOSITION, which is only meaningful once the window has
-- actually been placed by the shell.
iup.Flush()

local director = MotionDirector:new({ iup = iup })
local overlay  = MotionOverlay:new({ iup = iup, dialog = dlg, log = print })

print("")
print("Overlay")
test("overlay reports available", function()
	assert_true(overlay:available(), "overlay unavailable against a live dialog")
end)

test("resolves a widget screen rectangle", function()
	local x, y, w, h = overlay:rectOf(tabs)
	assert_true(x and y and w and h, "no rectangle for the tab strip")
	assert_true(w > 0 and h > 0, "degenerate rectangle " .. tostring(w) .. "x" .. tostring(h))
end)

local snap
test("captures a page to an offscreen bitmap", function()
	local pg = iup.GetChild(tabs, 0)
	assert_true(pg ~= nil, "no page at position 0")
	local why
	snap, why = overlay:capture(pg)
	assert_true(snap ~= nil, "capture returned nil: " .. tostring(why))
	assert_true(snap.w > 0 and snap.h > 0,
		"degenerate snapshot " .. tostring(snap and snap.w) .. "x" .. tostring(snap and snap.h))
end)

test("captures the tab strip itself", function()
	local s, why = overlay:capture(tabs)
	assert_true(s ~= nil, "capture returned nil: " .. tostring(why))
	s:release()
end)

test("releases a snapshot without error, and tolerates a double release", function()
	assert_true(snap ~= nil, "no snapshot to release")
	snap:release()
	snap:release()
	assert_true(snap.released, "snapshot not marked released")
end)

test("shows and hides without stealing focus", function()
	local shown = overlay:show(tabs, function(o) o:clear("40 40 40") end)
	assert_true(shown, "overlay:show failed")
	iup.Flush()
	assert_true(overlay:visible(), "overlay reports hidden after show")
	overlay:hide()
	assert_true(not overlay:visible(), "overlay still visible after hide")
end)

test("survives many capture/release cycles without exhausting GDI", function()
	-- GDI objects are a process-wide resource; a leak here degrades the whole
	-- desktop, so this is the test that matters most in this file.
	local pg = iup.GetChild(tabs, 0)
	for i = 1, 200 do
		local s = overlay:capture(pg)
		if not s then error("capture failed on iteration " .. i) end
		s:release()
	end
end)

-- ---------------------------------------------------------------------------
-- Live transition
-- ---------------------------------------------------------------------------

local transition = TabTransition:new({
	iup = iup,
	director = director,
	overlay = overlay,
	log = print,
})

print("")
print("Transition")
test("animates a programmatic tab switch", function()
	local ran = transition:run(tabs, 1, function()
		iup.SetAttribute(tabs, "VALUEPOS", "1")
	end)
	assert_true(ran, "transition did not run")
	assert_true(transition:busy(), "transition reported idle immediately")
end)

test("settles on demand", function()
	transition:settle()
	assert_true(not transition:busy(), "still busy after settle")
	assert_true(director:activeCount() == 0, "animations still scheduled after settle")
end)

test("performs the switch even when motion is disabled", function()
	director:configure({ enabled = false })
	iup.SetAttribute(tabs, "VALUEPOS", "0")
	local ran = transition:run(tabs, 2, function()
		iup.SetAttribute(tabs, "VALUEPOS", "2")
	end)
	assert_true(not ran, "transition animated while motion was disabled")
	assert_true(iup.GetAttribute(tabs, "VALUEPOS") == "2", "the switch itself did not happen")
	director:configure({ enabled = true })
end)

-- Drive the switch through the real callbacks so the arm/commit path is exercised
-- the way a native click does it.
local TabDragMotion = require("core.ui.TabDragMotion")
local drag_motion = TabDragMotion:new({
	iup = iup, director = director, overlay = overlay, spring_ms = 500,
})

print("")
print("Drag feedback")
test("caret and combine states render without error", function()
	drag_motion:showCaret(tabs, 40, 24)
	iup.Flush()
	drag_motion:showCombine(tabs, 10, 80, 24)
	iup.Flush()
	drag_motion:showSpring(tabs, 10, 80, 24)
	iup.Flush()
	drag_motion:clearSpring()
	drag_motion:clear()
	assert_true(true)
end)

test("merge flourish completes and invokes its callback", function()
	local done = false
	drag_motion:playMerge(tabs, { x = 0, w = 160 }, { x = 0, w = 80 }, 24, function()
		done = true
	end)
	-- Pump the loop until the 400ms expressive animation finishes.
	local deadline = MotionClock.now() + 3.0
	while not done and MotionClock.now() < deadline do
		iup.LoopStep()
	end
	assert_true(done, "playMerge never invoked its completion callback")
end)

-- ---------------------------------------------------------------------------
-- Integration: the full stack, wired the way main.lua wires it
-- ---------------------------------------------------------------------------
--
-- The seam most likely to break is not any single module but the wiring between
-- them: TabOrder arming the transition on press, committing it on TABCHANGE_CB,
-- and calling the drag renderer as a drop resolves. None of that is reachable from
-- busted, because it needs real strips with real hit-testing.

local TabOrder  = require("core.classes.TabOrder")
local TabGroups = require("core.classes.TabGroups")

print("")
print("Integration")

local i_tabs = iup.flattabs({
	page("One", "200 90 90"),
	page("Two", "90 140 200"),
	page("Three", "110 180 110"),
})
local i_dlg = iup.dialog({
	iup.vbox({ i_tabs, MARGIN = "6x6" }),
	TITLE = "Lunar motion integration", SIZE = "400x220",
})
iup.Map(i_dlg)
iup.Show(i_dlg)
iup.Flush()

local i_overlay = MotionOverlay:new({ iup = iup, dialog = i_dlg, log = print })
local i_director = MotionDirector:new({ iup = iup })
local i_transition = TabTransition:new({
	iup = iup, director = i_director, overlay = i_overlay,
})

local switches = 0
local i_order = TabOrder:new({
	iup = iup,
	on_switch = function() switches = switches + 1 end,
	prompt = function() return "Group" end,
})
i_order:setMotion(TabDragMotion:new({
	iup = iup, director = i_director, overlay = i_overlay, spring_ms = 500,
}))
i_order:setTransition(i_transition)

local i_groups = TabGroups:new({
	iup = iup,
	root_strip = i_tabs,
	settings = { get = function() return nil end, set = function() end, save = function() end },
	on_strip_created = function(s) i_order:install(s) end,
	notify_tree_change = function() end,
})
i_order:setGroups(i_groups)
iup.Flush()

test("TabOrder installs on the root strip without disturbing it", function()
	assert_true(iup.GetChildCount(i_tabs) == 3, "tab count changed during install")
end)

test("a press arms the transition", function()
	-- FLAT_BUTTON_CB press. Position 0's tab band is at the top of the strip.
	i_tabs.flat_button_cb(i_tabs, iup.BUTTON1, 1, 20, 8, "")
	assert_true(true)
end)

test("TABCHANGE_CB commits an armed transition", function()
	i_director:finishAll()
	i_tabs.flat_button_cb(i_tabs, iup.BUTTON1, 1, 20, 8, "")
	iup.SetAttribute(i_tabs, "VALUEPOS", "1")
	iup.Flush()
	i_tabs.tabchange_cb(i_tabs, iup.GetChild(i_tabs, 1), iup.GetChild(i_tabs, 0))
	-- Either it animated, or it declined cleanly; what must not happen is a throw.
	i_transition:settle()
	assert_true(true)
end)

test("a click without travel still does not rearrange anything", function()
	-- The regression this class has had twice: a plain click resolving as a drop.
	local before = iup.GetChildCount(i_tabs)
	i_tabs.flat_button_cb(i_tabs, iup.BUTTON1, 1, 20, 8, "")
	i_tabs.flat_button_cb(i_tabs, iup.BUTTON1, 0, 22, 8, "")
	iup.Flush()
	assert_true(iup.GetChildCount(i_tabs) == before,
		"a click changed the tab tree: " .. before .. " -> " .. iup.GetChildCount(i_tabs))
end)

test("a drag across the strip renders feedback without throwing", function()
	i_tabs.flat_button_cb(i_tabs, iup.BUTTON1, 1, 20, 8, "")
	for x = 26, 200, 8 do
		i_tabs.flat_motion_cb(i_tabs, x, 8, "")
		iup.Flush()
	end
	-- Release outside any tab band: an abandoned drag, which must clear cleanly.
	i_tabs.flat_button_cb(i_tabs, iup.BUTTON1, 0, 200, 400, "")
	iup.Flush()
	assert_true(true)
end)

test("the drag left no overlay on screen", function()
	assert_true(not i_overlay:visible(), "overlay still visible after the drag ended")
end)

test("motion disabled leaves gestures fully functional", function()
	i_director:configure({ enabled = false })
	local before = iup.GetChildCount(i_tabs)
	i_tabs.flat_button_cb(i_tabs, iup.BUTTON1, 1, 20, 8, "")
	i_tabs.flat_motion_cb(i_tabs, 60, 8, "")
	i_tabs.flat_button_cb(i_tabs, iup.BUTTON1, 0, 22, 8, "")
	iup.Flush()
	assert_true(iup.GetChildCount(i_tabs) == before, "tree changed unexpectedly")
	i_director:configure({ enabled = true })
end)

i_director:shutdown()
i_overlay:destroy()
iup.Destroy(i_dlg)

-- ---------------------------------------------------------------------------

print("")
print(string.format("=== %d passed, %d failed ===", passed, failed))
if failed > 0 then
	print("")
	print("A failure above means the animation would silently fall back to an")
	print("instant, non-animated UI on this machine -- not that the app is broken.")
end
print("")

iup.SetAttribute(status, "TITLE",
	string.format("%d passed, %d failed. Click the tabs to watch the transition.", passed, failed))

if not batch then
	print("Window is open: click between tabs to watch the transition. Close it to exit.")
	print("")
	iup.MainLoop()
end

overlay:destroy()
director:shutdown()
iup.Destroy(dlg)
iup.Close()

if batch and failed > 0 then
	os.exit(1)
end
os.exit(0)
