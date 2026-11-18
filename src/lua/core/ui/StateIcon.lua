--- Named-state SVG icons. All clocks belong to MotionDirector; no private timers.
local Reactor = require("core.ui.ThemeReactor")
local Animated = require("core.ui.AnimatedIcon")
local M = {}
M.__index = M
M.FRAMES = 8
local defs = {}
local instances = setmetatable({}, { __mode = "k" })
local director
local frames, serial = {}, 0
local function cached_frame(self, key, svg)
 self.cache_key=key
 serial=serial+1
 local item=frames[key]
 if item then item.used=serial; return item.path end
 local path_name=self.frame(key,svg())
 frames[key]={path=path_name,used=serial,kind=self.kind}
 local count,oldest,oldkey=0,math.huge
 for k,v in pairs(frames) do if v.kind == self.kind then
  count=count+1
  local pinned=false
  for icon in pairs(instances) do if icon.cache_key == k then pinned=true; break end end
  if not pinned and v.used < oldest then oldest,oldkey=v.used,k end
 end end
 -- 48 RGBA frames at 20px consume 75KB, leaving room for both sizes.
 if count>48 and oldkey then
  local old=frames[oldkey]; frames[oldkey]=nil
  local V=package.loaded["core.ui.VectorIcon"]
  if V and V.releasePath then V.releasePath(self.iup,old.path) end
 end
 return path_name
end

-- Point/path data uses Carbon's 32-unit coordinate system and square caps.
M.paths = {
 play = "M10 6L26 16L10 26Z", stop = "M8 8H24V24H8Z",
 check = "M5 16L12 23L27 8", warning = "M16 4L29 27H3ZM16 11V19M16 22V24",
 cross = "M8 8L24 24M24 8L8 24", queued = "M8 10H24M8 16H24M8 22H20",
 skipped = "M7 7L23 16L7 25ZM25 7V25", copy = "M11 10H26V28H11ZM6 22H4V4H20V6",
 save = "M5 4H23L28 9V28H4V4ZM10 4V12H22V4M10 28V19H22V28",
 plug = "M8 6V12M16 6V12M5 12H19V16L15 20H9L5 16ZM12 20V27M23 5V19M20 8H26",
 refresh = "M26 13A10 10 0 1 0 25 23M26 5V13H18", chevron = "M12 6L22 16L12 26",
 pin = "M11 4H21L20 13L25 20H7L12 13ZM16 20V29",
 favourite = "M16 3L20 12L30 13L23 20L25 30L16 25L7 30L9 20L2 13L12 12Z",
 panel = "M4 5H28V27H4ZM18 5V27", idle = "M6 16H26",
}
local function state(glyph, role, loop) return { glyph = glyph, role = role, loop = loop } end
function M.register(kind, def)
 assert(type(kind) == "string" and type(def.states) == "table" and def.states[def.initial], "invalid state icon definition")
 defs[kind] = def
