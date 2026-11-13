-- Comparative Windows UI benchmark. Run through scripts/benchmark-ui.ps1.
-- No product modules are changed: an isolated process loads this before main.lua.
local ffi = require('ffi')
ffi.cdef[[
int QueryPerformanceCounter(int64_t*); int QueryPerformanceFrequency(int64_t*);
void* GetCurrentProcess(void);
typedef struct { uint32_t low, high; } BenchTime;
int GetProcessTimes(void*, BenchTime*, BenchTime*, BenchTime*, BenchTime*);
typedef struct { uint32_t cb, PageFaultCount; size_t PeakWorkingSetSize, WorkingSetSize,
 QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage, QuotaPeakNonPagedPoolUsage,
 QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage, PrivateUsage; } BenchMemory;
int K32GetProcessMemoryInfo(void*, BenchMemory*, uint32_t);
typedef struct { long left, top, right, bottom; } BenchRect;
int GetClientRect(void*, BenchRect*); int AdjustWindowRectEx(BenchRect*, uint32_t, int, uint32_t);
int GetWindowRect(void*, BenchRect*);
intptr_t GetWindowLongPtrW(void*, int); int ShowWindow(void*, int);
int SetWindowPos(void*, void*, int, int, int, int, uint32_t);
]]
local q, freq = ffi.new('int64_t[1]'), ffi.new('int64_t[1]')
ffi.C.QueryPerformanceFrequency(freq)
local hz = tonumber(freq[0])
local function now() ffi.C.QueryPerformanceCounter(q); return tonumber(q[0]) / hz end
local entered = now()
local launched = tonumber(os.getenv('LUNAR_BENCH_LAUNCH_QPC')) or entered
local outdir = assert(arg[1], 'output directory required')
local mode = os.getenv('LUNAR_BENCH_MODE') or 'all'
local result = { mode = mode, errors = {}, pages = {}, extensions = {}, extension_registration = {} }
local startup_profiler
local function cpu()
 local a,b,k,u = ffi.new('BenchTime'),ffi.new('BenchTime'),ffi.new('BenchTime'),ffi.new('BenchTime')
 assert(ffi.C.GetProcessTimes(ffi.C.GetCurrentProcess(), a,b,k,u) ~= 0)
 return (tonumber(k.high)*4294967296 + k.low + tonumber(u.high)*4294967296 + u.low) / 1e7
end
local function memory()
 local m = ffi.new('BenchMemory'); m.cb = ffi.sizeof(m)
 assert(ffi.C.K32GetProcessMemoryInfo(ffi.C.GetCurrentProcess(),m,m.cb) ~= 0)
 return { working_mb = tonumber(m.WorkingSetSize)/1048576,
  private_mb = tonumber(m.PrivateUsage)/1048576, peak_working_mb = tonumber(m.PeakWorkingSetSize)/1048576,
  lua_mb = collectgarbage('count')/1024 }
end
local function save()
 local f = assert(io.open(outdir .. '/result.json','w'))
 f:write(require('cjson').encode(result)); f:close()
