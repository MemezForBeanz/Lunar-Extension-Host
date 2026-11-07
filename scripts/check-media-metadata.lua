-- Opt-in live keyless metadata check through the native host HTTP/TLS stack.
local root=os.getenv('LUNAR_REPO') or '.'
package.path=root..'/extensions/media/?.lua;'..root..'/src/lua/?.lua;'..root..'/vendor/luasec/src/?.lua;'..root..'/vendor/luasocket/src/?.lua;'..root..'/vendor/luarocks-tree/share/lua/5.1/?.lua;'..root..'/vendor/luarocks-tree/share/lua/5.1/?/init.lua;'..root..'/vendor/copas/?.lua;'..package.path
local Client=require('libs.metaclient');local http=require('core.lib.http');local socket=require('socket')
local client=Client.new({http=function(request,done) assert(not request.headers.Authorization,'Keyless check must never send a credential');request.cafile=root..'/build/win/bin/certs/cacert.pem';done(http.request(request)) end})
local function await(start)
 local result,why,finished;start(function(value,problem) result,why,finished=value,problem,true end)
 local deadline=os.time()+35
 while not finished and os.time()<deadline do client:tick();socket.sleep(0.1) end
 return result,why or (not finished and 'timed out' or nil)
end
for _,entry in ipairs({{'cinemeta','movie','Titanic'},{'tvmaze','show','Under the Dome'},{'kitsu','show','Cowboy Bebop'},{'jikan','show','Cowboy Bebop'},{'imdbot','movie','Titanic'}}) do
 local provider,work=entry[1],{kind=entry[2],title=entry[3]}
 local rows,why=await(function(done) client:search(provider,work,nil,done) end)
 if not rows or not rows[1] then print(provider..': unavailable - '..tostring(why or 'no results'))
 else
  print(provider..': search returned '..#rows..' titles')
  if provider~='imdbot' then
   local facts,problem=await(function(done) client:details(provider,work,rows[1].id,done) end)
   if facts then print(provider..': details '..facts.external_id..'; poster='..tostring(facts.poster_url~=nil)..'; description='..tostring(facts.overview~=nil))
   else print(provider..': details unavailable - '..tostring(problem)) end
   if provider=='cinemeta' or provider=='tvmaze' then assert(facts and facts.title and facts.poster_url,problem or 'Default provider details failed') end
  end
 end
 if provider=='cinemeta' or provider=='tvmaze' then assert(rows and rows[1],why or 'Default provider search failed') end
end
client:close()
