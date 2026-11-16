-- Contact-sheet probe. Run ONLY with cap-ui.ps1 on its private desktop.
-- Reuse the capture harness's bootstrap and back-buffer writer, not screen capture.
local here=debug.getinfo(1,"S").source:gsub("^@",""):gsub("\\","/")
local root=assert(here:match("^(.*)/scripts/[^/]+$"))
local f=assert(io.open(root .. "/scripts/ui_capture.lua","r"))
local source=f:read("*a"); f:close()
local prefix=assert(source:match("^(.-)local whole_window"))
local probe=[=[
local StateIcon=require("core.ui.StateIcon")
local Kit=require("core.ui.Kit")
local L=require("core.lib.CarbonLayout")
local real=iup.MainLoop
iup.MainLoop=function()
 local kinds=StateIcon.kinds()
 local scenes={}
 for _,kind in ipairs(kinds) do
  local states={} for state in pairs(StateIcon.definition(kind).states) do states[#states+1]=state end table.sort(states)
  local scene
  for _,from in ipairs(states) do for _,to in ipairs(states) do if from~=to then
   if not scene or #scene.pairs==6 then scene={kind=kind,pairs={},number=#scenes+1}; scenes[#scenes+1]=scene end
   scene.pairs[#scene.pairs+1]={from,to}
  end end end
 end
 local index, sheet, tick=0,nil,0
 local timer=iup.timer({time=350})
 function timer:action_cb()
  tick=tick+1
  if tick<3 then return iup.DEFAULT end
  if sheet then
   save_bmp(window_of(sheet),out_dir .. "/icons-" .. scenes[index].kind .. "-" .. index .. ".bmp",false)
   iup.Destroy(sheet); sheet=nil
  end
  index=index+1
  local scene=scenes[index]
  if not scene then self.run="NO"; iup.ExitLoop(); return iup.CLOSE end
  local kind=scene.kind
  local def=StateIcon.definition(kind)
  local states={} for state in pairs(def.states) do states[#states+1]=state end table.sort(states)
  local body=iup.vbox({MARGIN=L.margin(5),GAP=L.gap(2)})
  iup.Append(body,iup.label({TITLE=kind .. " | each strip: 0%, 25%, 50%, 75%, 100%; 16px / 20px / 4x",THEMEROLE="section_title"}))
  local V=require("core.ui.VectorIcon")
  local Animated=require("core.ui.AnimatedIcon")
  for _,pair in ipairs(scene.pairs) do local from,to=pair[1],pair[2]
   local row=iup.hbox({GAP=L.gap(4),ALIGNMENT="ACENTER"})
   iup.Append(row,iup.label({TITLE=from .. " > " .. to,RASTERSIZE="230x",THEMEROLE="secondary_label"}))
   for _,size in ipairs({16,20,80}) do
    for step=0,4 do
     local path=Animated.frame("probe-v7-" .. kind .. "-" .. from .. "-" .. to .. "-" .. step,StateIcon.svg(kind,from,to,step/4,step/4))
     local role=def.states[to].role or "neutral"
     local image=V.imageHandle(iup,{path=path,size=size,color=V.roleColor(role)})
     iup.Append(row,iup.label({IMAGE=image,RASTERSIZE=size .. "x" .. size}))
    end
   end
   iup.Append(body,row)
  end
  local reference=iup.hbox({GAP=L.gap(5),iup.label({TITLE="Static Carbon: checkmark / copy / save / chevron--right"})})
  for _,name in ipairs({"checkmark","copy","save","chevron--right"}) do
   iup.Append(reference,iup.label({IMAGE=Kit.icon(iup,name,20,"neutral")}))
  end
  iup.Append(body,reference)
  sheet=iup.dialog({body,TITLE="State icons: " .. kind,RASTERSIZE="1600x760"})
  local tm=require("core.ui.ThemeReactor").themeManager()
  if tm then tm:_repaintSubtree(sheet,tm._active) end
  iup.ShowXY(sheet,0,0)
  iup.Refresh(sheet)
  return iup.DEFAULT
 end
 timer.run="YES"
 return real()
end
assert(dofile((LUNAR_SOURCE_DIR or ".") .. "/src/lua/core/main.lua") == nil or true)
]=]
assert(loadstring(prefix .. probe,"@" .. root .. "/scripts/ui_capture.lua"))()
