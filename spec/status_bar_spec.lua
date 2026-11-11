-- core.ui.StatusBar through its public API, on the ImGui host's Null backend: the tree it
-- builds, the logo rules, activity, pane state, reveal, extension elements and the fade.
local T = require("core.lui.test")
local StatusBar = require("core.ui.StatusBar")

local ICONS = (os.getenv("LUNAR_REPO") or ".") .. "/assets/Icons"

local iup, Runtime, Element
local function bar(opts)
	opts = opts or {}
	opts.iup, opts.icon_dir = iup, ICONS
	return StatusBar.new(opts)
end

-- Show the bar in a dialog wide enough for the logo, and lay it out.
local function show(sb, w)
	local dlg = iup.dialog({ iup.vbox({ sb:widget() }), RASTERSIZE = (w or 1400) .. "x200" })
	iup.Show(dlg)
	Runtime.frame()
	return dlg
end

local function own(h, name) return Element.own(h, name) end

-- Count Refresh/Update calls by target while fn runs.
local function spy(fn)
	local log = { refresh = {}, update = {} }
	local r, u = iup.Refresh, iup.Update
	iup.Refresh = function(h) log.refresh[#log.refresh + 1] = h; return r(h) end
	iup.Update = function(h) log.update[#log.update + 1] = h; return u(h) end
	local ok, err = pcall(fn)
	iup.Refresh, iup.Update = r, u
	assert(ok, err)
	return log
end

local function image(name, w)
	iup.SetHandle(name, iup.imagergba({ width = w, height = 18, pixels = {} }))
	return name
end

before_each(function()
	iup, Runtime, _, Element = T.boot({})
end)

describe("StatusBar tree", function()
	it("builds the bar the shell lays out and the theme manager styles", function()
		local sb = bar({ has_logo = true, logo_tip = "Org" })
		local w = sb:widget()
		assert.equal("hbox", iup.GetClassName(w))
		assert.equal("statusbar", own(w, "THEMEROLE"))
		assert.equal("YES", own(w, "HOMOGENEOUS"))
		assert.equal("240 240 240", own(w, "BGCOLOR"))
		assert.equal("0x0", own(w, "MARGIN"))
		assert.equal("0", own(w, "GAP"))
		assert.equal("HORIZONTAL", own(w, "EXPAND"))
		assert.equal(3, iup.GetChildCount(w))
		local left, mid, right = iup.GetChild(w, 0), iup.GetChild(w, 1), iup.GetChild(w, 2)
		-- left: settings, activity box (hidden), status label
		assert.equal(sb:activityAnchor(), iup.GetChild(left, 0))
		assert.equal("48x28", own(sb:activityAnchor(), "RASTERSIZE"))
		assert.equal("statusbar_button", own(sb:activityAnchor(), "THEMEROLE"))
		local activity = iup.GetChild(left, 1)
		assert.equal("YES", own(activity, "FLOATING"))
		assert.equal("NO", own(activity, "VISIBLE"))
		local label = iup.GetChild(left, 2)
		assert.equal("label", iup.GetClassName(label))
		assert.equal("statusbar_text", own(label, "THEMEROLE"))
		assert.equal("60 60 60", own(label, "FGCOLOR"))
		assert.equal("YES", own(label, "ELLIPSIS"))
		-- middle: fill, the command field, fill
		assert.equal("fill", iup.GetClassName(iup.GetChild(mid, 0)))
		assert.equal(sb:commandWidget(), iup.GetChild(mid, 1))
		assert.equal("320x24", own(sb:commandWidget(), "RASTERSIZE"))
		assert.equal("commandbar", own(sb:commandWidget(), "THEMEROLE"))
		local field_box = iup.GetChild(sb:commandWidget(), 0)
		assert.equal("Search or run a command", own(iup.GetChild(field_box, 0), "TITLE"))
		assert.equal("Ctrl+P", own(iup.GetChild(field_box, 1), "TITLE"))
		-- right: fill, logo box, extension box, focus button
		assert.equal("8x0", own(right, "MARGIN"))
		assert.equal(4, iup.GetChildCount(right))
		local logo_box = iup.GetChild(right, 1)
		assert.equal("NO", own(logo_box, "VISIBLE"))
		assert.equal("Org", own(iup.GetChild(logo_box, 0), "TIP"))
		assert.equal(sb:extBox(), iup.GetChild(right, 2))
		local focus = iup.GetChild(right, 3)
		assert.equal("NO", own(focus, "ACTIVE"))
		assert.equal("32x28", own(focus, "RASTERSIZE"))
	end)

	it("has no logo box without a logo", function()
		local sb = bar()
		local right = iup.GetChild(sb:widget(), 2)
		assert.equal(3, iup.GetChildCount(right))
		assert.equal(sb:extBox(), iup.GetChild(right, 1))
	end)

	it("binds the three icons to their buttons", function()
		local bound = {}
		local sb = bar({ bind_icon = function(widget, name) bound[name] = widget end })
		assert.equal(sb:activityAnchor(), bound.settings)
		assert.equal(iup.GetChild(iup.GetChild(sb:commandWidget(), 0), 0), bound.search)
		assert.equal(iup.GetChild(iup.GetChild(sb:widget(), 2), 2), bound.view)
	end)
end)

describe("StatusBar logo", function()
	it("hides below 1000px, hides absent variants, and only relayouts changed sizes", function()
		local sb = bar({ has_logo = true })
		local dlg = show(sb)
		local logo_box = iup.GetChild(iup.GetChild(sb:widget(), 2), 1)
		local logo = iup.GetChild(logo_box, 0)
		sb:fit(1000)
		local log = spy(function() sb:setLogo(image("light", 60)) end)
		assert.equal("YES", own(logo_box, "VISIBLE"))
		assert.equal("light", own(logo, "IMAGE"))
		assert.same({ logo_box }, log.refresh)
		log = spy(function() sb:setLogo(image("dark", 60)) end)
		assert.same({}, log.refresh, "same size: a repaint only")
		assert.same({ logo }, log.update)
		assert.equal("dark", own(logo, "IMAGE"))
		log = spy(function() sb:setLogo(image("wide", 90)) end)
		assert.same({ logo_box }, log.refresh)
		sb:fit(999)
		assert.equal("NO", own(logo_box, "VISIBLE"))
		assert.equal("YES", own(logo_box, "FLOATING"))
		sb:fit(1000)
		assert.equal("YES", own(logo_box, "VISIBLE"))
		sb:setLogo(nil)
		assert.equal("NO", own(logo_box, "VISIBLE"))
		assert.equal("wide", own(logo, "IMAGE"), "a hidden logo keeps its image")
		iup.Destroy(dlg)
	end)
end)

describe("StatusBar fit, pane state and settings", function()
	it("sizes the command field and activity text to the window", function()
		local sb = bar()
		sb:fit(1500)
		assert.equal("480x24", own(sb:commandWidget(), "RASTERSIZE"))
		sb:fit(900)
		assert.equal("284x24", own(sb:commandWidget(), "RASTERSIZE"))
		sb:fit(300)
		assert.equal("160x24", own(sb:commandWidget(), "RASTERSIZE"))
		local text = iup.GetChild(iup.GetChild(iup.GetChild(sb:widget(), 0), 1), 1)
		assert.equal("80x", own(text, "RASTERSIZE"))
		sb:fit(1200)
		assert.equal("220x", own(text, "RASTERSIZE"))
	end)

	it("enables the focus button while split and words its tip by focus", function()
		local sb = bar()
		local focus = iup.GetChild(iup.GetChild(sb:widget(), 2), 2)
		sb:setPaneState(true, false)
		assert.equal("YES", own(focus, "ACTIVE"))
		assert.equal("Focus active pane", own(focus, "TIP"))
		sb:setPaneState(true, true)
		assert.equal("Restore split (Esc)", own(focus, "TIP"))
		sb:setPaneState(false, false)
		assert.equal("NO", own(focus, "ACTIVE"))
	end)

	it("shows the gear pressed with the theme's colours", function()
		local sb = bar()
		sb:setSettingsActive(true, { bg = "1 1 1", pressed = "2 2 2" })
		assert.equal("2 2 2", own(sb:activityAnchor(), "BGCOLOR"))
		-- written every time, even when a theme pass changed it in between
		iup.SetAttribute(sb:activityAnchor(), "BGCOLOR", "9 9 9")
		sb:setSettingsActive(true, { bg = "1 1 1", pressed = "2 2 2" })
		assert.equal("2 2 2", own(sb:activityAnchor(), "BGCOLOR"))
		sb:setSettingsActive(false, { bg = "1 1 1", pressed = "2 2 2" })
		assert.equal("1 1 1", own(sb:activityAnchor(), "BGCOLOR"))
	end)

	it("calls the handlers when its buttons are clicked", function()
		local sb = bar()
		local dlg = show(sb)
		local calls = {}
		sb:onSettings(function() calls[#calls + 1] = "settings" end)
		sb:onCommand(function() calls[#calls + 1] = "command" end)
		sb:onFocus(function() calls[#calls + 1] = "focus" end)
		sb:onActivity(function() calls[#calls + 1] = "activity" end)
		local field_box = iup.GetChild(sb:commandWidget(), 0)
		local focus = iup.GetChild(iup.GetChild(sb:widget(), 2), 2)
		local activity = iup.GetChild(iup.GetChild(sb:widget(), 0), 1)
		assert.equal(iup.DEFAULT, Element.call(sb:activityAnchor(), "FLAT_ACTION"))
		Element.call(iup.GetChild(field_box, 0), "FLAT_ACTION")
		Element.call(iup.GetChild(field_box, 1), "FLAT_ACTION")
		Element.call(focus, "FLAT_ACTION")
		Element.call(iup.GetChild(activity, 1), "FLAT_ACTION")
		Element.call(iup.GetChild(activity, 0), "BUTTON_CB", iup.BUTTON1, 0, 0, 0, "")
		assert.same({ "settings", "command", "command", "focus", "activity", "activity" }, calls)
		iup.Destroy(dlg)
	end)
end)

describe("StatusBar activity", function()
	it("shows work, escapes mnemonics, and hides again with one relayout each way", function()
		local sb = bar()
		local dlg = show(sb)
		local box = iup.GetChild(iup.GetChild(sb:widget(), 0), 1)
		local text = iup.GetChild(box, 1)
		local log = spy(function() sb:setActivity({ state = "running", text = "Build & test", tip = "2 jobs" }) end)
		assert.equal("NO", own(box, "FLOATING"))
		assert.equal("YES", own(box, "VISIBLE"))
		assert.equal("Build && test", own(text, "TITLE"))
		assert.equal("2 jobs", own(text, "TIP"))
		assert.same({ box }, log.refresh)
		log = spy(function() sb:setActivity({ state = "running", text = "Build 50%", tip = "2 jobs" }) end)
		assert.same({}, log.refresh, "text ticking over does not relayout")
		assert.equal("Build 50%", own(text, "TITLE"))
		log = spy(function() sb:setActivity(nil) end)
		assert.equal("YES", own(box, "FLOATING"))
		assert.equal("NO", own(box, "VISIBLE"))
		assert.equal("Build 50%", own(text, "TITLE"), "hidden, the last text stays")
		assert.same({ box }, log.refresh)
		iup.Destroy(dlg)
	end)
end)

describe("StatusBar reveal and extension elements", function()
	it("occupies a fraction of its height and reports it", function()
		local sb = bar()
		assert.is_nil(sb:revealedHeight())
		sb:setReveal(0.5)
		local w = sb:widget()
		assert.equal(14, sb:revealedHeight())
		assert.equal("1x14", own(w, "MINSIZE"))
		assert.equal("65535x14", own(w, "MAXSIZE"))
		assert.equal("NO", own(w, "FLOATING"))
		sb:setReveal(0)
		assert.equal(0, sb:revealedHeight())
		assert.equal("YES", own(w, "FLOATING"))
		assert.equal("NO", own(w, "VISIBLE"))
		sb:setReveal(1)
		assert.equal("YES", own(w, "VISIBLE"))
		assert.equal("65535x28", own(w, "MAXSIZE"))
	end)

	it("never disturbs the elements extensions put in its box", function()
		local sb = bar({ has_logo = true })
		local dlg = show(sb)
		local mine = iup.flatlabel({ TITLE = "ext" })
		iup.Append(sb:extBox(), mine)
		sb:fit(1200)
		sb:setReveal(0.5)
		sb:setReveal(1)
		sb:setStatus("busy")
		sb:setPaneState(true, true)
		assert.equal(sb:extBox(), iup.GetParent(mine))
		assert.equal(1, iup.GetChildCount(sb:extBox()))
		iup.Destroy(dlg)
	end)
end)

-- A motion director that runs frames only when told to, so a fade can be interrupted.
local function director()
	local running = {}
	local motion = {
		animate = function(_, spec)
			-- Supersede whatever ran on this target, as MotionDirector does.
			for _, r in ipairs(running) do
				if not r.done then r.done = true; r.spec.on_done(false) end
			end
			running[#running + 1] = { spec = spec }
		end,
	}
	local function frame(v)
		local r = running[#running]
		r.spec.on_frame(v)
		if v >= 1 then r.done = true; r.spec.on_done(true) end
	end
	return motion, frame
end

local function status_label(sb) return iup.GetChild(iup.GetChild(sb:widget(), 0), 2) end

describe("StatusBar.setStatus", function()
	it("fades the text in from the bar colour to its resting colour", function()
		local sb = bar()
		local motion, frame = director()
		sb:setMotion(motion)
		local label = status_label(sb)
		sb:setStatus("Building")
		assert.are.equal("Building", own(label, "TITLE"))
		frame(0)
		assert.are.equal("240 240 240", own(label, "FGCOLOR"))
		frame(1)
		assert.are.equal("60 60 60", own(label, "FGCOLOR"))
	end)

	it("keeps the resting colour when a fade is interrupted", function()
		local sb = bar()
		local motion, frame = director()
		sb:setMotion(motion)
		local label = status_label(sb)
		sb:setStatus("one")
		frame(0.5)                     -- mid-fade: FGCOLOR is an in-between colour
		sb:setStatus("two")
		frame(1)
		assert.are.equal("60 60 60", own(label, "FGCOLOR"))
		sb:setStatus("three")          -- and the next fade starts from the right place
		frame(1)
		assert.are.equal("60 60 60", own(label, "FGCOLOR"))
		assert.are.equal("three", own(label, "TITLE"))
	end)

	it("fades again for a repeated message", function()
		local sb = bar()
		local n = 0
		sb:setMotion({ animate = function(_, spec) n = n + 1; spec.on_done(true) end })
		sb:setStatus("same")
		sb:setStatus("same")
		assert.equal(2, n)
	end)

	it("just sets the text when there is no director", function()
		local sb = bar()
		local label = status_label(sb)
		sb:setStatus("Ready")
		assert.are.equal("Ready", own(label, "TITLE"))
		assert.are.equal("60 60 60", own(label, "FGCOLOR"))
	end)

	it("goes quiet once its label is gone", function()
		local sb = bar()
		iup.Destroy(sb:widget())
		assert.has_no.errors(function() sb:setStatus("after") end)
		assert.has_no.errors(function() sb:setStatus("again") end)
	end)
end)
