-- Exercise the actual native worker and cooperative scheduler in the host VM.
if not package.preload.socket then
 local root=LUNAR_SOURCE_DIR or '.'
 package.path=root..'/src/lua/?.lua;'..root..'/vendor/copas/?.lua;'
  ..root..'/vendor/luarocks-tree/share/lua/5.1/?.lua;'
  ..root..'/vendor/luarocks-tree/share/lua/5.1/?/init.lua;'..package.path
end
local socket=require('socket')
local resolver=require('native_resolver')
local async=require('core.lib.async')
local result={}
local out=assert(io.open(assert(arg[1]),'w'))
local ok,err=xpcall(function()
 local request=assert(resolver.start('localhost'))
 local deadline=socket.gettime()+2
 local state,addresses
 repeat state,addresses=resolver.poll(request); socket.sleep(.001)
 until state~='pending' or socket.gettime()>=deadline
 assert(state=='done' and #addresses>0,tostring(addresses))
 resolver.close(request); resolver.close(request)
 assert(resolver.poll(request)=='error')
 local cancelled=assert(resolver.start('localhost'))
 resolver.cancel(cancelled); assert(resolver.poll(cancelled)=='error')
 for _=1,20 do
  local pending=resolver.start('localhost')
  if pending then resolver.cancel(pending); resolver.close(pending) end
  assert(resolver.stats().active<=resolver.stats().limit)
 end
 deadline=socket.gettime()+2
 while resolver.stats().active>0 and socket.gettime()<deadline do socket.sleep(.001) end
 assert(resolver.stats().active==0,'cancelled worker did not release capacity after OS completion')
 result.native_worker=true
 assert(async.available,'cooperative scheduler is required')
 local server=assert(socket.bind('127.0.0.1',0))
 local _,port=server:getsockname()
 local done,connected,reason
 async.run(function() return async.probeTcp('localhost',port,1) end,function(success,value,why)
  assert(success); connected=value; reason=why; done=true
 end)
 deadline=socket.gettime()+3
 repeat async.pump(); socket.sleep(.001) until done or socket.gettime()>=deadline
 server:close(); assert(done and connected,'resolved numeric connection failed: '..tostring(reason))
 result.resolved_connect=true
 local original=async.resolver
 local closed,ticks=0,0
 async.resolver={start=function()return {}end,poll=function()return 'pending'end,
  cancel=function()closed=closed+1 end,close=function()end}
 done=false
 async.run(function() return async.probeTcp('deliberately-stalled.invalid',80,.03) end,function(success,value,why)
  assert(success and value==false and why=='timeout resolving host'); done=true
 end)
 async.run(function() for _=1,3 do ticks=ticks+1; async.sleep(.001) end end)
 deadline=socket.gettime()+2
 repeat async.pump(); socket.sleep(.001) until done or socket.gettime()>=deadline
 async.resolver=original
 assert(done and ticks>0 and closed==1,'stalled DNS blocked scheduler or leaked request')
 result.scheduler_ticks=ticks; result.deadline_cleanup=true
 if rawget(_G,'iup')==nil then
  assert(package.loaded['core.imgui.Runtime']==nil,'headless resolver imported the UI runtime')
  result.headless_isolation=true
 end
end,debug.traceback)
result.ok=ok; result.error=not ok and tostring(err) or nil
out:write(require('cjson').encode(result));out:close()
os.exit(ok and 0 or 1)
