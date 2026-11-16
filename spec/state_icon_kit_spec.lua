local Kit=require("core.ui.Kit")
local StateIcon=require("core.ui.StateIcon")
describe("Kit state icons",function()
 local iup
 before_each(function()
  StateIcon.bindDirector(nil)
  iup={DEFAULT=-2,flatbutton=function(t) return t end,
   SetAttribute=function(w,k,v) w[k]=v end, GetAttribute=function(w,k) return w[k] end}
 end)
 it("returns a run controller alongside the original button",function()
  local called=0
  local button,icon=Kit.button(iup,{title="Run",state_icon="run",action=function() called=called+1 end})
  assert.equals("Run",button.TITLE); assert.equals("ready",icon:state())
  button:flat_action(); assert.equals(1,called)
  icon:set("failed"); assert.equals("failed",icon:state()); icon:destroy()
 end)
 it("confirms a copy only when its action succeeds",function()
  local ok=false
  local button,icon=Kit.copyButton(iup,{title="Copy",action=function() return ok end})
  button:flat_action(); assert.equals("ready",icon:state())
  ok=true; button:flat_action(); assert.equals("copied",icon:state()); icon:destroy()
 end)
 it("keeps disclosure callbacks and chevrons in step",function()
  local changed
  local button,icon=Kit.disclosure(iup,{title="Advanced",on_change=function(open) changed=open end})
  button:flat_action(); assert.is_true(changed); assert.equals("open",icon:state())
  button:flat_action(); assert.is_false(changed); assert.equals("closed",icon:state()); icon:destroy()
 end)
end)
