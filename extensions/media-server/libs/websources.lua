--- Small, bounded HTML adapters. No browser, site scripts, or global crawl.
local cjson = require('cjson')
local url = require('socket.url')
local M = {}
M.LIMIT = 100
M.SITES = {
 { id='wco', name='WCO', kind='website', summary='Browse WCO titles and episodes. Availability depends on the website.', config={base='https://www.wco.tv/', adapter='wco'}, fields={} },
 { id='9anime', name='9anime.or.at', kind='website', summary='Browse anime, open a series, then choose an episode.', config={base='https://9anime.or.at/', adapter='9anime'}, fields={} },
 { id='kissanime', name='kissanime.tv.in', kind='website', summary='Browse anime and episodes; search filters the current catalog page.', config={base='https://kissanime.tv.in/', adapter='kissanime'}, fields={} },
 { id='video-page', name='Video webpage', kind='website', summary='Add a video page or playlist URL. Embedded video is resolved on the server.', config={adapter='generic'}, fields={{id='url',label='Webpage address',cue='https://example.org/video'}} },
}
function M.web(value)
 return type(value)=='string' and value:match('^https?://[^/%s]+') ~= nil and not value:find('[%c%s]') and not value:match('^https?://[^/]*@')
end
function M.text(s)
 s=tostring(s or ''):gsub('<script.-</script>',''):gsub('<style.-</style>',''):gsub('<[^>]+>','')
 local entities={amp='&',quot='"',apos="'",lt='<',gt='>',nbsp=' '}
 return (s:gsub('&([%a]+);',entities):gsub('&#(%d+);',function(n)
  n=tonumber(n); if n<128 then return string.char(n) end
  if n<2048 then return string.char(192+math.floor(n/64),128+n%64) end
  if n<65536 then return string.char(224+math.floor(n/4096),128+math.floor(n/64)%64,128+n%64) end
  return ''
 end):gsub('%s+',' '):gsub('^%s+',''):gsub('%s+$',''))
end
function M.attrs(s)
 local out={}
 for k,quote,v in s:gmatch('([%w_:%-]+)%s*=%s*([\'"])(.-)%2') do out[k:lower()]=M.text(v) end
 return out
end
function M.absolute(base, value)
 if type(value)~='string' or value=='' then return nil end
 local absolute=url.absolute(base,value)
 return M.web(absolute) and absolute or nil
end
local function first_url(base, value)
 if type(value)~='string' then return nil end
 value=value:gsub('^%s+',''):gsub('%s+$','')
 local candidate=value:match('^([^%s,]+)') or value
 return M.absolute(base,candidate)
end
local function srcset(base, value)
 if type(value)~='string' then return nil end
 for candidate in value:gmatch('([^,]+)') do
  local address=first_url(base,candidate)
  if address then return address end
 end
