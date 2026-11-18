local ffi=require('ffi')
ffi.cdef[[ int SetEnvironmentVariableA(const char*, const char*); ]]
local B=require('core.imgui.backend.Native')
local result={}
local log=assert(io.open(assert(arg[1]),'w'))
local ok,err=xpcall(function()
 ffi.C.SetEnvironmentVariableA('LUNAR_RENDERER','auto')
 ffi.C.SetEnvironmentVariableA('LUNAR_TEST_DEVICE_FAILURE','all')
 local opened=B.open{title='failure check',w=320,h=200}
 assert(not opened,'fault injection needs a development build')
 assert(not B.renderer().ready)
 ffi.C.SetEnvironmentVariableA('LUNAR_TEST_DEVICE_FAILURE','hardware')
 assert(B.open{title='retry check',w=320,h=200})
 local info=B.renderer()
 assert(info.ready and info.active=='warp' and info.fallbacks>0)
 result.renderer=info
 for _=1,3 do
  B.frame_begin(); B.rect_filled(0,0,100,100,0xff00ff00,0,256); B.frame_end()
 end
 B.close()
 ffi.C.SetEnvironmentVariableA('LUNAR_TEST_DEVICE_FAILURE','hardware_pipeline')
 assert(B.open{title='pipeline fallback check',w=320,h=200})
 assert(B.renderer().ready and B.renderer().active=='warp')
 B.frame_begin();B.rect_filled(0,0,100,100,0xff00ff00,0,256);B.frame_end()
 B.close();result.pipeline_fallback=true
 ffi.C.SetEnvironmentVariableA('LUNAR_TEST_DEVICE_FAILURE',nil)
 result.failure_cleanup=true;result.fallback=true
end,debug.traceback)
result.ok=ok; result.error=not ok and tostring(err) or nil
log:write(require('cjson').encode(result));log:close()
os.exit(ok and 0 or 1)
