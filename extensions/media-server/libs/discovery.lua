--- On-demand discovery and lazy stream extraction, owned by the server.
local cjson=require('cjson')
local Web=require('libs.websources')
local Providers=require('libs.providers')
local D={};D.__index=D
local M={TTL=300,MAX_JOBS=24,MAX_BYTES=2*1024*1024,TIMEOUT=45}
function M.new(opts)
 return setmetatable({http=opts.http,spawn=opts.spawn,extractor=opts.extractor,now=opts.now or os.time,
  providers=opts.providers,jobs={},queue={},serial=0,active=0,cache={},closed=false},D)
end
local function escape(s) return (s:gsub('[^%w%-._~]',function(c)return string.format('%%%02X',c:byte())end)) end
function D:_finish(job,result,error)
 if self.closed or job.cancelled then return end
 job.result,job.error,job.state=result,error,error and 'failed' or 'ready'
 job.finished=self.now()
 if result and job.cache_key then self.cache[job.cache_key]={at=self.now(),result=result} end
end
function D:_prune()
 for id,job in pairs(self.jobs) do
  if self.now()-job.created>M.TTL and job.state~='running' then
   self.jobs[id]=nil
   if job.done then job.done(nil,'Discovery request expired.');job.done=nil end
  end
 end
 local queue={}
 for _,job in ipairs(self.queue) do if self.jobs[job.id] then queue[#queue+1]=job end end
 self.queue=queue
end
function D:_new()
 self:_prune()
 local count=0
 for _ in pairs(self.jobs) do count=count+1 end
 if count>=M.MAX_JOBS then return nil,'Too many discovery requests; try again shortly.' end
 self.serial=self.serial+1
 local job={id=tostring(self.serial),state='queued',created=self.now()};self.jobs[job.id]=job
 return job
end
function D:begin(body)
 if type(body)~='table' or type(body.provider)~='string' then return nil,'Choose a provider.' end
 local provider
 for _,p in ipairs(self.providers()) do if p.id==body.provider then provider=p;break end end
 if not provider or (provider.kind~='website' and provider.kind~='archive') then return nil,'This provider does not support discovery.' end
 local query=body.query or '';local page=tonumber(body.page) or 1
 if type(query)~='string' or #query>200 or page<1 or page>100 or page~=math.floor(page) then return nil,'Invalid search or page.' end
 local request,why
 if provider.kind=='archive' then
  request,why=Providers.request(provider,{})
  if request then
   request.url=request.url:gsub('&rows=200','&rows=50&page='..page)
   if query~='' then request.url=request.url:gsub('&fl','+AND+'..escape(query)..'&fl',1) end
  end
 else request,why=Web.request(provider,query,page,body.url) end
 if not request then return nil,why end
 local job,problem=self:_new();if not job then return nil,problem end
 job.provider,job.query,job.page,job.request,job.details=provider,query,page,request,body.details==true
 job.cache_key=provider.id..':'..request.url..':'..tostring(job.details)
 local cached=self.cache[job.cache_key]
 if cached and self.now()-cached.at<M.TTL then self:_finish(job,cached.result) else self.queue[#self.queue+1]=job end
 return {id=job.id,state=job.state}
end
function D:poll(id)
 self:_prune()
 local job=self.jobs[tostring(id)]
 if not job then return nil end
 return {id=job.id,state=job.state,error=job.error,result=job.result,provider=job.provider and job.provider.id}
end
function D:entry(id,key)
 self:_prune()
 local job=self.jobs[tostring(id)]
 if not job or job.state~='ready' then return nil,'Discovery has not completed.' end
 for _,entry in ipairs(job.result.items or {}) do if entry.key==key then return entry,job.provider end end
 return nil,'This title is not in these search results.'
end
function D:resolve(address,done)
 if not Web.web(address) then return done(nil,'Invalid video page address.') end
 local job,why=self:_new();if not job then return done(nil,why) end
 job.resolve=true;job.request={url=address};job.done=done
 self.queue[#self.queue+1]=job
 return job.id
end
function D:cancel(id)
 local job=self.jobs[tostring(id)]
 if not job then return false end
 job.cancelled=true;job.done=nil;self.jobs[tostring(id)]=nil
 if self.extracting and self.extracting.job==job then
  self.extracting.process:kill();self.extracting.process:close();self.extracting=nil
 end
 self:_prune()
 return true
end
function D:_extract(job)
 local executable=self.extractor and self.extractor()
 if not executable then return self:_resolved(job,nil,'Video extractor is being prepared, or is unavailable. Check server runtime status.') end
 local process,why=self.spawn({executable,'--ignore-config','--no-warnings','--no-progress','--skip-download',
  '--dump-single-json','--no-playlist','--socket-timeout','20','--retries','1','--extractor-retries','1',
  '-f','best[vcodec!=none][acodec!=none]/best','--',job.request.url})
 if not process then return self:_resolved(job,nil,tostring(why)) end
 self.extracting={job=job,process=process,started=self.now(),output={},bytes=0,error={}}
end
function D:_resolved(job,result,why)
 self:_finish(job,result,why)
 if job.done then job.done(result,why);job.done=nil end
end
function D:tick()
 if self.closed then return end
 self:_prune()
 for key,cached in pairs(self.cache) do if self.now()-cached.at>M.TTL then self.cache[key]=nil end end
 local run=self.extracting
 if run then
  for _,stream in ipairs({'stdout','stderr'}) do
   local chunk=run.process:read(stream)
   while chunk and chunk~='' do
    run.bytes=run.bytes+#chunk
    if run.bytes<=M.MAX_BYTES then local parts=stream=='stdout' and run.output or run.error;parts[#parts+1]=chunk end
    if run.bytes>M.MAX_BYTES then break end
    chunk=run.process:read(stream)
   end
  end
  local code=run.process:poll();local timeout=self.now()-run.started>M.TIMEOUT
  if code~=nil or timeout or run.bytes>M.MAX_BYTES then
   if code==nil then run.process:kill() end
   run.process:close();self.extracting=nil
   local ok,data=pcall(cjson.decode,table.concat(run.output))
   if not timeout and run.bytes<=M.MAX_BYTES and code==0 and ok and type(data)=='table' and Web.web(data.url) then
    local headers={}
    for name,value in pairs(type(data.http_headers)=='table' and data.http_headers or {}) do
     if type(name)=='string' and (name:lower()=='referer' or name:lower()=='user-agent' or name:lower()=='origin') and type(value)=='string' and not value:find('[\r\n]') then
      headers[#headers+1]=name..': '..value
     end
    end
    self:_resolved(run.job,{url=data.url,headers=headers,expires_at=self.now()+120})
   else self:_resolved(run.job,nil,timeout and 'Video extraction timed out.' or
     (table.concat(run.error):sub(1,600)~='' and Web.text(table.concat(run.error)):sub(1,600) or 'This website or video host is not supported by the extractor.')) end
  end
 end
 if self.active>=2 or #self.queue==0 then return end
 local job=self.queue[1]
 if job.extract then
  if self.extracting then return end
  table.remove(self.queue,1);self:_extract(job);return
 end
 table.remove(self.queue,1);job.state='running';self.active=self.active+1
 local request=job.request;request.timeout=20;request.max_bytes=M.MAX_BYTES
 self.http(request,function(response,why)
  self.active=self.active-1
  if self.closed or job.cancelled then return end
  if not response or not response.ok then
   local problem=response and ('Website returned HTTP '..tostring(response.status)..'.') or tostring(why or 'No response.')
   if job.resolve then self:_resolved(job,nil,problem) else self:_finish(job,nil,problem) end
   return
  end
  local text=response.body or ''
  if job.resolve then
   if Web.unavailable(text) then return self:_resolved(job,nil,'The video host reports that this video is unavailable.') end
   local stream=Web.stream(text,request.url)
   if stream then return self:_resolved(job,{url=stream,headers={'Referer: '..request.url},expires_at=self.now()+120}) end
   local embed=Web.embed(text,request.url)
   if embed and embed~=request.url and (job.followups or 0)<2 then
    job.followups=(job.followups or 0)+1
    job.request={url=embed,headers={Referer=request.url}}
    self.queue[#self.queue+1]=job;return
   end
   job.extract=true;self.queue[#self.queue+1]=job;return
  end
  local result
  if job.provider.kind=='archive' then result={items=Providers.parseArchive(text),has_more=true}
  else result=Web.parse(text,request.url,job.provider,job.query,job.details,job.context) end
  if result.followup and not job.followup_done then
   local followup=result.followup;result.followup=nil
   local validated=Web.request(job.provider,'',1,followup.url)
   if not validated then return self:_finish(job,nil,'The source returned an invalid episode address.') end
   job.followup_done=true;job.context=result;job.request=validated
   self.queue[#self.queue+1]=job;return
  end
  result.page=job.page
  self:_finish(job,result)
 end)
end
function D:close()
 self.closed=true
 if self.extracting then self.extracting.process:kill();self.extracting.process:close();self.extracting=nil end
 self.queue={};self.jobs={};self.cache={}
end
return M
