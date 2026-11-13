--- Typed, batched FFI arithmetic for boxes. Lua keeps tree ownership and callbacks.
local Element = require('core.imgui.Element')
local band = require('bit').band
local M = { available = false, enabled = os.getenv('LUNAR_LAYOUT') ~= 'lua' }
-- Small LuaJIT loops are cheaper than marshaling a tiny batch. Keep the native
-- path for work large enough to amortize the boundary; force it for differential QA.
M.min_children = os.getenv('LUNAR_LAYOUT') == 'native' and 0 or 16
local ok, ffi = pcall(require, 'ffi')
if not ok then return M end
ffi.cdef[[
typedef struct {
 double nw, nh, minw, minh, maxw, maxh, weight, content_min;
 double x, y, w, h;
 uint32_t expand, flags, limits;
} LunarLayoutNode;
typedef struct {
 double x, y, w, h, mx, my, gap, total, align;
 uint32_t expand, vertical, homogeneous, shrink;
} LunarLayoutBox;
int lunar_layout_abi(void);
size_t lunar_layout_node_size(void); size_t lunar_layout_box_size(void);
int lunar_layout_natural(LunarLayoutNode*, size_t, LunarLayoutBox*, uint32_t, int, double*);
int lunar_layout_place(LunarLayoutNode*, size_t, const LunarLayoutBox*);
]]
local C
local counters = { natural_calls=0, place_calls=0, nodes=0 }
function M.stats(reset)
 local out={}; for k,v in pairs(counters) do out[k]=v; if reset then counters[k]=0 end end; return out
end
local function bind(lib)
 local valid, match = pcall(function()
  return lib.lunar_layout_abi()==1 and lib.lunar_layout_node_size()==ffi.sizeof('LunarLayoutNode')
   and lib.lunar_layout_box_size()==ffi.sizeof('LunarLayoutBox')
 end)
 if valid and match then C=lib; M.available=true; return true end
 return false
end
bind(ffi.C)
-- Explicit test injection; production never loads a DLL from an environment path.
function M.testLibrary(path) return bind(ffi.load(path)) end
local function limits(st,n)
 local a=st.attrs; local d=st.data
 local saved=d.layout_limits
 if not saved or saved.min~=a.MINSIZE or saved.max~=a.MAXSIZE then
  local function pair(s)
   if not s then return nil,nil end
   local x,y=tostring(s):match('^%s*([^x]*)x(.*)$')
   if not x then return tonumber(s),nil end
   return tonumber(x),tonumber(y)
  end
  local mw,mh=pair(a.MINSIZE); local xw,xh=pair(a.MAXSIZE)
  saved={min=a.MINSIZE,max=a.MAXSIZE,mw=mw,mh=mh,xw=xw,xh=xh,
   flags=(mw and 1 or 0)+(mh and 2 or 0)+(xw and 4 or 0)+(xh and 8 or 0)}
  d.layout_limits=saved
 end
 n.minw,n.minh,n.maxw,n.maxh=saved.mw or 0,saved.mh or 0,saved.xw or 0,saved.xh or 0
 n.limits=saved.flags
