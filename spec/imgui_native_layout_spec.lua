local R=require('core.imgui.Runtime')
local Null=require('core.imgui.backend.Null')
local Element=require('core.imgui.Element')
local Classes=require('core.imgui.Classes')
local Layout=require('core.imgui.Layout')
local Native=require('core.imgui.NativeLayout')
local iup=require('core.imgui.iup')

describe('native box layout differential',function()
 before_each(function()
  Native.min_children=0
  R.init(Null.new())
  local dll=os.getenv('LUNAR_LAYOUT_TEST_DLL')
  if dll then assert.is_true(Native.testLibrary(dll)) end
  Classes.define{name='kernel_leaf',children=0,natural=function(_,s)
   return tonumber(s.attrs.TESTWIDTH) or 20,tonumber(s.attrs.TESTHEIGHT) or 12
  end}
 end)
 after_each(function() Native.enabled=true; Native.min_children=16 end)
 local function snapshot(root)
  local result={}
  local function walk(e)
   local s=Element.state(e)
   result[#result+1]={s.classname,s.nat_w,s.nat_h,s.expand,s.x,s.y,s.w,s.h}
   for _,c in ipairs(s.children) do walk(c) end
  end
  walk(root); return result
 end
 local function tree(seed)
  math.randomseed(seed)
  local function make(depth)
   if depth==0 or math.random(3)==1 then
    return Element.new('kernel_leaf',{
     TESTWIDTH=tostring(math.random(10,90)),TESTHEIGHT=tostring(math.random(5,50)),
     EXPAND=({'NO','YES','HORIZONTAL','VERTICAL'})[math.random(4)],
     EXPANDWEIGHT=tostring(math.random(1,4)/2),
     MINSIZE=math.random(0,15)..'x'..math.random(0,10),
     MAXSIZE=math.random(80,160)..'x'..math.random(50,100),
     FLOATING=math.random(8)==1 and 'IGNORE' or 'NO',
    })
   end
   local kids={}
   for _=1,math.random(1,5) do kids[#kids+1]=make(depth-1) end
   kids.GAP=tostring(math.random(0,7)); kids.MARGIN=math.random(0,5)..'x'..math.random(0,5)
   kids.HOMOGENEOUS=math.random(4)==1 and 'YES' or 'NO'
   kids.NORMALIZESIZE=({'NONE','BOTH','HORIZONTAL','VERTICAL'})[math.random(4)]
   kids.ALIGNMENT=({'ACENTER','ARIGHT','ABOTTOM','ALEFT'})[math.random(4)]
   return (math.random(2)==1 and iup.hbox or iup.vbox)(kids)
  end
  return iup.dialog{make(3),SHRINK=seed%2==0 and 'YES' or 'NO'}
 end
 it('matches Lua geometry, natural sizes and expansion for randomized constrained trees',function()
  if not Native.available then pending('build lunar_layout.cpp as DLL and set LUNAR_LAYOUT_TEST_DLL'); return end
  for seed=1,160 do
   Native.enabled=false
   local a=tree(seed); Layout.run(a,100+seed%7*80,80+seed%9*35)
   local expected=snapshot(a)
   Native.enabled=true
   local b=tree(seed); Layout.run(b,100+seed%7*80,80+seed%9*35)
   assert.same(expected,snapshot(b),'seed '..seed)
   iup.Destroy(a); iup.Destroy(b)
  end
  assert.is_true(Native.stats().place_calls>0)
 end)
 it('reuses clean measurement/placement and invalidates changes and inherited font state',function()
  local a=iup.label{TITLE='first'}
  local root=iup.dialog{iup.vbox{a}}
  Layout.run(root,400,300); Layout.stats(true)
  Layout.run(root,400,300)
  assert.equal(0,Layout.stats().measured)
  assert.equal(0,Layout.stats().placed)
  iup.SetAttribute(a,'TITLE','a significantly longer title')
  Layout.run(root,400,300)
  assert.is_true(Layout.stats().measured>0)
  assert.is_true(Element.state(a).nat_w>20)
  iup.SetAttribute(root,'FONT','Segoe UI, -24')
  assert.is_true(Element.state(a).data.natural_dirty)
 end)
 it('keeps explicit updates and repeated command setters observable',function()
  local canvas=iup.canvas{RASTERSIZE='40x40'}
  local n=0; canvas.action=function() n=n+1 end
  local root=iup.dialog{iup.vbox{canvas}}
  iup.Show(root); R.frame()
  local before=n
  iup.Update(canvas); R.frame()
  assert.equal(before+1,n)
  local text=iup.text{MULTILINE='YES',VALUE='a'}
  iup.SetAttribute(text,'APPEND','b'); iup.SetAttribute(text,'APPEND','b')
  assert.equal('a\nb\nb',iup.GetAttribute(text,'VALUE'))
 end)
 it('restores intrinsic sizes after normalizing and invalidates moved inherited fonts',function()
  local a=iup.label{TITLE='small'}; local b=iup.label{TITLE='much longer'}
  local group=iup.hbox{a,b,NORMALIZESIZE='HORIZONTAL'}
  local root=iup.dialog{group,FONT='Segoe UI, -24'}
  Layout.run(root,500,300)
  assert.equal(Element.state(a).nat_w,Element.state(b).nat_w)
  local intrinsic=Layout.natural(a)
  assert.is_true(intrinsic<Element.state(b).nat_w)
  Layout.run(root,600,300)
  assert.equal(Element.state(a).nat_w,Element.state(b).nat_w)
  iup.SetAttribute(group,'NORMALIZESIZE','NONE'); Layout.run(root,500,300)
  assert.equal(intrinsic,Element.state(a).nat_w)
  iup.Detach(a)
  local small=iup.dialog{iup.vbox{a},FONT='Segoe UI, -10'}
  Layout.run(small,500,300)
  assert.is_true(Element.state(a).nat_w<intrinsic)
 end)
 it('invalidates layout and canvas recordings when the window DPI changes',function()
  local B=Null.new();R.init(B)
  local label=iup.label{TITLE='DPI dependent text',FONT='Segoe UI, 12'}
  local paints=0
  local canvas=iup.canvas{RASTERSIZE='50x30',action=function()paints=paints+1 end}
  local root=iup.dialog{iup.vbox{label,canvas},RASTERSIZE='400x300'}
  iup.Show(root);R.frame()
  local width=Element.state(label).nat_w
  local before=paints
  B.dpi_scale=1.5;R.frame()
  assert.equal(144,require('core.imgui.Fonts').dpi)
  assert.is_true(Element.state(label).nat_w>width)
  assert.equal(before+1,paints)
  R.frame();assert.equal(before+1,paints)
 end)
end)
