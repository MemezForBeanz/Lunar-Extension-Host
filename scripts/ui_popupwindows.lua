-- Run only through the private-desktop runner. Captures are back-buffer composites.
local iup = require("iup")
local R = require("core.imgui.Runtime")
local E = require("core.imgui.Element")
local B = R.backend()
local ffi = require("ffi")
local platform = require("core.platform")
platform.open = function() return false end
platform.elevate = function() return false end
ffi.cdef[[
typedef struct { uint32_t cb, faults; size_t peakws, ws, q1,q2,q3,q4, page, peakpage, privatebytes; } POP_MEM;
void* GetCurrentProcess(void);
int K32GetProcessMemoryInfo(void*, POP_MEM*, uint32_t);
void Sleep(unsigned long);
long GetWindowLongW(void*, int);
void* GetWindow(void*, unsigned);
void* GetFocus(void);
intptr_t SendMessageW(void*, unsigned, uintptr_t, intptr_t);
typedef struct { long x,y; } POP_POINT;
int ClientToScreen(void*, POP_POINT*);
void* WindowFromPoint(POP_POINT);
]]
local u = ffi.load("user32")
local outdir = assert(arg[1])
local out = assert(io.open(outdir.."/probe.txt","w"))
local function run()
local function say(s,...) out:write(string.format(s,...),"\n"); out:flush() end
local function mem()
	local m=ffi.new("POP_MEM");m.cb=ffi.sizeof(m);ffi.C.K32GetProcessMemoryInfo(ffi.C.GetCurrentProcess(),m,m.cb)
	return tonumber(m.ws)/1048576,tonumber(m.privatebytes)/1048576
end
local function ptr(n) return ffi.cast("void*",tonumber(n)) end
local main=iup.dialog{iup.vbox{ iup.videohost{RASTERSIZE="300x180"} },TITLE="Popup probe",RASTERSIZE="640x420"}
local list=iup.list{DROPDOWN="YES",RASTERSIZE="120x24",[1]="First",[2]="Second",[3]="Third",[4]="Fourth"}
list["1"],list["2"],list["3"],list["4"]="First","Second","Third","Fourth"
local tip=iup.label{TITLE="Hover for tooltip",TIP="A tooltip beyond the small window edge",RASTERSIZE="180x24"}
local d=iup.dialog{iup.vbox{iup.fill{},iup.hbox{iup.fill{},list},tip},TITLE="Small owner",RASTERSIZE="240x140",PARENTDIALOG=main}
iup.ShowXY(main,100,100);iup.ShowXY(d,340,260)
for i=1,4 do R.frame() end
local function shot(name,id)
	B.screenshot(outdir.."/"..name..".bmp",0,0,0,0,id or 0,true);R.frame()
end
local function inspect(o)
	assert(o.win,"overlay was not promoted")
	local h=ptr(B.window("popup_hwnd",o.win))
	local style,ex=u.GetWindowLongW(h,-16),u.GetWindowLongW(h,-20)
	assert(bit.band(style,0x80000000)~=0,"WS_POPUP")
	assert(bit.band(ex,0x08000080)==0x08000080,"NOACTIVATE/TOOLWINDOW")
	assert(u.SendMessageW(h,0x21,0,0)==3,"MA_NOACTIVATE")
	say("popup %d owner=%s style=%x ex=%x",o.win,tostring(u.GetWindow(h,4)),tonumber(style),tonumber(ex))
end
R.activateDialog(d)
local menu=iup.menu{iup.item{TITLE="Context menu beyond owner"},iup.item{TITLE="Second item"},iup.item{TITLE="Third item"}}
local ds=E.state(d)
if os.getenv("LUNAR_OVERLAY_WINDOWS")=="0" then
	local o=R.overlay{owner=d,x=ds.w-10,y=ds.h-10,w=180,h=100,event=function()end,draw=function()end}
	R.frame();assert(not o.win);assert(B.memory_stats().overlay_windows==0);say("environment fallback passed");R.close();return