end
local function prepare(st,L,vertical,placing)
 local count=#st.children; local d=st.data; local buf=d.native_layout
 if not buf or buf.capacity<count then
  local capacity=math.max(4,buf and buf.capacity or 4)
  while capacity<count do capacity=capacity*2 end
  buf={capacity=capacity,nodes=ffi.new('LunarLayoutNode[?]',capacity),box=ffi.new('LunarLayoutBox'),out=ffi.new('double[3]'),synced={}}
  d.native_layout=buf
 end
 local b=buf.box
 b.x,b.y,b.w,b.h=st.x or 0,st.y or 0,st.w or 0,st.h or 0
 b.mx,b.my,b.gap,b.total=d.mx or 0,d.my or 0,d.gap or 0,d.total_natural or 0
 b.expand,b.vertical,b.homogeneous,b.shrink=st.expand or 0,vertical and 1 or 0,d.homogeneous and 1 or 0,L.shrink() and 1 or 0
 local align=(st.attrs.ALIGNMENT or ''):upper()
 b.align=align=='ACENTER' and .5 or (align==(vertical and 'ARIGHT' or 'ABOTTOM') and 1 or 0)
 for i,child in ipairs(st.children) do
  local cs=Element.state(child); local n=buf.nodes[i-1]
  if cs then
   local cached,j=buf.synced,(i-1)*8
   local f=cs.attrs.FLOATING
   local floating=f=='IGNORE' or f=='YES' or f=='ON'
   local nw,nh,e=cs.nat_w or 0,cs.nat_h or 0,cs.expand or 0
   if cached[j+1]~=nw then n.nw=nw;cached[j+1]=nw end
   if cached[j+2]~=nh then n.nh=nh;cached[j+2]=nh end
   if cached[j+3]~=e then n.expand=e;cached[j+3]=e end
   local flags=(cs.class.children~=0 and 1 or 0)+(cs.classname=='fill' and 2 or 0)+(floating and 4 or 0)
   local weight=tonumber(cs.attrs.EXPANDWEIGHT)
   if weight then flags=flags+8 end
   if cached[j+4]~=flags then n.flags=flags;cached[j+4]=flags end
   weight=weight or 1
   if cached[j+5]~=weight then n.weight=weight;cached[j+5]=weight end
   if placing then
    if cached[j+6]~=cs.attrs.MINSIZE or cached[j+7]~=cs.attrs.MAXSIZE then
     limits(cs,n);cached[j+6],cached[j+7]=cs.attrs.MINSIZE,cs.attrs.MAXSIZE
    end
    n.content_min=(not floating and not d.homogeneous and band(e,vertical and 2 or 8)~=0
     and b.shrink~=0 and b.total>(vertical and st.h or st.w))
     and L.minContent(child,not vertical) or 0
   end
  else n.flags=4;buf.synced[(i-1)*8+4]=nil end
 end
 counters.nodes=counters.nodes+count
 return buf,count
end
function M.natural(st,L,vertical,normalize,expand_override)
 if not (M.available and M.enabled) or #st.children<M.min_children then return nil end
 local buf,count=prepare(st,L,vertical,false)
 assert(C.lunar_layout_natural(buf.nodes,count,buf.box,normalize or 0,expand_override or -1,buf.out)~=0)
 if normalize or expand_override then for i,child in ipairs(st.children) do
  local cs=Element.state(child); local n=buf.nodes[i-1]
  if cs then
   if not L.floating(child) then cs.nat_w,cs.nat_h=tonumber(n.nw),tonumber(n.nh) end
   if expand_override or not L.floating(child) then cs.expand=tonumber(n.expand) end
   local cached,j=buf.synced,(i-1)*8
   cached[j+1],cached[j+2],cached[j+3]=tonumber(n.nw),tonumber(n.nh),tonumber(n.expand)
  end
 end end
 st.data.total_natural=tonumber(buf.box.total)
 counters.natural_calls=counters.natural_calls+1
 return tonumber(buf.out[0]),tonumber(buf.out[1]),tonumber(buf.out[2])
end
function M.place(st,L,vertical,Layout)
 if not (M.available and M.enabled) or #st.children<M.min_children then return false end
 for _,child in ipairs(st.children) do
  local cs=Element.state(child)
  if cs then local floating,ignore=L.floating(child)
   if floating and not ignore then Layout.placeFloating(child,cs,st) end
  end
 end
 local buf,count=prepare(st,L,vertical,true)
 assert(C.lunar_layout_place(buf.nodes,count,buf.box)~=0)
 for i,child in ipairs(st.children) do
  local cs=Element.state(child); local n=buf.nodes[i-1]
  if cs and n.flags%8<4 then
   cs.x,cs.y,cs.w,cs.h=tonumber(n.x),tonumber(n.y),tonumber(n.w),tonumber(n.h)
   Layout.placeChildren(child,cs)
  end
 end
 counters.place_calls=counters.place_calls+1
 return true
end
return M
