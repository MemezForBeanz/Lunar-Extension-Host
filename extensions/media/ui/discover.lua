--- Browse sources without importing their whole catalog into the personal library.
local L=require('core.lib.CarbonLayout')
local Kit=require('core.ui.Kit')
local RowList=require('core.ui.RowList')
local FlatField=require('core.ui.FlatField')
local M={}
function M.new(ctx,opts)
 local iup=ctx.iup;local api={};local providers,items={},{};local provider,selected,current
 local generation=0;local pending;local history={}
 local query=FlatField.new(iup,{cue='Search titles, or paste a video webpage URL'})
 local status=Kit.statusLine(iup,'info','Choose a source to browse its catalog.')
 local description=iup.flatlabel({TITLE='',THEMEROLE='reading_muted',TEXTWRAP='YES',EXPAND='HORIZONTAL',RASTERSIZE='x38'})
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
 local back=Kit.button(iup,{title='Back',role='actionbutton',action=function()
  local previous=table.remove(history);if previous then generation=generation+1;pending=nil;show(previous) end
 end})
 local next_page=Kit.button(iup,{title='Next page',role='actionbutton',action=function()
  if provider and current and current.result.has_more then search({provider=provider.id,query=query:value(),page=(current.result.page or 1)+1},true) end
 end})
 api.widget=iup.hbox({provider_list.widget,iup.vbox({
  iup.hbox({query.widget,find,GAP=L.gap(2),EXPAND='HORIZONTAL'}),status,description,results.widget,
  iup.hbox({back,open,save,iup.fill({}),next_page,GAP=L.gap(2),EXPAND='HORIZONTAL'}),
  GAP=L.gap(3),MARGIN='0x0',EXPAND='YES'}),GAP=L.gap(5),MARGIN='0x0',EXPAND='YES'})
 function api.setProviders(list)
  local old=provider and provider.id;providers={}
  for _,p in ipairs(list or {}) do if p.kind=='website' or p.kind=='archive' then providers[#providers+1]=p end end
  provider_list:setProvider(#providers,provider_value)
  provider=nil
  for i,p in ipairs(providers) do if p.id==old then provider=p;provider_list:select(i);break end end
  if not provider and providers[1] then provider=providers[1];provider_list:select(1) end
 end
 function api.tick()
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
