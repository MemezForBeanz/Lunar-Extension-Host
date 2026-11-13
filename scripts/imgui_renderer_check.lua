-- Integration check: recreate D3D device and preserve texture/UI state.
local B=require('core.imgui.backend.Native')
local json=require('cjson')
local out=assert(arg[1])
local log=assert(io.open(out..'.json','w'))
local report={}
local ok,err=xpcall(function()
 assert(B.open{title='Lunar renderer recovery check',w=640,h=400})
 report.before=B.renderer(); assert(report.before.ready)
 local tex=assert(B.texture(string.rep('\255\128\0\255',32*32),32,32))
 local popup=assert(B.window('popup_open',{title='Recovery popup',caption=true,border=true,resize=false,owned=true}))
 B.window('popup_place',popup,150,100,180,90,true,false,'Recovery popup')
 local function frames(file)
  for i=1,6 do
   local input=B.frame_begin()
   B.rect_filled(0,0,input.w,input.h,0xff202020,0,256)
   B.image(tex,100,100,132,132,0,0,1,1,0xffffffff)
   B.rect_filled(20,20,80,60,0xff00ffff,6,0)
   B.surface(popup)
   B.rect_filled(150,100,330,190,0xff202020,0,256)
   B.image(tex,160,110,192,142,0,0,1,1,0xffffffff)
   B.surface(0)
   if i==5 then B.screenshot(file) end
   B.frame_end()
  end
 end
 frames(out..'-before.bmp')
 assert(B.renderer_reset())
 report.after=B.renderer(); assert(report.after.ready and report.after.resets==report.before.resets+1)
 if report.before.requested=='hardware' or report.before.requested=='gpu' then
  assert(report.after.active=='hardware' or report.after.fallbacks>0)
 else assert(report.after.active=='warp') end
 assert(B.window('popup_ready',popup),'popup swap chain was not restored')
 frames(out..'-after.bmp')
 B.window('popup_close',popup); B.texture_free(tex); B.close()
 report.ok=true
end,debug.traceback)
report.error=not ok and tostring(err) or nil
log:write(json.encode(report));log:close()
os.exit(ok and 0 or 1)