end
local function error_record(s) result.errors[#result.errors+1] = tostring(s); save() end
local iup = require('iup')
result.backend = rawget(iup,'_IMGUI') and 'imgui' or 'iup'
iup.Message = function(title,text) error_record(tostring(title)..': '..tostring(text)) end
local Host = require('core.classes.HostAPI')
local Manager = require('core.classes.ExtensionManager')
if os.getenv('LUNAR_BENCH_SKIP_PROBES') == '1' then
 result.network_probes_stubbed=true
 require('core.lib.async').probeTcp=function() return false,'benchmark probe bypass' end
end
local host, tabs = nil, {}
local add = Host.addTab
Host.addTab = function(self,title,widget,owner,opts)
 local ret = add(self,title,widget,owner,opts)
 local rec = owner and self._owners[owner]
 if rec and rec.tabs then tabs[#tabs+1] = { title=title, owner=owner, index=#rec.tabs } end
 return ret
end
local register = Host.registerExtension
Host.registerExtension = function(self,ext,manifest,...)
 local ok,err = register(self,ext,manifest,...)
 if ok and type(ext.register) == 'function' then
  local run = ext.register
  ext.register = function(...)
   local a,c = now(),cpu()
   local ret = run(...)
   result.extension_registration[#result.extension_registration+1] = {
    id=manifest.id, wall_ms=(now()-a)*1000, cpu_ms=(cpu()-c)*1000 }
   return ret
  end
 end
 return ok,err
end
local load = Manager.loadAll
if mode == 'none' then
 Manager._discover = function() return {} end
 require('core.lib.OrgProfile').resolve = function()
  return nil, {reason='none',errors={},warnings={},available={}}
 end
end
Manager.loadAll = function(self,ctx)
 host = ctx
 local a,c = now(),cpu()
 local n = load(self,ctx)
 result.load_ms, result.load_cpu_ms = (now()-a)*1000,(cpu()-c)*1000
 result.extension_count = n
 for _,e in ipairs(self.extensions) do result.extensions[#result.extensions+1] = {id=e.id,source=e.source} end
 result.skipped = self.skipped
 return n
end
local shown = Host._markShown
Host._markShown = function(self,...)
 local ret = shown(self,...)
 result.mark_shown_ms = (now()-launched)*1000
 return ret
end
local R
local frame_count = 0
if result.backend == 'imgui' then
 R = require('core.imgui.Runtime')
 local realframe = R.frame
 R.frame = function(...) frame_count=frame_count+1; return realframe(...) end
 R.warn = function(s) error_record(s) end
end
local function resize()
 local F = require('core.classes.IupFFI')
 local hwnd = assert(F.getptr(F.ptr(host.dialog),'HWND'))
 ffi.C.ShowWindow(hwnd,9)
 local rect = ffi.new('BenchRect',{0,0,1400,900})
 local style,ex = tonumber(ffi.C.GetWindowLongPtrW(hwnd,-16)),tonumber(ffi.C.GetWindowLongPtrW(hwnd,-20))
 assert(ffi.C.AdjustWindowRectEx(rect,style,0,ex) ~= 0)
 assert(ffi.C.SetWindowPos(hwnd,nil,30,30,rect.right-rect.left,rect.bottom-rect.top,0x14) ~= 0)
 local cr = ffi.new('BenchRect'); ffi.C.GetClientRect(hwnd,cr)
 -- Lunar's custom WM_NCCALCSIZE changes the normal caption inset. Correct the
 -- actual client delta instead of assuming AdjustWindowRectEx knows that inset.
 for _=1,3 do
  if cr.right == 1400 and cr.bottom == 900 then break end
  local wr=ffi.new('BenchRect'); ffi.C.GetWindowRect(hwnd,wr)
  ffi.C.SetWindowPos(hwnd,nil,30,30,wr.right-wr.left+1400-cr.right,wr.bottom-wr.top+900-cr.bottom,0x14)
  ffi.C.GetClientRect(hwnd,cr)
 end
 result.client = {width=tonumber(cr.right),height=tonumber(cr.bottom)}
 assert(cr.right == 1400 and cr.bottom == 900,'wrong client size')
end
local function sample(fn,n)
 local values = {}
 local c,a = cpu(),now()
 for i=1,n do local t=now(); fn(i); values[i]=(now()-t)*1000 end
 return {samples_ms=values,wall_ms=(now()-a)*1000,cpu_ms=(cpu()-c)*1000}
end
local function repaint() iup.Redraw(host.dialog,1); iup.Flush() end
local function relayout() iup.Refresh(host.dialog); repaint() end
local function focus(t)
 if t.owner then assert(host:focusTab(t.owner,t.index))
 else assert(host:_activateTabWidget(t.widget)) end
 iup.Flush()
end
local mainloop = iup.MainLoop
iup.MainLoop = function()
 if startup_profiler then startup_profiler.stop() end
 assert(host,'host was not captured')
 resize(); repaint()
 result.ready_ms = (now()-launched)*1000
 result.lua_to_ready_ms = (now()-entered)*1000
 result.ready_cpu_ms = cpu()*1000
 result.ready_memory = memory()
 if R then
  local b=R.backend(); result.renderer=b.renderer and b.renderer() or nil
  local native=require('core.imgui.NativeLayout')
  result.native_layout=native.available and native.enabled
 end
 if #tabs > 0 then tabs[#tabs+1]={title='Settings',widget=assert(host._host_tabs.settings)} end
 result.tab_titles = {}
 for _,t in ipairs(tabs) do result.tab_titles[#result.tab_titles+1]=t.title end
 if mode == 'none' then assert(result.extension_count == 0,'extensions leaked into baseline') end
 save()
 local timer = iup.timer{time=tonumber(os.getenv('LUNAR_BENCH_WARMUP_MS')) or 2000}
 local state, idle_t,idle_c,idle_frames = 'warmup'
 function timer:action_cb()
  local ok,err = xpcall(function()
   if state == 'warmup' then
    idle_t,idle_c,idle_frames = now(),cpu(),frame_count
    state = 'idle'
    self.run='NO'; self.time=tonumber(os.getenv('LUNAR_BENCH_IDLE_MS')) or 2000; self.run='YES'
    return
   end
   self.run='NO'
   result.idle = {duration_s=now()-idle_t,cpu_ms=(cpu()-idle_c)*1000,
    frames=result.backend == 'imgui' and frame_count-idle_frames or nil, memory=memory()}
   save()
   if os.getenv('LUNAR_BENCH_IDLE_ONLY') == '1' then
    result.idle_only=true; result.complete=true; save(); iup.ExitLoop(); return
   end
   -- Startup/idle keep the shipping motion setting. Microbenchmarks measure
   -- completed state changes, with animations disabled identically on both hosts.
   host:motion():configure{enabled=false}
   local function page(title)
    for _=1,5 do repaint() end
    result.pages[#result.pages+1] = {title=title,
     repaint=sample(repaint,40),relayout=sample(relayout,15)}
    save()
   end
   if #tabs == 0 then page('Settings') else
    for _,t in ipairs(tabs) do focus(t); page(t.title) end
    -- Repeated cycles through all tabs use the real group/menu/status routing.
    result.switch = sample(function(i)
     local t=tabs[(i-1)%#tabs+1]; focus(t)
    end,#tabs*10)
   end
   result.after_memory = memory()
   if R then
    result.layout_stats=require('core.imgui.Layout').stats()
    result.native_layout_stats=require('core.imgui.NativeLayout').stats()
    result.font_cache=require('core.imgui.Fonts').measure_cache_stats()
   end
   if R and os.getenv('LUNAR_BENCH_PROFILE') == '1' then
    local prof=require('jit.p')
    local Layout=require('core.imgui.Layout')
    local Element=require('core.imgui.Element')
    local timing={frame_begin=0,frame_end=0,layout=0,paint=0,frames=200}
    local B=R.backend()
    local begin,finish,lay,paint= B.frame_begin,B.frame_end,Layout.run,R.paint
    B.frame_begin=function(...) local a=now(); local ret=begin(...); timing.frame_begin=timing.frame_begin+now()-a; return ret end
    B.frame_end=function(...) local a=now(); local ret=finish(...); timing.frame_end=timing.frame_end+now()-a; return ret end
    Layout.run=function(...) local a=now(); local ret=lay(...); timing.layout=timing.layout+now()-a; return ret end
    -- Runtime calls its local paint internally. Direct paint is measured separately below.
    prof.start('Fl2',outdir..'/profile.txt')
    local a,c=now(),cpu()
    for _=1,200 do repaint() end
    timing.wall_ms,timing.cpu_ms=(now()-a)*1000,(cpu()-c)*1000
    prof.stop()
    timing.frame_begin_ms,timing.frame_end_ms,timing.layout_ms=timing.frame_begin*1000,timing.frame_end*1000,timing.layout*1000
    local dc=R.dc(); local st=Element.state(host.dialog)
    timing.paint_only=sample(function()
     B.frame_begin(); dc:begin(st.w,st.h)
     local p=now(); paint(host.dialog,dc); timing.paint=timing.paint+now()-p
     B.frame_end()
    end,80)
    timing.paint_only_mean_ms=timing.paint*1000/80
    prof.start('Fl2',outdir..'/profile-layout.txt')
    timing.forced_layout=sample(relayout,80)
    prof.stop()
    result.profile_breakdown=timing
    B.frame_begin,B.frame_end,Layout.run=begin,finish,lay
   end
   result.complete=true; save()
   iup.ExitLoop()
  end,debug.traceback)
  if not ok then error_record(err); iup.ExitLoop() end
  return state == 'idle' and self.run ~= 'NO' and iup.DEFAULT or iup.CLOSE
 end
 timer.run='YES'
 return mainloop()
end
if os.getenv('LUNAR_BENCH_PROFILE') == '1' then
 package.path=LUNAR_SOURCE_DIR..'/vendor/luajit/bin/lua/?.lua;'..package.path
 result.startup_spans={}
 local function pack(...) return {n=select('#',...),...} end
 local function wrap(label,obj,key)
  local fn=obj[key]
  if type(fn) ~= 'function' then return end
  obj[key]=function(...)
   local a=now(); local ret=pack(fn(...)); local duration=(now()-a)*1000
   if duration > 0.05 then result.startup_spans[#result.startup_spans+1]={name=label,start_ms=(a-launched)*1000,wall_ms=duration} end
   return unpack(ret,1,ret.n)
  end
 end
 wrap('OrgProfile.resolve',require('core.lib.OrgProfile'),'resolve')
 local settings=require('core.classes.SettingsManager')
 wrap('Settings.load',settings,'load'); wrap('Settings.applyProfile',settings,'applyProfile')
 wrap('iup.Map',iup,'Map'); wrap('iup.Show',iup,'Show')
 wrap('async.probeTcp',require('core.lib.async'),'probeTcp')
 result.ready_callback_costs={}
 local onready=Host.onReady
 Host.onReady=function(self,fn,owner)
  return onready(self,function()
   local a=now(); local ret=pack(fn())
   result.ready_callback_costs[#result.ready_callback_costs+1]={owner=owner and owner.id,wall_ms=(now()-a)*1000}
   return unpack(ret,1,ret.n)
  end,owner)
 end
 local platform=require('core.platform')
 for name,fn in pairs(platform) do if type(fn)=='function' then wrap('platform.'..name,platform,name) end end
 startup_profiler=require('jit.p')
 startup_profiler.start('Fl2',outdir..'/profile-startup.txt')
end
local ok,err=xpcall(function() dofile(LUNAR_SOURCE_DIR..'/src/lua/core/main.lua') end,debug.traceback)
if not ok then error_record(err) end
if not result.complete then os.exit(1) end
os.exit(#result.errors == 0 and 0 or 2)
