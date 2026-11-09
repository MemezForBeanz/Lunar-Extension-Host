local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local Classes = require("core.imgui.Classes")
local Draw = require("core.imgui.Draw")

local function layout()
	return {
		font = Fonts.forElement, charsize = function(e) return Fonts.forElement(e):charsize() end,
		size = function(v) local a,b=tostring(v or ""):match("^(%d*)x(%d*)$"); return tonumber(a), tonumber(b) end,
	}
end

describe("imgui flattoggle", function()
	local rt
	before_each(function()
		Fonts.backend = Null.new(); Fonts.reset()
		Element.globals.DEFAULTFONT, Element.globals.DLGBGCOLOR, Element.globals.DLGFGCOLOR = "Segoe UI, 10", "240 240 240", "0 0 0"
		rt = { redraw=function() end, capture=function() end, release=function() end, setFocus=function() end }
	end)
	it("measures title, check and padding", function()
		local t = iup.flattoggle{ TITLE="Enable", CHECKSIZE="16", CHECKSPACING="4", PADDING="3x2" }
		local w,h = Classes.get("flattoggle").natural(t, Element.state(t), layout())
		assert.is_true(w >= 16 + 4 + 3 * 2)
		assert.is_true(h >= 2 * 2)
	end)
	it("cycles three states and reports both callbacks", function()
		local actions, changes = {}, 0
		local t = iup.flattoggle{VALUE="OFF", ["3STATE"]="YES",
			flat_action=function(_, v) actions[#actions+1]=v end,
			valuechanged_cb=function() changes=changes+1 end}
		local s,c = Element.state(t), Classes.get("flattoggle"); s.w,s.h=80,24
		c.event(t,s,{type="press",button=1,lx=2,ly=2},rt)
		c.event(t,s,{type="release",button=1,lx=2,ly=2},rt)
		assert.are.equal("NOTDEF", t.VALUE)
		assert.are.equal(1, #actions); assert.are.equal(1, changes)
	end)
	it("draws the switch track and knob", function()
		local b, dc = Null.new(), nil
		local t = iup.flattoggle{SWITCH="YES", VALUE="ON", SWITCHPOS="50", SWITCHONCOLOR="1 2 3", SWITCHKNOBCOLOR="4 5 6"}
		local s,c=Element.state(t),Classes.get("flattoggle"); s.x,s.y,s.w,s.h=0,0,60,24
		dc=Draw.new(b); dc:begin(100,100); c.draw(t,s,dc,{})
		assert.is_true(#b.frame_calls >= 2)
	end)
end)