end
local function register(kind, initial, states) M.register(kind, { initial = initial, states = states }) end
register("run", "ready", { ready=state("play"), working=state("stop", nil, "icon_spin"), stopping=state("stop"), succeeded=state("check", "success"), failed=state("warning", "error") })
register("row", "queued", { queued=state("queued"), running=state("stop", nil, "icon_spin"), ok=state("check", "success"), warning=state("warning", "warning"), failed=state("cross", "error"), skipped=state("skipped", "muted") })
register("connection", "offline", { offline=state("plug", "muted"), connecting=state("plug", nil, "icon_connect"), connected=state("plug", "success"), error=state("warning", "error") })
register("refresh", "idle", { idle=state("refresh"), checking=state("refresh", nil, "icon_spin"), current=state("check", "success"), available=state("refresh", "info"), failed=state("warning", "error") })
register("copy", "ready", { ready=state("copy"), copied=state("check", "success") })
register("save", "clean", { clean=state("save"), modified=state("save"), saving=state("save", nil, "icon_spin"), saved=state("check", "success"), failed=state("warning", "error") })
register("chevron", "closed", { closed=state("chevron"), open=state("chevron") })
register("activity", "idle", { idle=state("idle"), busy=state("idle", nil, "icon_activity"), attention=state("idle", "warning") })
for _, kind in ipairs({ "pin", "favourite", "panel" }) do register(kind, "off", { off=state(kind), on=state(kind) }) end
function M.kinds() local out={} for k in pairs(defs) do out[#out+1]=k end table.sort(out) return out end
function M.definition(kind) return defs[kind] end
function M.bindDirector(d) director = d end

local function path(d, fill, opacity, transform)
 return string.format('<path d="%s" fill="%s" stroke="black" stroke-width="2" stroke-linecap="square" stroke-linejoin="miter" opacity="%.3f" transform="%s"/>', d, fill or "none", opacity or 1, transform or "")
end
local function fade(body, opacity)
 -- NanoSVG resolves opacity per shape; a path's explicit opacity overrides its group.
 body = body:gsub(' opacity="[%d%.]+"', '')
 local attribute = ' opacity="' .. opacity .. '" '
 return (body:gsub('<path ', '<path' .. attribute):gsub('<circle ', '<circle' .. attribute))
end
local function glyph(kind, name, phase, progress)
 local def = defs[kind].states[name]
 local d = M.paths[def.glyph] or def.path
 local transform = ""
 if kind == "chevron" then transform = "rotate(" .. (name == "open" and 90 or 0) .. " 16 16)" end
 if kind == "refresh" and name == "checking" then transform = "rotate(" .. phase * 360 .. " 16 16)" end
 if kind == "activity" and name == "busy" then return Animated.barsSVG(phase):match("<path.-/></svg>"):gsub("</svg>", "") end
 local out = path(d, (name == "on" and kind ~= "panel") and "black" or "none", 1, transform)
 if kind == "connection" and name ~= "error" then
  local gap = name == "connected" and 0 or 4
  out = path("M5 8H12V24H5M12 12H16M12 20H16", "none", 1, "translate(" .. -gap .. " 0)")
   .. path("M27 8H20V24H27M16 12H20M16 20H20", "none", 1, "translate(" .. gap .. " 0)")
 end
 if kind == "panel" and name == "on" then out=out .. path("M18 5H28V27H18Z","black") end
 if (kind == "save" and name == "modified") or name == "available" or name == "attention" or (kind == "connection" and name == "connected") then
  if kind == "connection" then
   out = out .. '<circle cx="25" cy="7" r="5" fill="none" stroke="black" stroke-width="1"/>' .. path("M22 7L24 9L28 5")
  else out = out .. '<circle cx="25" cy="7" r="4"/>' end
 end
 if def.loop and kind ~= "activity" and kind ~= "refresh" then
  local start = phase * math.pi * 2 - math.pi / 2
  local span = (progress or 0.7) * math.pi * 2
  local x,y = 16+14*math.cos(start),16+14*math.sin(start)
  local ex,ey = 16+14*math.cos(start+span),16+14*math.sin(start+span)
  if progress == 1 then out=out .. '<circle cx="16" cy="16" r="14" fill="none" stroke="black" stroke-width="2"/>'
  elseif progress ~= 0 then out = out .. path(string.format("M%.3f %.3f A14 14 0 %d 1 %.3f %.3f", x,y,span>math.pi and 1 or 0,ex,ey)) end
 end
 return out
end
--- Pure, quantised frame geometry, also used by the contact sheet.
function M.svg(kind, from, to, t, phase, progress)
 t = math.max(0, math.min(1, t or 1))
 local body
 if kind == "chevron" then
  local a,b = from == "open" and 90 or 0, to == "open" and 90 or 0
  body = path(M.paths.chevron, "none", 1, "rotate(" .. (a+(b-a)*t) .. " 16 16)")
 elseif kind == "run" and ((from == "ready" and to == "working") or (from == "working" and to == "ready")) then
  local amount=to == "working" and t or 1-t
  local points=Animated.lerpPoints({{10,6},{26,16},{10,26},{10,16}},{{8,8},{24,8},{24,24},{8,24}},amount)
  local data={}
  for i,p in ipairs(points) do data[#data+1]=string.format("%s%.3f %.3f",i==1 and "M" or "L",p[1],p[2]) end
  body=path(table.concat(data," ") .. "Z")
  if to == "working" then body=body .. fade(glyph(kind,to,phase or 0,progress):match('(<path d="M[%d%.%-]+ [%d%.%-]+ A.-/>)') or "",t) end
 elseif kind == "connection" and (from == "offline" or from == "connecting") and to == "connected" and t < 1 then
  local gap = 4 * (1-t)
  body = path("M5 8H12V24H5M12 12H16M12 20H16", "none", 1, "translate(" .. -gap .. " 0)")
   .. path("M27 8H20V24H27M16 12H20M16 20H20", "none", 1, "translate(" .. gap .. " 0)")
 elseif to == "succeeded" and kind == "run" and t>0.5 and t<1 then
  t = (t-.5)*2
  local x,y
  if t<0.35 then x,y=5+7*t/0.35,16+7*t/0.35 else x,y=12+15*(t-0.35)/0.65,23-15*(t-0.35)/0.65 end
  body=path(t<0.35 and string.format("M5 16L%.3f %.3f",x,y) or string.format("M5 16L12 23L%.3f %.3f",x,y))
 elseif from == to or t == 1 then body = glyph(kind,to,phase or 0,progress)
 elseif t == 0 then body = glyph(kind,from,0,progress)
 else
  local entering = t >= .5
  local amount = entering and (t-.5)*2 or 1-t*2
  local scale = .8+.2*amount
  body = '<g transform="translate(16 16) scale(' .. scale .. ') translate(-16 -16)">' .. fade(glyph(kind,entering and to or from,phase or 0,progress),amount) .. '</g>'
 end
 return '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">' .. body .. '</svg>'
end

local function visible(self)
 if self.dead then return false end
 if self.visible then return self.visible() end
 local w = self.target
 if not w then return false end
 local R = package.loaded["core.imgui.Runtime"]
 if R then return R.isVisible(w) and self.iup.GetAttribute(self.iup.GetDialog(w), "PLACEMENT") ~= "MINIMIZED" end
 return self.iup.GetAttribute(w,"VISIBLE") == "YES" and self.iup.GetAttribute(w,"MAPPED") ~= "NO"
end
function M.new(iup, opts)
 opts = opts or {}
 local def = assert(defs[opts.kind], "unknown state icon kind")
 local self = setmetatable({ iup=iup, kind=opts.kind, size=opts.size or 16, role=opts.role or "neutral", animate=opts.animate,
  visible=opts.visible, paint=opts.paint, frame=opts.frame or Animated.frame, current=def.initial, from=def.initial, t=1, phase=0 },M)
 instances[self]=true
 Reactor.register(self)
 if self.paint then self:_draw() end
 return self
end
function M:state() return self.current end
function M:widget()
 if not self.target then self:attach(self.iup.label({ RASTERSIZE=self.size .. "x" .. self.size, EXPAND="NO" })) end
 return self.target
end
function M:attach(button, attribute)
 self.target,self.attribute=button,attribute or "IMAGE"
 self:_draw()
 self:_resume()
 return self
end
function M:_draw()
 if self.dead then return end
 local t = math.floor(self.t*M.FRAMES+0.5)/M.FRAMES
 local phase = math.floor(self.phase*12)%12/12
 local progress = self.progress and math.floor(self.progress*16+0.5)/16
 local key = table.concat({"state-v9",self.kind,t == 1 and self.current or self.from,self.current,t,phase,progress or "ind"},"-")
 local path_name = cached_frame(self,key,function() return M.svg(self.kind,self.from,self.current,t,phase,progress) end)
 -- The first half fades the outgoing glyph; keep its semantic colour too.
 local shown = t < .5 and self.from or self.current
 local role = (self.role == "on-accent" or self.role == "on_accent") and "on_accent" or (defs[self.kind].states[shown].role or self.role)
 if role == "muted" then role="neutral" end
 if self.paint then self.paint(path_name, role) return end
 local V = require("core.ui.VectorIcon")
 if not V.available or not self.target then return end
 local handle = V.imageHandle(self.iup,{ path=path_name, size=self.size, color=V.roleColor(role) })
 if handle then self.iup.SetAttribute(self.target,self.attribute,handle) end
end
function M:_onThemeApply() self:_draw(); self:_resume() end
--- Request new raster geometry when a caller changes DPI or icon size.
function M:setSize(size) self.size=assert(tonumber(size)); self:_draw(); return self end
function M:_motion()
 return (self.animate or director) and (not director or director:enabled())
end
function M:_animate(spec)
 if self.animate then return self.animate(spec) end
 if director then return director:animate(spec) end
 spec.on_frame(spec.to or 1); if spec.on_done then spec.on_done(true) end
end
function M:_cancel()
 local h=self.handle self.handle=nil
 if h then h:cancel() end
end
local active_loops = 0
function M:_resume()
 local loop = defs[self.kind].states[self.current].loop
 if self.handle or not loop or not visible(self) or not self:_motion() or active_loops >= 4 or self.progress ~= nil then return end
 active_loops=active_loops+1
 local synchronous = true
 local handle = self:_animate({ role=loop, from=0,to=1,
  on_frame=function(v) if visible(self) then self.phase=v; self:_draw() else self:_cancel() end end,
  on_done=function(done)
   active_loops=active_loops-1; self.handle=nil
   if done and not synchronous then self:_resume() end
  end })
 synchronous=false
 if handle and not handle:done() then self.handle=handle end
end
function M:set(name, opts)
 assert(defs[self.kind].states[name], "unknown state: " .. tostring(name))
 opts=opts or {}
 if name == self.current and opts.progress == self.progress then self:_resume(); return self end
 self:_cancel()
 self.from,self.current,self.progress,self.phase = self.current,name,opts.progress and math.max(0,math.min(1,opts.progress)),0
 self.t=1
 if self:_motion() and visible(self) then
  local role = (name == "succeeded" or name == "saved" or name == "connected" or self.kind == "refresh") and "icon_settle" or (self.kind == "row" and "icon_row" or "icon_morph")
  local synchronous=true
  local h=self:_animate({ role=role,from=0,to=1,on_frame=function(v) self.t=v; self:_draw() end,
   on_done=function(done) self.handle=nil; if done and not synchronous then self:_settled() end end })
  synchronous=false
  if h and not h:done() then self.handle=h else self:_draw() end
 else self:_draw() end
 self:_resume()
 return self
end
function M:_settled()
 if (self.kind == "run" and self.current == "succeeded") or (self.kind == "copy" and self.current == "copied") then
  if not self:_motion() then return end
  self.handle=self:_animate({role="icon_hold",from=0,to=1,on_frame=function() end,on_done=function(done)
   self.handle=nil; if done then self:set("ready") end
  end})
 else self:_resume() end
end
function M:destroy() self.dead=true; self:_cancel(); instances[self]=nil; self.target=nil end

-- Visibility changes wake suspended loops on an existing UI frame, never a poll timer.
local R=package.loaded["core.imgui.Runtime"]
if R then R.preRoute[#R.preRoute+1]=function() for icon in pairs(instances) do
 if icon.handle and not visible(icon) then icon:_cancel(); icon.t=1 else icon:_resume() end
end end end
return M
