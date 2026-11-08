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
  on_select=function(pos) selected=items[pos] end})
 local function show(job)
  current=job;items=job.result.items or {};selected=items[1]
  results:setProvider(#items,item_value);if selected then results:select(1) end
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
   local selected_pos
   for pos,row in ipairs(downloads) do
    if row.state=='queued' or row.state=='running' then active=active+1 end
    if row.state=='failed' then failed=failed+1 end
    if tostring(row.id)==tostring(download_id) then selected_pos=pos end
   end
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
  pending=nil;selected=nil
  Kit.setStatus(iup,status,'info','Fetching from '..(provider and provider.name or 'source')..'…')
  opts.on_discover(body,function(job,why)
   if own~=generation then return end
   if not job then return Kit.setStatus(iup,status,'error',why or 'Could not start discovery.') end
   if job.state=='ready' and job.result then return show(job) end
   pending={id=job.id,wait=0,attempts=0,generation=own}
  end)
 end
 local provider_list=RowList.new(iup,{count=0,value=provider_value,row_height=64,column_widths={},role='flatrows_plain',
  empty_title='Connect to your server',empty_hint='Available source adapters are supplied by the server.',
  on_select=function(pos) provider=providers[pos];generation=generation+1;pending=nil;current=nil;history={};items={};selected=nil;results:setProvider(0,item_value);Kit.setStatus(iup,status,'info',provider and provider.summary or '') end})
 iup.SetAttribute(provider_list.widget,'RASTERSIZE','260x')
 local find=Kit.button(iup,{title='Search / Browse',role='primary_btn',action=function()
  if not provider then return end
  local text=query:value();history={}
  local generic=provider.id=='video-page'
  search({provider=provider.id,query=generic and '' or text,url=generic and text or nil,page=1})
 end})
 local open=Kit.button(iup,{title='Open page / episodes',role='actionbutton',action=function()
  if provider and selected and selected.is_page then search({provider=provider.id,url=selected.url,details=true},true) end
 end})
 local save=Kit.button(iup,{title='Save to library',icon='add',role='primary_btn',action=function()
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
 local download=Kit.button(iup,{title='Download to library',icon='download',role='primary_btn',action=function()
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
 api.widget=iup.hbox({provider_list.widget,iup.vbox({
  iup.hbox({query.widget,find,GAP=L.gap(2),EXPAND='HORIZONTAL'}),status,description,results.widget,
  iup.hbox({back,open,save,iup.fill({}),next_page,GAP=L.gap(2),EXPAND='HORIZONTAL'}),
  iup.hbox({destination,download,GAP=L.gap(2),EXPAND='HORIZONTAL'}),
  download_info,download_list.widget,
  iup.hbox({cancel_download,retry_download,GAP=L.gap(2),EXPAND='HORIZONTAL'}),
  GAP=L.gap(3),MARGIN='0x0',EXPAND='YES'}),GAP=L.gap(5),MARGIN='0x0',EXPAND='YES'})
 function api.setProviders(list)
  local old=provider and provider.id;providers={}
  for _,p in ipairs(list or {}) do if p.kind=='website' or p.kind=='archive' then providers[#providers+1]=p end end
  provider_list:setProvider(#providers,provider_value)
  provider=nil
  for i,p in ipairs(providers) do if p.id==old then provider=p;provider_list:select(i);break end end
  if not provider and providers[1] then provider=providers[1];provider_list:select(1) end
 end
 api.setLibraries=set_libraries
 set_libraries(libraries)
 function api.tick()
  download_wait=download_wait-1
  if download_wait<=0 then download_wait=100;download_status() end
  local request=pending;if not request then return end
  request.wait=request.wait-1;if request.wait>0 or request.busy then return end
  request.busy=true;request.attempts=request.attempts+1
  opts.on_discovery(request.id,function(job,why)
   if pending~=request or generation~=request.generation then return end
   request.busy=false
   if not job or job.state=='failed' then pending=nil;return Kit.setStatus(iup,status,'error',why or (job and job.error) or 'Discovery failed.') end
   if job.state=='ready' then pending=nil;return show(job) end
   if request.attempts>=90 then pending=nil;return Kit.setStatus(iup,status,'error','Source timed out. Try again.') end
   request.wait=20
  end)
 end
 return api
end
return M
