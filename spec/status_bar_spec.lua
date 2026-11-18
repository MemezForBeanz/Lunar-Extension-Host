-- core.ui.StatusBar through its public API, on the ImGui host's Null backend: the tree it
-- builds, the logo rules, activity, pane state, reveal, extension elements and the fade.
local T = require("core.lui.test")
local StatusBar = require("core.ui.StatusBar")

local ICONS = (os.getenv("LUNAR_REPO") or ".") .. "/assets/Icons"

local iup, Element
local function bar(opts)
	opts = opts or {}
	opts.iup, opts.icon_dir = iup, ICONS
	return StatusBar.new(opts)
end

local function own(h, name) return Element.own(h, name) end

before_each(function()
	local i, _, _, e = T.boot({})
	iup, Element = i, e
end)

describe("StatusBar shell", function()
 it("has a 24px bar with status left and activity, update and settings right",function()
  local sb=bar();assert.equal(24,StatusBar.HEIGHT)
  assert.equal(2,iup.GetChildCount(sb:widget()))
  assert.is_nil(sb:commandWidget())
  local right=iup.GetChild(sb:widget(),1)
  assert.equal(sb:extBox(),iup.GetChild(right,1))
  sb:setReveal(0.5);assert.equal(12,sb:revealedHeight())
 end)
 it("keeps tool messages isolated and expires them after eight seconds",function()
  local sb=bar();sb:showTool("build",100)
  sb:postStatus("clock","Clocked in",100)
  assert.equal("",own(sb._label,"TITLE"))
  sb:showTool("clock",101);assert.equal("Clocked in",own(sb._label,"TITLE"))
  sb:showTool("clock",108);assert.equal("",own(sb._label,"TITLE"))
  assert.is_false(sb:hasTransient(108))
 end)
 it("clears completed work and uses only the active tool's work sentence",function()
  local sb=bar();sb:showTool("build",100,{title="Building firmware"})
  assert.equal("Building firmware",own(sb._label,"TITLE"))
  sb:postStatus("build","Done",100);sb:clearTool("build")
  assert.equal("",own(sb._label,"TITLE"))
 end)
 it("ignores unowned messages and leaves template state in the header",function()
  local sb=bar();sb:showTool(nil,100)
  sb:postStatus(nil,"Dependency index ready",100)
  assert.equal("",own(sb._label,"TITLE"))
  sb:showTool("build",100,{title="Preview finished"},"Build in progress")
  sb:postStatus("build","Preview finished",100)
  assert.equal("",own(sb._label,"TITLE"))
  assert.equal("NO",own(sb._status_icon:widget(),"VISIBLE"))
 end)
 it("shows a bounded activity count and preserves details in its tooltip",function()
  local sb=bar();sb:setActivity({state="running",text="Build 50%",count=3,tip="Three jobs"})
  local text=sb._refs.activity_text.current
  assert.equal("3",own(text,"TITLE"));assert.equal("Three jobs",own(text,"TIP"))
  sb:setActivity(nil);assert.equal("NO",own(sb:activityAnchor(),"VISIBLE"))
 end)
 it("calls settings and activity handlers",function()
  local sb=bar();local calls={}
  sb:onSettings(function() calls[#calls+1]="settings" end)
  sb:onActivity(function() calls[#calls+1]="activity" end)
  Element.call(sb._refs.settings.current,"FLAT_ACTION")
  Element.call(sb._refs.activity_text.current,"FLAT_ACTION")
  assert.same({"settings","activity"},calls)
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

local function status_label(sb) return sb._label end

describe("StatusBar.setStatus", function()
	it("resolves the theme colour instead of preserving a stale fallback", function()
		local sb = bar()
		local motion, frame = director()
		sb:setMotion(motion)
		local reactor = require("core.ui.ThemeReactor")
		local manager = stub(reactor, "themeManager", function()
			return { activeTheme = function() return { palette = function() return { textMuted = "174 181 191" } end } end }
		end)
		sb:setStatus("Ready")
		frame(1)
		assert.equal("174 181 191", own(status_label(sb), "FGCOLOR"))
		manager:revert()
	end)
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
