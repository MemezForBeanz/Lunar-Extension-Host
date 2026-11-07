-- Identical client ships inside the GUI and server extensions. Each calls providers directly.
local db=require('libs.metadb')
local json=require('cjson')
local M={};local Client={};Client.__index=Client
function M.new(opts)
 return setmetatable({http=assert(opts.http),get_secret=opts.get_secret,now=opts.now or os.time,queue={},cache={},order={},bytes=0,next_at={},blocked={},busy=false},Client)
end
function Client:secret(name)
 local v=self.get_secret and self.get_secret(name);return type(v)=='string' and v~='' and v or nil
end
function Client:providers()
 local out={};for _,p in ipairs(db.providers) do local row={};for k,v in pairs(p) do row[k]=v end;row.configured=p.keyless or self:secret(p.id=='tmdb' and 'tmdb_token' or 'tvdb_key')~=nil;out[#out+1]=row end;return out
end
function Client:request(provider,op,work,value,done)
 local url,why=db.request(provider,op,work,value);if not url then return done(nil,why) end
 if self.closed then return done(nil,'Metadata client is closed.') end
 local key=url;local cached=self.cache[key]
 if cached and cached.expires>self.now() then return done(cached.body) end
 if #self.queue>=24 then return done(nil,'Metadata queue is full; try again shortly.') end
 self.queue[#self.queue+1]={provider=provider,url=url,done=done,key=key,ttl=op=='search' and 3600 or 86400}
 self:tick()
end
function Client:search(provider,work,query,done)
 self:request(provider,'search',work,query,function(body,why,retry) if not body then return done(nil,why,retry) end;local rows,err=db.results(provider,work.kind,body);done(rows,err) end)
end
function Client:details(provider,work,id,done)
 self:request(provider,'details',work,id,function(body,why,retry) if not body then return done(nil,why,retry) end;local facts,err=db.details(provider,work.kind,id,body);done(facts,err) end)
end
function Client:_fetch(job,headers,done,body)
 self.http({url=job.url,method=body and 'POST' or 'GET',body=body,headers=headers,same_origin=job.provider=='tmdb' or job.provider=='tvdb',timeout=15,max_bytes=2*1024*1024},function(response)
  if self.closed then return end
  local code=response and response.status
  if not response or not response.ok then
   local retry=tonumber(response and response.headers and (response.headers['retry-after'] or response.headers['Retry-After']))
   retry=math.min(math.max(retry or (code==429 and 60 or 5),1),3600)
   self.next_at[job.provider]=self.now()+retry
   if code==401 or code==403 then self.blocked[job.provider]=self:secret(job.provider=='tmdb' and 'tmdb_token' or 'tvdb_key');if job.provider=='tvdb' then self.tvdb_token=nil end end
   return done(nil,job.provider..(code and ' answered HTTP '..code or ' could not be reached'),retry)
  end
  if type(response.body)~='string' or #response.body>2*1024*1024 then return done(nil,'Provider response was too large.') end
  done(response.body)
 end)
end
function Client:tick()
 if self.closed or self.busy then return end
 local pos;for i,j in ipairs(self.queue) do if self.now()>=(self.next_at[j.provider] or 0) then pos=i;break end end
 if not pos then return end
 local job=table.remove(self.queue,pos);self.busy=true
 local function finish(body,why,retry)
  self.busy=false;self.next_at[job.provider]=math.max(self.next_at[job.provider] or 0,self.now()+(job.provider=='jikan' and 2 or 1))
  if body then
   if not self.cache[job.key] then self.order[#self.order+1]=job.key else self.bytes=self.bytes-#self.cache[job.key].body end
   self.cache[job.key]={body=body,expires=self.now()+job.ttl};self.bytes=self.bytes+#body
   while #self.order>128 or self.bytes>8*1024*1024 do local key=table.remove(self.order,1);self.bytes=self.bytes-#self.cache[key].body;self.cache[key]=nil end
  end
  job.done(body,why,retry)
 end
 local headers={Accept=job.provider=='kitsu' and 'application/vnd.api+json' or 'application/json',['User-Agent']='Lunar-Media/0.2 (metadata)',Connection='close'}
 if job.provider=='tmdb' or job.provider=='tvdb' then
  local credential=self:secret(job.provider=='tmdb' and 'tmdb_token' or 'tvdb_key')
  if not credential then return finish(nil,'Configure your optional '..job.provider..' credential in local Settings.') end
  if self.blocked[job.provider]==credential then return finish(nil,'Update the rejected '..job.provider..' credential in local Settings.') end
  if job.provider=='tmdb' then headers.Authorization='Bearer '..credential
  elseif not self.tvdb_token or self.tvdb_key~=credential or self.now()>=(self.tvdb_until or 0) then
   local login={provider='tvdb',url='https://api4.thetvdb.com/v4/login'}
   local payload={apikey=credential,pin=self:secret('tvdb_pin')};headers['Content-Type']='application/json'
   return self:_fetch(login,headers,function(body,why,retry)
    local data=body and db.decode(body);local token=data and type(data.data)=='table' and data.data.token
    if type(token)~='string' or token=='' then return finish(nil,why or 'TheTVDB login failed.',retry) end
    self.tvdb_token,self.tvdb_key,self.tvdb_until=token,credential,self.now()+20*86400
    self.busy=false;table.insert(self.queue,1,job);self.next_at.tvdb=self.now()+1
   end,json.encode(payload))
  else headers.Authorization='Bearer '..self.tvdb_token end
 end
 self:_fetch(job,headers,finish)
end
function Client:close() self.closed=true;self.queue={};self.cache={};self.tvdb_token=nil end
return M
