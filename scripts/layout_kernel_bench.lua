-- Isolate cold/full-tree and warm/local layout on a populated 1,000-cell tree.
local R=require('core.imgui.Runtime')
local Null=require('core.imgui.backend.Null')
local iup=require('core.imgui.iup')
local L=require('core.imgui.Layout')
local N=require('core.imgui.NativeLayout')
local ffi=require('ffi')
ffi.cdef[[ int QueryPerformanceCounter(int64_t*); int QueryPerformanceFrequency(int64_t*); ]]
local q,f=ffi.new('int64_t[1]'),ffi.new('int64_t[1]');ffi.C.QueryPerformanceFrequency(f)
local hz=tonumber(f[0])
local function now() ffi.C.QueryPerformanceCounter(q);return tonumber(q[0])/hz end
R.init(Null.new());assert(N.available)
local rows={}
local first
for row=1,200 do
 local cells={}
 for col=1,5 do
  local label=iup.label{TITLE='Populated cell '..col,EXPAND='HORIZONTAL'}
  cells[#cells+1]=label;first=first or label
 end
 cells.GAP='4';rows[#rows+1]=iup.hbox(cells)
end
local root=iup.dialog{iup.vbox(rows),SHRINK='YES'}
local results={}
for _,enabled in ipairs{false,true,false,true} do
 N.enabled=enabled
 for _=1,10 do L.invalidate(root,true);L.run(root,1400,900) end
 local a=now()
 for _=1,80 do L.invalidate(root,true);L.run(root,1400,900) end
 local full=(now()-a)*1000/80
 a=now()
 for i=1,300 do iup.SetAttribute(first,'TITLE','updated '..i);L.run(root,1400,900) end
 results[#results+1]={native=enabled,full_ms=full,local_ms=(now()-a)*1000/300}
end
local out=assert(io.open(assert(arg[1]),'w'));out:write(require('cjson').encode(results));out:close()
os.exit(0)
