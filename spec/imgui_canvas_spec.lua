local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local Classes = require("core.imgui.Classes")
local Draw = require("core.imgui.Draw")

describe("imgui canvas", function()
	it("joins pixel-aligned corner segments including single-pixel endpoints", function()
		local b = Null.new()
		local c = iup.canvas{ action = function(self)
			iup.DrawBegin(self)
			iup.SetAttribute(self, "DRAWCOLOR", "1 2 3")
			iup.DrawLine(self, 2, 3, 5, 3)
			iup.DrawLine(self, 5, 4, 5, 4)
			iup.DrawEnd(self)
		end }
		local st = Element.state(c)
		st.x, st.y, st.w, st.h = 10, 20, 30, 40
		local dc = Draw.new(b)
		dc:begin(100, 100)
		Classes.get("canvas").draw(c, st, dc, {})
		local runs = {}
		for _, call in ipairs(b.frame_calls) do
			if call[1] == "rect_filled" and call[6] == require("core.imgui.Color").parse("1 2 3") then
				runs[#runs + 1] = { call[2], call[3], call[4], call[5] }
			end
		end
		assert.same({ { 12, 23, 16, 24 }, { 15, 24, 16, 25 } }, runs)
	end)
	it("runs ACTION inside the Draw context with inclusive coordinates", function()
		local b=Null.new();Fonts.backend=b;Fonts.reset()
		local gotw, goth
		local c=iup.canvas{BGCOLOR="9 8 7",action=function(self)
			iup.DrawBegin(self);iup.SetAttribute(self,"DRAWSTYLE","FILL");iup.SetAttribute(self,"DRAWCOLOR","1 2 3");iup.DrawRectangle(self,0,0,2,2);iup.DrawEnd(self)
			gotw, goth=iup.DrawGetSize(self)
		end}
		local s,cl=Element.state(c),Classes.get("canvas");s.x,s.y,s.w,s.h=10,20,30,40
		local dc=Draw.new(b);dc:begin(100,100);cl.draw(c,s,dc,{})
		assert.are.same({30,40},{gotw,goth})
		assert.are.equal("rect_filled",b.frame_calls[4][1])
		assert.are.same({10,20,13,23}, {b.frame_calls[4][2],b.frame_calls[4][3],b.frame_calls[4][4],b.frame_calls[4][5]})
	end)
	it("forwards mouse and resize callbacks", function()
		local buttons,resized=0,0
		local c=iup.canvas{button_cb=function()buttons=buttons+1 end,resize_cb=function()resized=resized+1 end}
		local s,cl=Element.state(c),Classes.get("canvas");s.w,s.h=20,20
		local rt={capture=function()end,release=function()end}
		cl.draw(c,s,Draw.new(Null.new()),rt)
		cl.event(c,s,{type="press",button=1,lx=2,ly=3},rt)
		assert.are.equal(1,buttons);assert.are.equal(1,resized)
	end)
end)