end
local function image_from_attrs(base, attrs)
 local function usable(value)
  local address=first_url(base,value)
  if not address then return nil end
  local path=(url.parse(address).path or ''):lower()
  if path:find('placeholder',1,true) or path:find('transparent',1,true) or
    path:find('spacer',1,true) or path:find('blank',1,true) or path:find('1x1',1,true) then return nil end
  return address
 end
 local candidates={}
 for _,key in ipairs({'data-src','data-lazy-src','data-original','data-image','src'}) do
  local value=attrs[key]
  if value then candidates[#candidates+1]=value end
 end
 for _,value in ipairs(candidates) do
  local address=usable(value)
  if address then return address end
 end
 return srcset(base,attrs['data-srcset'] or attrs.srcset)
end
local function media_url(value)
 if type(value)~='string' then return false end
 local path=value:lower():match('^[^?#]*') or value:lower()
 return path:match('%.m3u8$') ~= nil or path:match('%.mp4$') ~= nil or path:match('%.webm$') ~= nil
end
local function json_image(base, value)
 if type(value)=='string' then return first_url(base,value) end
 if type(value)=='table' then
  if #value>0 then
   for _,entry in ipairs(value) do
    local address=json_image(base,entry)
    if address then return address end
   end
   return nil
  end
  return json_image(base,value.url or value.contentUrl or value.thumbnailUrl or value.image)
 end
end
local function json_ld(html, base)
 local facts={}
 for body in html:gmatch('<script[^>]-type=[\'"]application/ld%+json[\'"][^>]*>(.-)</script>') do
  local ok,data=pcall(cjson.decode,body)
  local entries=ok and type(data)=='table' and (data['@graph'] or data)
  if type(entries)~='table' then entries={} end
  if entries['@type'] or entries.name or entries.headline then entries={entries} end
  for _,item in ipairs(entries) do
   if type(item)=='table' then
    local kind=tostring(item['@type'] or ''):lower()
    if not facts.title and (kind:find('movie',1,true) or kind:find('tv',1,true) or kind=='video' or item.headline or item.name) then
     facts.title=item.headline or item.name
    end
    facts.overview=facts.overview or item.description
    facts.poster_url=facts.poster_url or json_image(base,item.image or item.thumbnailUrl)
    facts.source_url=facts.source_url or first_url(base,item.url)
    local content_url=first_url(base,item.contentUrl)
    facts.playable_url=facts.playable_url or (media_url(content_url) and content_url or nil)
    local publisher=item.publisher
    if type(publisher)=='table' then facts.attribution=facts.attribution or publisher.name end
   end
  end
 end
 return facts
end
local function encode(s) return (s:gsub('[^%w%-._~]',function(c) return string.format('%%%02X',c:byte()) end)) end
function M.request(provider, query, page, target)
 local config=provider.config or {}; local base=config.base or target
 if not M.web(base) then return nil,'Enter a valid HTTP or HTTPS webpage address.' end
 if target then
  if not M.web(target) then return nil,'Invalid page address.' end
  if config.base and url.parse(target).host ~= url.parse(config.base).host then return nil,'This page belongs to a different source.' end
  return {url=target}
 end
 query=query or '';page=page or 1
 if config.adapter=='9anime' or config.adapter=='wco' then
  return {url=base..(page>1 and ('page/'..page..'/') or '')..(query~='' and ('?s='..encode(query)) or '')}
 end
 if config.adapter=='kissanime' then return {url=base..'AnimeList?page='..page} end
 return {url=base}
end
function M.metadata(html, base)
 local facts=json_ld(html,base)
 for tag in html:gmatch('<[mM][eE][tT][aA]%s+([^>]+)>') do
  local a=M.attrs(tag); local key=a.property or a.name
  key=key and key:lower()
  if key=='og:title' or key=='twitter:title' then facts.title=facts.title or a.content end
  if key=='og:description' or key=='description' or key=='twitter:description' then facts.overview=facts.overview or a.content end
  if key=='og:image' or key=='og:image:url' or key=='og:image:secure_url' or key=='twitter:image' then facts.poster_url=facts.poster_url or first_url(base,a.content) end
  if key=='og:url' then facts.source_url=facts.source_url or first_url(base,a.content) end
  if key=='og:video' or key=='og:video:url' or key=='og:video:secure_url' then
   local address=first_url(base,a.content)
   facts.playable_url=facts.playable_url or (media_url(address) and address or nil)
  end
 end
 for attributes in html:gmatch('<[lL][iI][nN][kK]%s+([^>]+)>') do
  local a=M.attrs(attributes)
  if a.rel and a.rel:lower():find('canonical',1,true) then
   facts.source_url=facts.source_url or first_url(base,a.href)
   break
  end
 end
 facts.title=facts.title or M.text(html:match('<[tT][iI][tT][lL][eE][^>]*>(.-)</[tT][iI][tT][lL][eE]>'))
 local heading=html:match('<h[12][^>]-class=[\'"][^\'"]-film%-name[^\'"]*[\'"][^>]*>(.-)</h[12]>')
 facts.title=heading and M.text(heading) or facts.title:gsub('^Watch (.-) %- 9anime$','%1'):gsub(' %- Watch Online Free %- KissAnime$','')
 facts.overview=facts.overview and M.text(facts.overview) or nil
 facts.title=facts.title and M.text(facts.title) or ''
 facts.source_url=facts.source_url or base
 return facts
end
function M.parse(html, base, provider, query, details, context)
 local items,seen={},{};local config=provider.config or {};local host=url.parse(base).host
 local named_images,image_count={},0
 for attributes in html:gmatch('<[iI][mM][gG]%s+([^>]+)>') do
  if image_count>=M.LIMIT*4 then break end
  local image=M.attrs(attributes)
  local title=image.alt or image.title
  local address=image_from_attrs(base,image)
  if title and title~='' and address and not named_images[title:lower()] then
   named_images[title:lower()]=address;image_count=image_count+1
  end
 end
 local facts=context or M.metadata(html,base)
 local source_id=provider.id
 if config.adapter=='9anime' and details then
  local ok,data=pcall(cjson.decode,html)
  if ok and type(data)=='table' and type(data.pages)=='string' then html=data.pages end
  local series=html:match('data%-series=[\'"](%d+)[\'"]')
  if series then return {items={},source_id=source_id,title=facts.title,overview=facts.overview,poster_url=facts.poster_url,
   source_url=facts.source_url,attribution=facts.attribution,
   followup={url=(config.base or base)..'wp-json/9animetv/v1/episodes/'..series..'?active=0'}} end
 end
 if config.adapter=='generic' then
  local streams=M.streams(html,base)
  if facts.playable_url then
   local found=false
   for _,value in ipairs(streams) do if value==facts.playable_url then found=true;break end end
   if not found then table.insert(streams,1,facts.playable_url) end
  end
  local playable=streams[1]
  return {items={{key=base,source_id=source_id,title=facts.title~='' and facts.title or base,url=playable or base,
   resolve=playable and 'direct' or 'webpage',overview=facts.overview,poster_url=facts.poster_url,
   source_url=facts.source_url,attribution=facts.attribution,stream_urls=#streams>0 and streams or nil,is_page=not playable}},page_url=base,
   source_id=source_id,title=facts.title,overview=facts.overview,poster_url=facts.poster_url,source_url=facts.source_url,
   attribution=facts.attribution,has_more=false}
 end
 for attributes,body in html:gmatch('<[aA]%s+([^>]-)>(.-)</[aA]>') do
  local a=M.attrs(attributes);local address=M.absolute(base,a.href)
  local image=M.attrs(body:match('<[iI][mM][gG]%s+([^>]+)>') or '')
   local same=address and url.parse(address).host==host
   local path=address and url.parse(address).path or ''
  local title=M.text(body);if title=='' then title=image.alt or a.title or
   ((details and facts.title) ~= '' and facts.title) or (path:match('/([^/]+)$') or ''):gsub('[%-%_]+',' ') end
  local match=same and ((config.adapter=='9anime' and path:match('^/anime/')) or
   (config.adapter=='kissanime' and path:lower():match('^/anime/')) or
   (config.adapter=='wco' and (path:match('^/anime/') or path:lower():find('episode',1,true))) or
   config.adapter=='generic' or media_url(address))
  if details and same then
   match=match or path:lower():find('episode',1,true)~=nil
   -- Series cards are not playable episodes.
   if config.adapter=='9anime' then match=path:match('^/watch/')~=nil or path:find('episode',1,true)~=nil end
   if config.adapter=='kissanime' then match=path:lower():find('/episode',1,true)~=nil end
   if config.adapter=='wco' then match=match or path:lower():find('/watch/',1,true)~=nil end
  end
  -- Sites often link the title before a second link containing its poster.
  -- Deduplication must still let that later card complete the first result.
  if match and seen[address] then
   local existing=seen[address]
   existing.poster_url=existing.poster_url or image_from_attrs(base,image) or named_images[existing.title:lower()]
   existing.overview=existing.overview or a['data-description']
  end
  if match and title~='' and #title<=300 and not seen[address] and #items<M.LIMIT and
    not (config.adapter=='kissanime' and title:lower()=='kissanime') and
    (not query or query=='' or config.adapter~='kissanime' or title:lower():find(query:lower(),1,true)) then
   local number=details and tonumber(a['data-number'] or path:lower():match('episode%-(%d+)') or title:lower():match('episode%s*(%d+)'))
   local is_series=not details and (config.adapter=='9anime' or config.adapter=='kissanime' or
    (config.adapter=='wco' and path:match('^/anime/'))) and not path:lower():find('episode',1,true)
   local own_facts=details or facts.source_url==address
   local direct=media_url(address) and address or nil
   items[#items+1]={key=address,source_id=source_id,title=number and ('Episode '..number) or title,url=direct or address,resolve=direct and 'direct' or 'webpage',
    poster_url=(details and facts.poster_url) or image_from_attrs(base,image) or named_images[title:lower()] or (own_facts and facts.poster_url or nil),
    overview=own_facts and facts.overview or a['data-description'],page_url=address,source_url=details and (facts.source_url or address) or address,
    attribution=facts.attribution,stream_urls=direct and {direct} or nil,
    kind=number and 'episode' or (is_series and 'series' or 'page'),
    is_page=not direct,is_series=is_series or false,
    show=number and facts.title or nil,season=number and 1 or nil,episode=number}
   seen[address]=items[#items]
  end
 end
 if details then table.sort(items,function(a,b) return (a.episode or 0)<(b.episode or 0) end) end
 return {items=items,source_id=source_id,title=facts.title,overview=facts.overview,poster_url=facts.poster_url,source_url=facts.source_url,
  attribution=facts.attribution,page_url=base,
  search_mode=config.adapter=='kissanime' and 'page' or 'site',has_more=#items>0 and not details,truncated=#items>=M.LIMIT}
end
function M.embed(html,base)
 local ok,data=pcall(cjson.decode,html)
 if ok and type(data)=='table' and type(data.html)=='string' then html=data.html end
 if url.parse(base).host=='9anime.or.at' then
  local id=html:match('episodeId%s*:%s*(%d+)')
  if id then return 'https://9anime.or.at/ajax/episode/servers?id='..id end
 end
 local encoded=html:match('data%-embed=[\'"]([%w+/=]+)[\'"]')
 if encoded then
  local decoded=require('mime').unb64(encoded)
  local address=M.absolute(base,decoded)
  if address then return address end
 end
 for tag in html:gmatch('<[iI][fF][rR][aA][mM][eE]%s+([^>]+)>') do
  local attrs=M.attrs(tag);local address=M.absolute(base,attrs.src or attrs['data-src'])
  if address then return address end
 end
end
function M.unavailable(html)
 local text=M.text(html):lower()
 local heading=M.text(html:match('<h[123][^>]*>(.-)</h[123]>')):lower()
 return heading=='video not available' or text:match('^video not available') or
  (text:find("we can't find the file you are looking for",1,true) and text:find('error code: 410',1,true))
end
function M.streams(html, base)
 local out,seen={},{}
 local function add(value)
  local v=M.absolute(base,value)
  if v and not seen[v] then seen[v]=true;out[#out+1]=v end
 end
 for tag in html:gmatch('<[mM][eE][tT][aA]%s+([^>]+)>') do
  local a=M.attrs(tag)
  if a.property=='og:video:url' or a.property=='og:video:secure_url' or a.property=='og:video' then
   local address=first_url(base,a.content)
   if media_url(address) then add(address) end
  end
 end
 for tag in html:gmatch('<[vV][iI][dD][eE][oO]%s+([^>]+)>') do local a=M.attrs(tag);add(a.src or a['data-src']) end
 for tag in html:gmatch('<[sS][oO][uU][rR][cC][eE]%s+([^>]+)>') do local a=M.attrs(tag);add(a.src or a['data-src']) end
 for body in html:gmatch('<script[^>]-type=[\'"]application/ld%+json[\'"][^>]*>(.-)</script>') do
  local ok,data=pcall(cjson.decode,body)
  local entries=ok and type(data)=='table' and (data['@graph'] or data)
  if type(entries)~='table' then entries={} end
  if entries.contentUrl or entries.url then entries={entries} end
  for _,item in ipairs(entries) do
   if type(item)=='table' then add(item.contentUrl) end
  end
 end
 return out
end
function M.stream(html, base)
 return M.streams(html,base)[1]
end
return M
