local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local E = require("core.imgui.Element")
local iup = require("core.imgui.iup")
describe("native overlay windows", function()
	local B, main
	before_each(function()
		B = Null.new{ w = 400, h = 300, overlay_windows = true, dialog_windows = true }
		R.init(B)
		main = iup.dialog{ iup.vbox{}, RASTERSIZE = "400x300" }
		iup.Show(main); R.frame()
	end)
	after_each(function() R.close() end)
	local function open(x, y, event)
		return R.overlay{ owner = main, x = x, y = y, w = 100, h = 70,
			draw = function(dc, o) dc:fill(o.x, o.y, o.w, o.h, "255 255 255", { radius = 4 }) end,
			event = event or function() end }
	end
	it("keeps inside overlays on their owner and promotes past its edge until closed", function()
		local o = open(20,20); R.frame(); assert.is_nil(o.win)
		o:move(390,290); R.frame(); local id = o.win; assert.is_number(id)
		o:move(20,20); R.frame(); assert.equal(id,o.win)
		o:close(); assert.is_false(B.overlays[id].visible)
	end)
	it("promotes over visible video only", function()
		local v = iup.videohost{ RASTERSIZE = "200x150" }
		iup.Append(iup.GetChild(main,0),v); iup.Refresh(main); R.frame()
		local o = open(20,20); R.frame(); assert.is_number(o.win)
		o:close(); v.visible = "NO"; R.frame()
		local p = open(20,20); R.frame(); assert.is_nil(p.win)
	end)
	it("routes popup input and retains capture across its boundary", function()
		local seen = {}
		local o = open(390,290,function(ev) seen[#seen+1] = ev end); R.frame()
		B.queue{ events = {{ type="press", button=1, x=395, y=295, win=o.win }} }; R.frame()
		B.queue{ events = {{ type="move", x=5, y=5, win=0, mods={b1=true} }, {type="release",button=1,x=5,y=5,win=0}} }; R.frame()
		assert.equal("press",seen[1].type); assert.equal(5,seen[1].lx)
		assert.equal("release",seen[#seen].type); assert.is_nil(R._overlay_capture)
	end)
	it("closes on outside presses and application deactivation", function()
		local o = open(390,290); R.frame()
		B.queue{events={{type="press",button=1,x=5,y=5,win=0}}}; R.frame(); assert.is_false(o.open)
		local p = open(390,290); R.frame()
		B.queue{events={{type="dismiss"}}}; R.frame(); assert.is_false(p.open)
	end)
	it("reuses two pooled windows then releases idle resources", function()
		local o = open(390,290); R.frame(); local id=o.win; o:close()
		local p = open(390,290); R.frame(); assert.equal(id,p.win); assert.equal(1,B.overlay_opens)
		p:close(); B.advance(6); R.frame(); assert.is_nil(next(B.overlays))
	end)
	it("uses the secondary owner and shifts to the monitor work area", function()
		local d = iup.dialog{ iup.vbox{}, RASTERSIZE="200x120" }; iup.Show(d); R.frame()
		local o=R.overlay{owner=d,x=190,y=110,w=100,h=70,event=function()end,draw=function()end}
		B.monitor.work={0,0,300,200}; R.frame()
		assert.equal(E.state(d).data.win,B.overlays[o.win].owner)
		assert.is_true(o.x+(o.shift_x or 0)+o.w<=300)
	end)
	it("draws combo rows in secondary client coordinates exactly once", function()
		local list=iup.list{DROPDOWN="YES",RASTERSIZE="120x24"};list["1"]="Row one";list["2"]="Row two"
		local d=iup.dialog{iup.vbox{iup.fill{},list},RASTERSIZE="160x100"};iup.Show(d);R.frame()
		R.deliver(list,{type="press",button=1});R.frame()
		local o=E.state(list).data.popup
		assert.is_number(o.win)
		local found=false
		for _,c in ipairs(B.lastFrame()) do
			if c[1]=="text" and c[7]=="Row one" and math.abs(c[4]-(o.x+3))<1 then found=true end
		end
		assert.is_true(found)
	end)
	it("recreates a promoted window after its native owner destroys it", function()
		local o=open(390,290);R.frame();local id=o.win;B.overlays[id]=nil
		R.frame();assert.is_nil(o.win);R.frame();assert.is_number(o.win);assert.is_not.equal(id,o.win)
	end)
	it("promotes tooltips at an owner edge without taking mouse input", function()
		local tip=iup.label{TITLE="Tip",TIP="Outside the owner",RASTERSIZE="100x24"}
		local d=iup.dialog{iup.vbox{iup.fill{},tip},RASTERSIZE="150x90"};iup.Show(d);R.frame()
		local st,ds=E.state(tip),E.state(d)
		B.queue{events={{type="move",x=ds.data.ox+st.x+5,y=ds.data.oy+st.y+5,win=ds.data.win}}};R.frame()
		B.advance(0.6);R.frame()
		local _,p=next(B.overlays);assert.is_not_nil(p);assert.is_true(p.passthrough);assert.is_true(p.visible)
		B.queue{mx=0,my=0};R.frame();assert.is_false(p.visible)
	end)
	it("bounds the hidden pool to two windows", function()
		local layers={open(390,290),open(390,290),open(390,290)};R.frame()
		for _,o in ipairs(layers) do o:close() end
		local n=0;for _ in pairs(B.overlays)do n=n+1 end;assert.equal(2,n)
	end)
	it("keeps unbounded effects and capability-free backends in-surface", function()
		local effect=R.overlay{owner=main,draw=function()end}; R.frame(); assert.is_nil(effect.win)
		R.close(); B=Null.new{w=400,h=300,dialog_windows=true}; R.init(B)
		main=iup.dialog{iup.vbox{}}; iup.Show(main)
		local o=open(1000,1000); R.frame(); assert.is_nil(o.win)
	end)
end)
