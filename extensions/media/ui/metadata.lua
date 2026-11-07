-- Provider lookup remains available when there is no media-server extension.
local Dropdown=require('core.ui.FlatDropdown')
local Match=require('ui.metadata_match')
local M={}
function M.new(ctx,opts)
 local iup=ctx.iup;local item={kind='movie',title=''}
 local title=iup.flatlabel({TITLE='Metadata lookup',THEMEROLE='pagetitle',EXPAND='HORIZONTAL'})
 local details=iup.flatlabel({TITLE='Search movies, TV shows, and anime without connecting a media server.',THEMEROLE='reading',TEXTWRAP='YES',EXPAND='HORIZONTAL',RASTERSIZE='x135'})
 local source=iup.link({TITLE='',URL='https://www.tvmaze.com',EXPAND='HORIZONTAL'})
 local function changed(next_item)
  item=next_item;title.title=(item.title or '')..(item.year and ' ('..item.year..')' or '')
  details.title=(item.overview or 'No description supplied.')..'\n\n'..table.concat(item.genres or {},', ')..'\nCast: '..table.concat(item.people or {},', ')
  source.title=(item.provider or '')..' - '..(item.source_url or '');source.url=item.source_url or ''
 end
 local match=Match.new(ctx,{lookup=true,on_metadata=opts.on_metadata,on_changed=changed})
 local kind=Dropdown.new(iup,{items={'Movies','TV shows / anime'},value=1,width=220,on_change=function(index) item={kind=index==1 and 'movie' or 'show',title=''};match.open(item) end})
 match.open(item)
 return {widget=iup.vbox({title,kind.widget,match.widget,details,source,require('ui.credits').new(iup),GAP='12',MARGIN='16x16',EXPAND='YES'}),tick=match.tick}
end
return M
