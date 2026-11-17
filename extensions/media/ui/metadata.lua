local Kit=require('core.ui.Kit')
local L=require('core.lib.CarbonLayout')
-- Provider lookup remains available when there is no media-server extension.
local Dropdown=require('core.ui.FlatDropdown')
local Match=require('ui.metadata_match')
local M={}
function M.new(ctx,opts)
 local iup=ctx.iup;local item={kind='movie',title=''}
 local title=iup.flatlabel({TITLE='Preview',THEMEROLE='sectiontitle',EXPAND='HORIZONTAL'})
 local details=iup.flatlabel({TITLE='Search movies, TV shows, and anime without connecting a media server.',THEMEROLE='reading',TEXTWRAP='YES',EXPAND='HORIZONTAL',RASTERSIZE='x135'})
 local kind_line=iup.flatlabel({TITLE='',THEMEROLE='reading_muted',EXPAND='HORIZONTAL'})
 local source=iup.link({TITLE='',URL='https://www.tvmaze.com',EXPAND='HORIZONTAL'})
 local KINDS={movie='Movie',show='TV show',anime='Anime'}
 local function kind_name(k) if not k then return '' end return KINDS[k] or (tostring(k):gsub('^%l',string.upper)) end
 local function changed(next_item)
  item=next_item;title.title=(item.title or '')..(item.year and ' ('..item.year..')' or '')
  kind_line.title=kind_name(item.kind)
  details.title=(item.overview or 'No description supplied.')..'\n\n'..table.concat(item.genres or {},', ')..'\nCast: '..table.concat(item.people or {},', ')
  source.title=(item.provider or '')..' - '..(item.source_url or '');source.url=item.source_url or ''
 end
 local function selection(next_item)
  if next_item then
   title.title=(next_item.title or '')..(next_item.year and ' ('..next_item.year..')' or '')
   kind_line.title=kind_name(next_item.kind or item.kind or 'movie')
   details.title=next_item.overview or 'No description supplied.'
   source.title=next_item.source_url or '';source.url=next_item.source_url or ''
  else
   title.title='Preview'
   kind_line.title=''
   details.title='Search movies, TV shows, and anime without connecting a media server.'
   source.title=''
  end
 end
 local match
 local kind=Dropdown.new(iup,{items={'Movies','TV shows / anime'},value=1,width=220,on_change=function(index) item={kind=index==1 and 'movie' or 'show',title=''};match.open(item) end})
 match=Match.new(ctx,{lookup=true,on_selection=selection,on_metadata=opts.on_metadata,on_changed=changed,type_widget=kind.widget})
 match.open(item)
 local content=iup.vbox({match.widget,title,kind_line,details,source,iup.fill({}),require('ui.credits').new(iup),GAP=L.gap(4),EXPAND='YES'})
 local page=Kit.page(iup,{id='media-metadata',title='Metadata',icon='search',main=content,state={kind='info',text='Search a provider, select a result, then load its details'}})
 match.bindStatus(page.stateLine)
 page.mediaCaptureState=match.capture
 if ctx.fitPage then ctx:fitPage(page:widget(),function(w) page:fit(w) end) end
 return {widget=page:widget(),tick=match.tick,capture=match.capture}
end
return M
