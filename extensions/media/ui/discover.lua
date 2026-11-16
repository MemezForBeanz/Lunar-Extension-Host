--- Browse sources without importing their whole catalog into the personal library.
local L=require('core.lib.CarbonLayout')
local Kit=require('core.ui.Kit')
local RowList=require('core.ui.RowList')
local FlatField=require('core.ui.FlatField')
local M={}
function M.new(ctx,opts)
 local iup=ctx.iup;local api={};local providers,items={},{}; local provider,selected,current
 local libraries=opts.libraries or {}
 local generation=0;local pending;local history={};local download_id;local downloads={};local download_wait=0
 local download_busy=false
 local page, save, add_menu, find
 local function search_state(working)
  if not find then return end
  iup.SetAttribute(find,'TITLE',working and 'Stop' or 'Search / Browse')
  if page and page.setRunState then page:setRunState(working and 'working' or 'ready') end
 end
 local activities={}
 local capture_connected
 local function selection()
  if page then page:openInspector(selected~=nil); Kit.show(iup,add_menu,selected~=nil,status) end
 end
 local query=FlatField.new(iup,{cue='Search titles, or paste a video webpage URL'})
 local status=Kit.statusLine(iup,'info','Choose a source to browse its catalog.')
 local description=iup.flatlabel({TITLE='',THEMEROLE='reading_muted',TEXTWRAP='YES',EXPAND='HORIZONTAL',RASTERSIZE='x38'})
 local download_info=iup.flatlabel({TITLE='',THEMEROLE='reading_muted',TEXTWRAP='YES',EXPAND='HORIZONTAL'})
 local function download_value(pos,field)
  local row=downloads[pos];if not row then return end
  if field=='TITLE' then return row.title or 'Download' end
  if field=='SECONDARY' then
   local total=tonumber(row.total_bytes) or 0
   local progress=total>0 and string.format(' · %d%%',math.min(100,math.floor((row.bytes or 0)*100/total))) or ''
   return tostring(row.state)..progress..(row.error and (': '..row.error) or '')
  end
 end
 local download_list=RowList.new(iup,{count=0,value=download_value,row_height=52,role='flatrows_plain',
  empty_title='No downloads',empty_hint='Choose a result and a destination library.',
  on_select=function(pos) download_id=downloads[pos] and downloads[pos].id end})
 iup.SetAttribute(download_list.widget,'RASTERSIZE','x132')
 local function provider_value(pos,field)
  local p=providers[pos];if not p then return end
  if field=='TITLE' then return p.name end
  if field=='SECONDARY' then return p.summary end
 end
 local function item_value(pos,field)
  local item=items[pos];if not item then return end
  if field=='TITLE' then return item.title end
  if field=='SECONDARY' then return item.overview or item.page_url or item.key end
  if field=='COLUMN1' then return item.year and tostring(item.year) or (item.is_series and 'Series' or (item.episode and ('Ep. '..item.episode) or (item.is_page and 'Web page' or 'Film'))) end
 end
 local results=RowList.new(iup,{count=0,value=item_value,row_height=64,column_widths={85},role='flatrows_plain',
  empty_title='Browse a source',empty_hint='Search first; save only the titles you want in your library.',
  header={title="Title",columns={"Year / type"}},
  on_select=function(pos) selected=items[pos];selection() end})
 local function show(job)
  search_state(false)
  current=job;items=job.result.items or {};selected=items[1]
  results:setProvider(#items,item_value);if selected then results:select(1) end;selection()
  local result=job.result
  iup.SetAttribute(description,'TITLE',result.overview or result.title or '')
  Kit.setStatus(iup,status,'ok',tostring(#items)..' results'..(result.truncated and ' — page limit reached' or '')..(result.search_mode=='page' and ' — search filters this page' or ''))
 end
 local function download_status()
  if not opts.on_downloads or download_busy then return end
  download_busy=true
  opts.on_downloads(function(rows,why)
   download_busy=false
   if why then
    iup.SetAttribute(download_info,'TITLE','Could not update downloads: '..tostring(why))
    return
   end
   downloads=rows or {}
   local active,failed,total=0,0,#downloads
   local retry_menu={}
   local selected_pos
   for pos,row in ipairs(downloads) do
    if ctx.activity then
     local key=tostring(row.id)
     local handle=activities[key]
     if not handle then
      local id=row.id
      handle=ctx:activity({title=row.title or 'Media download',cancel=(row.state=='queued' or row.state=='running') and function()
       if opts.on_cancel_download then opts.on_cancel_download(id,function() download_wait=0 end) end
      end or nil,retry=function() if opts.on_retry_download then opts.on_retry_download(id,function() activities[key]=nil;download_wait=0 end) end end},opts.owner)
      activities[key]=handle
     end
     if row.state=='queued' or row.state=='running' then handle:progress(row.bytes,row.total_bytes,row.state)
     else handle:finish(row.state=='complete' or row.state=='completed',row.error or row.state) end
    end
    if row.state=='queued' or row.state=='running' then active=active+1 end
    if row.state=='failed' then failed=failed+1;local id=row.id;retry_menu[#retry_menu+1]={title='Retry '..(row.title or 'download'),action=function() if opts.on_retry_download then opts.on_retry_download(id,function() activities[tostring(id)]=nil;download_wait=0 end) end end} end
    if tostring(row.id)==tostring(download_id) then selected_pos=pos end
   end
   if page then page.opts.menu=retry_menu;page:setSecondary({}) end
   download_list:setProvider(total,download_value)
   selected_pos=selected_pos or (downloads[1] and 1)
   download_id=selected_pos and downloads[selected_pos].id or nil
   if selected_pos then download_list:select(selected_pos) end
   iup.SetAttribute(download_info,'TITLE',string.format('Downloads: %d · Active: %d · Failed: %d',total,active,failed))
  end)
 end
 local function current_download_id()
  return download_id
 end
 local function search(body,remember)
  if not opts.on_discover then return end
  generation=generation+1;local own=generation
  if remember and current then history[#history+1]=current end
  pending=nil;selected=nil;items={};results:setProvider(0,item_value);selection()
  results:setEmpty('Searching the catalog','Waiting for the source to respond.')
  Kit.setStatus(iup,status,'info','Fetching from '..(provider and provider.name or 'source')..'…')
  opts.on_discover(body,function(job,why)
   if own~=generation then return end
   if not job then return Kit.setStatus(iup,status,'error',why or 'Could not start discovery.') end
   if job.state=='ready' and job.result then return show(job) end
   pending={id=job.id,wait=0,attempts=0,generation=own};search_state(true)
  end)
 end
 local provider_list=RowList.new(iup,{count=0,value=provider_value,row_height=64,column_widths={},role='flatrows_plain',
  empty_title='Connect to your server',empty_hint='Available source adapters are supplied by the server.',
  on_select=function(pos) provider=providers[pos];generation=generation+1;pending=nil;current=nil;history={};items={};selected=nil;results:setProvider(0,item_value);selection();Kit.setStatus(iup,status,'info',provider and provider.summary or '') end})
 iup.SetAttribute(provider_list.widget,'RASTERSIZE','260x')
 find=Kit.button(iup,{title='Search / Browse',role='primary_btn',action=function()
  if pending then generation=generation+1;pending=nil;search_state(false);return Kit.setStatus(iup,status,'idle','Search stopped') end
  if not provider then return end
  local text=query:value();history={}
  local generic=provider.id=='video-page'
  search({provider=provider.id,query=generic and '' or text,url=generic and text or nil,page=1})
 end})
 local open=Kit.button(iup,{title='Open page / episodes',role='actionbutton',action=function()
  if provider and selected and selected.is_page then search({provider=provider.id,url=selected.url,details=true},true) end
 end})
 save=Kit.button(iup,{title='Stream from source',icon='add',role='actionbutton',action=function()
  if not selected or not current or not opts.on_import then return end
  local job,key=current.id,selected.key
  opts.on_import(job,key,function(answer,why)
   Kit.setStatus(iup,status,answer and 'ok' or 'error',answer and (answer.syncing and 'Series saved. Its episodes are being fetched on the server.' or 'Saved to your library.') or why)
  end)
 end})
 local destination=iup.list({DROPDOWN='YES',EXPAND='HORIZONTAL',VISIBLECOLUMNS=24})
 local function set_libraries(next_libraries)
  local old=tonumber(iup.GetAttribute(destination,'VALUE') or '0')
  local old_id=libraries[old or 0] and libraries[old].id
  local old_count=#libraries
  local available=next_libraries or libraries
  libraries={}
  for _,library in ipairs(available) do
   if not library.source_id then libraries[#libraries+1]=library end
  end
  local chosen=1
  for i=1,old_count do iup.SetAttribute(destination,tostring(i),nil) end
  for i,library in ipairs(libraries) do
   iup.SetAttribute(destination,tostring(i),library.name)
   if library.id==old_id then chosen=i end
  end
  iup.SetAttribute(destination,'VALUE',#libraries>0 and tostring(chosen) or '0')
 end
 local download=Kit.button(iup,{title='Download to library',icon='download',role='actionbutton',action=function()
  local pos=tonumber(iup.GetAttribute(destination,'VALUE') or '0')
  local library=libraries[pos]
  if not selected or not current or not library or not opts.on_download then
   return Kit.setStatus(iup,status,'error','Choose a local destination library first.')
  end
  opts.on_download(current.id,selected.key,library.id,function(answer,why)
   download_id=answer and answer.id or download_id
   local failed=not answer or answer.state=='failed'
   Kit.setStatus(iup,status,failed and 'error' or 'ok',failed and (why or (answer and answer.error) or 'Download failed.') or
    ('Download '..tostring(answer.state or 'queued')..' for '..library.name..'.'))
   download_wait=0
  end)
 end})
 local cancel_download=Kit.button(iup,{title='Cancel download',role='actionbutton',action=function()
  local id=current_download_id()
  if id and opts.on_cancel_download then opts.on_cancel_download(id,function(_,why)
   if why then Kit.setStatus(iup,status,'error',why) end
   download_status()
  end) end
 end})
 local retry_download=Kit.button(iup,{title='Retry download',role='actionbutton',action=function()
  local id=current_download_id()
  if id and opts.on_retry_download then opts.on_retry_download(id,function(answer,why)
   if answer then download_id=answer.id or id end
   Kit.setStatus(iup,status,answer and 'info' or 'error',answer and 'Retry queued.' or why)
  end) end
 end})
 local back=Kit.button(iup,{title='Back',role='actionbutton',action=function()
  local previous=table.remove(history);if previous then generation=generation+1;pending=nil;show(previous) end
 end})
 local next_page=Kit.button(iup,{title='Next page',role='actionbutton',action=function()
  if provider and current and current.result.has_more then search({provider=provider.id,query=query:value(),page=(current.result.page or 1)+1},true) end
 end})
 local choices=iup.vbox({save,destination,download,GAP=L.gap(3),EXPAND='HORIZONTAL'})
 Kit.show(iup,choices,false,status)
 add_menu=Kit.disclosure(iup,{title='Add to library',on_change=function(on) Kit.show(iup,choices,on,status) end})
 local empty=Kit.button(iup,{title='Connect',action=function() if opts.on_connect then opts.on_connect() end end})
 local welcome=iup.vbox({L.sectionTitle(iup,'Connect to your media server'),
  L.hint(iup,'Connect to browse source catalogs and add titles to your library.'),empty,GAP=L.gap(3),EXPAND='YES'})
 local catalog=iup.vbox({description,results.widget,
  iup.hbox({back,open,iup.fill({}),next_page,GAP=L.gap(3),EXPAND='HORIZONTAL'}),GAP=L.gap(3),EXPAND='YES'})
 local main=iup.vbox({welcome,catalog,EXPAND='YES'})
 page=Kit.page(iup,{id='media-sources',title='Sources',icon='globe',
  nav={title='Sources',widget=provider_list.widget}, main=main,
  toolbar=iup.hbox({query.widget,GAP=L.gap(3),EXPAND='HORIZONTAL'}),
  primary={widget=find,run='run'},inspector={title='Add selected title',widget=iup.vbox({add_menu,choices,GAP=L.gap(3),EXPAND='YES'})}})
 -- Keep asynchronous status callbacks on the page's one state line.
 status=page.stateLine
 api.widget=page:widget()
 api.page=page
 local last_connected,last_provider
 local function connection()
  local connected=capture_connected or not opts.is_connected or opts.is_connected()
  if connected==last_connected and provider==last_provider then return end
  last_connected,last_provider=connected,provider
  Kit.show(iup,welcome,not connected,status);Kit.show(iup,catalog,connected,status)
  Kit.show(iup,query.widget,connected,status);Kit.show(iup,find,connected,status)
  iup.SetAttribute(find,'ACTIVE',connected and provider and 'YES' or 'NO')
  iup.SetAttribute(find,'TIP',connected and provider and 'Search the selected source' or 'Connect and choose a source first')
  if ctx.notifyTreeChange then ctx:notifyTreeChange(find) end
  Kit.show(iup,page.config,connected,status)
  if page.configSplit then iup.SetAttribute(page.configSplit,'VALUE',connected and tostring(math.floor(page.configSize/page.width*1000)) or '0') end
  if not connected then page:setState('idle','Not connected');page:openInspector(false)
  end
 end
 api.refreshConnection=connection
 page.mediaCaptureState=function(state)
  capture_connected=true;api.setProviders(opts.providers);connection()
  items={};selected=nil;current=nil;results:setProvider(0,item_value);selection()
  if state=='working' then
   page:setState('working','Searching Internet Archive…');search_state(true)
   results:setEmpty('Searching the catalog','Waiting for Internet Archive to respond.')
  else
   page:setState('error','Internet Archive could not be reached. Try searching again.');search_state(false)
   results:setEmpty('Could not load the catalog','Check your connection and search again.')
  end
 end
 api.capture=function(state)
  if state=='connected' then
   capture_connected=true;api.setProviders(opts.providers);connection()
   iup.SetAttribute(find,'ACTIVE',provider and 'YES' or 'NO')
   if ctx.notifyTreeChange then ctx:notifyTreeChange(find) end
   show({id='catalog',result={items={{key='1',title='The General',year=1926,overview='A railway engineer follows his stolen locomotive across enemy lines.'},{key='2',title='Sherlock Jr.',year=1924,overview='A projectionist dreams of becoming a detective.'}}}})
  else capture_connected=false;current=nil;items={};selected=nil;results:setProvider(0,item_value);connection();selection() end
 end
 if ctx.fitPage then ctx:fitPage(api.widget,function(w) page:fit(w) end) end

 function api.setProviders(list)
  local old=provider and provider.id;providers={}
  for _,p in ipairs(list or {}) do if p.kind=='website' or p.kind=='archive' then providers[#providers+1]=p end end
  provider_list:setProvider(#providers,provider_value)
  provider=nil
  for i,p in ipairs(providers) do if p.id==old then provider=p;provider_list:select(i);break end end
  if not provider and providers[1] then provider=providers[1];provider_list:select(1) end
  connection()
 end
 api.setLibraries=set_libraries
 set_libraries(libraries)
 connection();selection()
 function api.tick()
  connection()
  download_wait=download_wait-1
  if download_wait<=0 then download_wait=100;download_status() end
  local request=pending;if not request then return end
  request.wait=request.wait-1;if request.wait>0 or request.busy then return end
  request.busy=true;request.attempts=request.attempts+1
  opts.on_discovery(request.id,function(job,why)
   if pending~=request or generation~=request.generation then return end
   request.busy=false
   if not job or job.state=='failed' then pending=nil;search_state(false);return Kit.setStatus(iup,status,'error',why or (job and job.error) or 'Discovery failed.') end
   if job.state=='ready' then pending=nil;return show(job) end
   if request.attempts>=90 then pending=nil;search_state(false);return Kit.setStatus(iup,status,'error','Source timed out. Try again.') end
   request.wait=20
  end)
 end
 return api
end
return M
