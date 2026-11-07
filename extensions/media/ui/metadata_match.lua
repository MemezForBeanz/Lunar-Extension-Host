-- Inline, asynchronous metadata correction for a title page.
local Kit = require('core.ui.Kit')
local Field = require('core.ui.FlatField')
local Rows = require('core.ui.RowList')
local Dropdown = require('core.ui.FlatDropdown')
local Metadb = require('libs.metadb')
local M = {}
function M.new(ctx, opts)
 local iup=ctx.iup
 local api={}; local item,selected,pending; local generation=0
 local candidates={}
 local provider_ids,provider_names={},{}
 for _,p in ipairs(Metadb.providers) do provider_ids[#provider_ids+1]=p.id;provider_names[#provider_names+1]=p.name end
 local provider_index=1
 local provider=Dropdown.new(iup,{items=provider_names,value=1,width=240,on_change=function(index) provider_index=index;generation=generation+1;pending=nil;candidates={};selected=nil end})
 local query=Field.new(iup,{cue='Movie or TV title'})
 local status=Kit.statusLine(iup,'info','Search, then choose the correct title and year.')
 local function value(pos,field)
  local row=candidates[pos]; if not row then return end
  if field=='TITLE' then return row.title end
  if field=='SECONDARY' then return row.overview or '' end
  if field=='COLUMN1' then return tostring(row.year or '') end
 end
 local rows=Rows.new(iup,{count=0,value=value,row_height=64,column_widths={70},role='flatrows_plain',
  empty_title='Find the correct match',empty_hint='Choose a metadata provider and search.',on_select=function(pos) selected=candidates[pos] end})
 iup.SetAttribute(rows.widget,'RASTERSIZE','x240')
 local function start(method,arg)
  if not item or not opts.on_metadata then return end
  generation=generation+1;local own=generation;pending=nil
  Kit.setStatus(iup,status,'info',method=='search' and 'Searching provider...' or 'Loading selected metadata...')
  opts.on_metadata(method,item,arg,function(job,why)
   if own~=generation then return end
   if not job then return Kit.setStatus(iup,status,'error',why or 'Could not start metadata request.') end
   pending={id=job.id,method=method,generation=own,wait=0,attempts=0}
  end)
 end
 local search=Kit.button(iup,{title='Search',role='actionbutton',action=function() start('search',{query=query:value(),provider=provider_ids[provider_index]}) end})
 local match=Kit.button(iup,{title=opts.lookup and 'Load details' or 'Use selected match',role='primary_btn',action=function() if selected then start('match',{id=selected.id,provider=selected.provider}) end end})
 local refresh=Kit.button(iup,{title='Refresh metadata',role='actionbutton',action=function()
  if opts.lookup then return start('search',{query=query:value(),provider=provider_ids[provider_index]}) end
  if item and opts.on_metadata then opts.on_metadata('refresh',item,nil,function(answer,why)
   Kit.setStatus(iup,status,answer and 'ok' or 'error',answer and 'Metadata refresh queued.' or why)
  end) end
 end})
 api.widget=iup.vbox({provider.widget,iup.hbox({query.widget,search,GAP='8',EXPAND='HORIZONTAL'}),status,rows.widget,
  iup.hbox({match,refresh,GAP='8'}),GAP='8',EXPAND='HORIZONTAL'})
 function api.open(next_item)
  generation=generation+1;pending=nil;item=next_item;selected=nil;candidates={}
  query:setValue(item.title or '');rows:setProvider(0,value)
  Kit.setStatus(iup,status,'info','Search, then choose the correct title and year.')
 end
 function api.tick()
  local job=pending;if not job or job.busy then return end
  job.wait=job.wait-1;if job.wait>0 then return end
  job.busy=true;job.attempts=job.attempts+1
  opts.on_metadata('poll',item,job.id,function(answer,why)
   if pending~=job or generation~=job.generation then return end
   job.busy=false
   if not answer or answer.state=='failed' then pending=nil;return Kit.setStatus(iup,status,'error',why or (answer and answer.error) or 'Request failed.') end
   if answer.state=='ready' then
    pending=nil
    if job.method=='match' then
     Kit.setStatus(iup,status,'ok',opts.lookup and 'Details loaded.' or 'Match saved. Reloading artwork and details...')
     if opts.on_changed then opts.on_changed(item) end
    else
     candidates=answer.result or {};selected=nil;rows:setProvider(#candidates,value)
     if candidates[1] then selected=candidates[1];rows:select(1) end
     Kit.setStatus(iup,status,'info',tostring(#candidates)..' matches. Check the title and year before choosing.')
    end
   elseif job.attempts>=90 then pending=nil;Kit.setStatus(iup,status,'error','Metadata request timed out.')
   else job.wait=20 end
  end)
 end
 return api
end
return M