end
local cold_start=B.now();local cold_ws,cold_private=mem()
require("core.imgui.widgets.menu").popupMenu(menu,ds.data.ox+ds.w-15,ds.data.oy+ds.h-15,R)
local state={overlay=R.overlays()[#R.overlays()]}
R.frame();say("cold open+frame ms=%.3f",(B.now()-cold_start)*1000)
local cold_ws_after,cold_private_after=mem();say("cold working set delta MiB=%.3f private delta=%.3f",cold_ws_after-cold_ws,cold_private_after-cold_private)
inspect(state.overlay);shot("context-edge",ds.data.win);state.overlay:close()
R.deliver(list,{type="press",button=1,lx=5,ly=5});R.frame()
inspect(E.state(list).data.popup);shot("dropdown-edge",ds.data.win);E.state(list).data.popup:close()
iup.Hide(d);R.activateDialog(main)
require("core.imgui.widgets.menu").popupMenu(menu,40,40,R)
local vstate={overlay=R.overlays()[#R.overlays()]}
R.frame();inspect(vstate.overlay);shot("menu-video")
local p=ffi.new("POP_POINT",60,60);u.ClientToScreen(ptr(B.window("hwnd")),p)
assert(u.WindowFromPoint(p)==ptr(B.window("popup_hwnd",vstate.overlay.win)),"menu is above the native video child")
say("native video z-order hit test passed")
u.SendMessageW(ptr(B.window("hwnd")),0x1c,0,0);R.frame();assert(not vstate.overlay.open,"deactivation closes menu")
say("owner deactivation dismissed menu")
iup.Show(d);R.frame()
local ts=E.state(tip)
local h=ptr(B.window("popup_hwnd",ds.data.win))
local l=bit.bor(ts.x+5,bit.lshift(ts.y+5,16))
-- A private desktop has no physical pointer; feed the native adapter a stationary hover.
local begin=B.frame_begin
B.frame_begin=function()
	local f=begin();f.mx,f.my=ds.data.ox+ts.x+5,ds.data.oy+ts.y+5;f.inside=true;f.win=ds.data.win
	f.events={{type="move",x=f.mx,y=f.my,win=f.win,mods={}}};return f
end
for i=1,12 do R.frame();ffi.C.Sleep(60) end
say("tooltip hover target=%s expected=%s",tostring(R.hovered()),tostring(tip))
say("tip local=%d,%d owner=%d,%d size=%d,%d input=%s,%s win=%s",ts.x,ts.y,ds.data.ox,ds.data.oy,ds.w,ds.h,tostring(R.input().mx),tostring(R.input().my),tostring(R.input().win))
shot("tooltip-edge",ds.data.win)
B.frame_begin=begin
-- Warm fonts and targets before measuring repeated opens.
local ws0,p0=mem();local times={}
for i=1,40 do
	local start=B.now()
	local o=R.overlay{owner=d,x=ds.w-10,y=ds.h-10,w=180,h=100,event=function()end,draw=function(dc)dc:fill(ds.w-10,ds.h-10,180,100,"240 240 240",{radius=5})end}
	R.frame();times[i]=(B.now()-start)*1000;o:close();R.frame()
end
table.sort(times);local ws1,p1=mem()
say("warm open+frame latency ms p50=%.3f p95=%.3f",times[20],times[38])
say("working set MiB before=%.3f after=%.3f delta=%.3f; private delta=%.3f",ws0,ws1,ws1-ws0,p1-p0)
local stats=B.memory_stats();say("pooled windows=%d retained overlay bytes=%d",stats.overlay_windows,stats.overlay_bytes)
ffi.C.Sleep(5100);R.frame();stats=B.memory_stats();say("after idle windows=%d overlay bytes=%d",stats.overlay_windows,stats.overlay_bytes)
R.close()
end
local ok,err=xpcall(run,debug.traceback)
if not ok then out:write(tostring(err),"\n") end
out:close();os.exit(ok and 0 or 1)
