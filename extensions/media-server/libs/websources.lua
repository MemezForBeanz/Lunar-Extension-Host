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
 local facts={}
 for tag in html:gmatch('<[mM][eE][tT][aA]%s+([^>]+)>') do
  local a=M.attrs(tag); local key=a.property or a.name
  if key=='og:title' then facts.title=a.content end
  if key=='og:description' or key=='description' then facts.overview=facts.overview or a.content end
  if key=='og:image' then facts.poster_url=M.absolute(base,a.content) end
 end
 facts.title=facts.title or M.text(html:match('<[tT][iI][tT][lL][eE][^>]*>(.-)</[tT][iI][tT][lL][eE]>'))
 local heading=html:match('<h[12][^>]-class=[\'"][^\'"]-film%-name[^\'"]*[\'"][^>]*>(.-)</h[12]>')
 facts.title=heading and M.text(heading) or facts.title:gsub('^Watch (.-) %- 9anime$','%1'):gsub(' %- Watch Online Free %- KissAnime$','')
 return facts
end
function M.parse(html, base, provider, query, details, context)
 local items,seen={},{};local config=provider.config or {};local host=url.parse(base).host
 local facts=context or M.metadata(html,base)
 if config.adapter=='9anime' and details then
  local ok,data=pcall(cjson.decode,html)
  if ok and type(data)=='table' and type(data.pages)=='string' then html=data.pages end
  local series=html:match('data%-series=[\'"](%d+)[\'"]')
  if series then return {items={},title=facts.title,overview=facts.overview,poster_url=facts.poster_url,
   followup={url=(config.base or base)..'wp-json/9animetv/v1/episodes/'..series..'?active=0'}} end
 end
 if config.adapter=='generic' then
  return {items={{key=base,title=facts.title~='' and facts.title or base,url=base,resolve='webpage',
   overview=facts.overview,poster_url=facts.poster_url,is_page=true}},page_url=base,title=facts.title,overview=facts.overview,has_more=false}
 end
 for attributes,body in html:gmatch('<[aA]%s+([^>]-)>(.-)</[aA]>') do
  local a=M.attrs(attributes);local address=M.absolute(base,a.href)
  local image=M.attrs(body:match('<[iI][mM][gG]%s+([^>]+)>') or '')
  local title=M.text(body);if title=='' then title=image.alt or a.title or '' end
  local same=address and url.parse(address).host==host
  local path=address and url.parse(address).path or ''
  local match=same and ((config.adapter=='9anime' and path:match('^/anime/')) or
   (config.adapter=='kissanime' and path:lower():match('^/anime/')) or
   (config.adapter=='wco' and (path:match('^/anime/') or path:lower():find('episode',1,true))) or
   config.adapter=='generic')
  if details and same then
   match=match or path:lower():find('episode',1,true)~=nil
   -- Series cards are not playable episodes.
   if config.adapter=='9anime' then match=path:match('^/watch/')~=nil or path:find('episode',1,true)~=nil end
   if config.adapter=='kissanime' then match=path:lower():find('/episode',1,true)~=nil end
  end
  if match and title~='' and #title<=300 and not seen[address] and #items<M.LIMIT and
    (not query or query=='' or config.adapter~='kissanime' or title:lower():find(query:lower(),1,true)) then
   seen[address]=true
   local number=details and tonumber(a['data-number'] or path:lower():match('episode%-(%d+)') or title:lower():match('episode%s*(%d+)'))
   local is_series=not details and (config.adapter=='9anime' or config.adapter=='kissanime') and not path:lower():find('episode',1,true)
   items[#items+1]={key=address,title=number and ('Episode '..number) or title,url=address,resolve='webpage',
    poster_url=M.absolute(base,image['data-src'] or image.src) or (details and facts.poster_url or nil),
    overview=details and facts.overview or nil,page_url=address,kind=number and 'episode' or 'movie',is_page=not number,is_series=is_series or false,
    show=number and facts.title or nil,season=number and 1 or nil,episode=number}
  end
 end
 if details then table.sort(items,function(a,b) return (a.episode or 0)<(b.episode or 0) end) end
 return {items=items,title=facts.title,overview=facts.overview,poster_url=facts.poster_url,page_url=base,
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
function M.stream(html, base)
 for tag in html:gmatch('<[mM][eE][tT][aA]%s+([^>]+)>') do
  local a=M.attrs(tag)
  if a.property=='og:video:url' or a.property=='og:video:secure_url' or a.property=='og:video' then
   local v=M.absolute(base,a.content);if v and v:match('%.(m3u8)') then return v end
   if v and (v:match('%.mp4') or v:match('%.webm')) then return v end
  end
 end
 for tag in html:gmatch('<[vV][iI][dD][eE][oO]%s+([^>]+)>') do local a=M.attrs(tag);local v=M.absolute(base,a.src);if v then return v end end
 for tag in html:gmatch('<[sS][oO][uU][rR][cC][eE]%s+([^>]+)>') do local a=M.attrs(tag);local v=M.absolute(base,a.src);if v then return v end end
 for body in html:gmatch('<script[^>]-type=[\'"]application/ld%+json[\'"][^>]*>(.-)</script>') do
  local ok,data=pcall(cjson.decode,body)
  if ok and type(data)=='table' then
   local v=M.absolute(base,data.contentUrl);if v then return v end
  end
 end
 return nil
end
return M
