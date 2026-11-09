local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local Classes = require("core.imgui.Classes")
local Draw = require("core.imgui.Draw")

describe("imgui basic controls", function()
	local rt
	before_each(function()
		Fonts.backend=Null.new(); Fonts.reset()
		Element.globals.DEFAULTFONT,Element.globals.DLGBGCOLOR,Element.globals.DLGFGCOLOR="Segoe UI, 10","240 240 240","0 0 0"
		rt={redraw=function() end,capture=function() end,release=function() end,setFocus=function() end,now=function() return 0 end,animate=function() end,overlay=function(o) return {close=function() end} end}
	end)
	it("draws a label and respects separator orientation", function()
		local b,dc=Null.new(),nil
		local l=iup.label{TITLE="hello",FGCOLOR="1 2 3"}
		local s,c=Element.state(l),Classes.get("label"); s.x,s.y,s.w,s.h=0,0,50,20
		dc=Draw.new(b);dc:begin(100,100);c.draw(l,s,dc,rt)
		assert.are.equal("hello",b.frame_calls[3][7])
		local sep=iup.label{SEPARATOR="VERTICAL"}; local ss,sc=Element.state(sep),c;ss.x,ss.y,ss.w,ss.h=0,0,2,20;sc.draw(sep,ss,dc,rt)
		assert.is_true(#b.frame_calls>1)
	end)
	it("activates buttons only after an inside release", function()
		local count=0;local b=iup.button{TITLE="go",action=function()count=count+1 end}
		local s,c=Element.state(b),Classes.get("button");s.w,s.h=40,20
		c.event(b,s,{type="press",button=1,lx=2,ly=2},rt);c.event(b,s,{type="release",button=1,lx=50,ly=2},rt)
		assert.are.equal(0,count)
		c.event(b,s,{type="press",button=1,lx=2,ly=2},rt);c.event(b,s,{type="release",button=1,lx=2,ly=2},rt)
		assert.are.equal(1,count)
	end)
	it("maps gauge to progressbar and animates marquee", function()
		local p=iup.gauge{VALUE="0.5",MARQUEE="YES"};local s,c=Element.state(p),Classes.get("progressbar");s.x,s.y,s.w,s.h=0,0,100,8
		local b,dc=Null.new(),nil;dc=Draw.new(b);dc:begin(100,100);c.draw(p,s,dc,rt)
		assert.is_true(#b.frame_calls>0)
	end)
end)
