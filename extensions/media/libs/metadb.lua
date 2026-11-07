-- Public metadata adapters. Fixed HTTPS endpoints; no relay and no shared credentials.
local json = require('cjson')
local tmdb = require('libs.tmdb')
local M = {}
M.providers = {
 {id='cinemeta',name='Cinemeta',keyless=true,kinds={movie=true,show=true},source_url='https://www.stremio.com'},
 {id='tvmaze',name='TVmaze',keyless=true,kinds={show=true},source_url='https://www.tvmaze.com',license='CC BY-SA'},
 {id='jikan',name='Jikan / MyAnimeList',keyless=true,kinds={movie=true,show=true},source_url='https://jikan.moe'},
 {id='kitsu',name='Kitsu',keyless=true,kinds={movie=true,show=true},source_url='https://kitsu.app'},
 {id='imdbot',name='IMDbOT (unofficial lookup)',keyless=true,experimental=true,kinds={movie=true,show=true},source_url='https://imdb.iamidiotareyoutoo.com'},
 {id='tmdb',name='TMDB (optional token)',kinds={movie=true,show=true},source_url='https://www.themoviedb.org'},
 {id='tvdb',name='TheTVDB (optional key)',kinds={movie=true,show=true},source_url='https://www.thetvdb.com'},
}
function M.provider(id) for _,p in ipairs(M.providers) do if p.id==id then return p end end end
local function obj(v) return type(v)=='table' and v or {} end
local function str(v,n) return type(v)=='string' and v~='' and v:sub(1,n or 4096) or nil end
local function num(v) local n=tonumber(v);return n and n==n and math.abs(n)<1e12 and n or nil end
local function year(v) return tonumber(tostring(v or ''):match('^(%d%d%d%d)')) end
local function list(v) return type(v)=='table' and v or {} end
local function strings(v)
 local out={};for _,s in ipairs(list(v)) do if #out>=32 then break end;if str(s,160) then out[#out+1]=str(s,160) end end;return out
end
function M.plain(v)
 local s=str(v,32768);if not s then return end
 return s:gsub('<[bB][rR]%s*/?>','\n'):gsub('</[pP]>','\n'):gsub('<[^>]*>',''):gsub('&nbsp;',' '):gsub('&amp;','&'):gsub('&quot;','"'):gsub('&#39;',"'"):gsub('&lt;','<'):gsub('&gt;','>')
end
-- Only known provider image hosts may be fetched. No URLs supplied by the user are followed.
function M.image(v)
 if type(v)~='string' or #v>2048 or v:find('[%s%c]') then return end
 local host=v:match('^https://([^/]+)/');local allowed={['image.tmdb.org']=true,['static.tvmaze.com']=true,['cdn.myanimelist.net']=true,['media.kitsu.app']=true,['media.kitsu.io']=true,['images.metahub.space']=true,['m.media-amazon.com']=true,['artworks.thetvdb.com']=true,['www.thetvdb.com']=true}
 return allowed[host] and v or nil
end
function M.validId(provider,id)
 if provider=='cinemeta' or provider=='imdbot' then return type(id)=='string' and id:match('^tt%d+$') and #id<=16 and id or nil end
 local n=num(id);return n and n>=1 and n==math.floor(n) and tostring(n) or nil
end
function M.request(provider,op,work,value)
 local p=M.provider(provider);if not p or not p.kinds[work.kind] then return nil,'This provider does not support that media type.' end
 local kind=work.kind=='show' and 'series' or 'movie'
 local query=op=='search' and str(value or work.title,200)
 local id=op~='search' and M.validId(provider,value)
 if op~='search' and op~='details' then return nil,'Unsupported metadata operation.' end
 if op=='search' and (not query or query:match('^%s*$')) then return nil,'Enter a title to search.' end
 if op=='details' and not id then return nil,'Invalid provider id.' end
 local q=tmdb.escape(query or '')
 if provider=='cinemeta' then return 'https://v3-cinemeta.strem.io/'..(op=='search' and 'catalog/'..kind..'/top/search='..q..'.json' or 'meta/'..kind..'/'..id..'.json') end
 if provider=='tvmaze' then return 'https://api.tvmaze.com/'..(op=='search' and 'search/shows?q='..q or 'shows/'..id..'?embed=cast') end
 if provider=='jikan' then return 'https://api.jikan.moe/v4/anime'..(op=='search' and '?q='..q..'&limit=20&sfw=true'..(work.kind=='movie' and '&type=movie' or '') or '/'..id..'/full') end
 if provider=='kitsu' then return 'https://kitsu.io/api/edge/anime'..(op=='search' and '?filter%5Btext%5D='..q..'&page%5Blimit%5D=20' or '/'..id..'?include=genres') end
 if provider=='imdbot' then if op=='details' then return nil,'IMDbOT supplies title lookup only; use Cinemeta for this IMDb id.' end;return 'https://imdb.iamidiotareyoutoo.com/search?q='..q end
 if provider=='tmdb' then if op=='search' then return tmdb.searchUrl(work,value) end;return tmdb.detailUrl(work.kind,tonumber(id)) end
 if provider=='tvdb' then return 'https://api4.thetvdb.com/v4/'..(op=='search' and 'search?query='..q..'&type='..kind..'&limit=20' or (kind=='series' and 'series/' or 'movies/')..id..'/extended?meta=translations') end
end
local function animeKind(kind,t) local movie=type(t)=='string' and t:lower()=='movie';return kind=='movie' and movie or kind=='show' and not movie end
local function common(provider,kind,id,title)
 return {provider=provider,kind=kind,id=id,external_id=tostring(id),title=title,genres={},people={},cast={}}
end
local function convert(provider,kind,r)
 r=obj(r);local id=M.validId(provider,(provider=='tvdb' and r.tvdb_id) or r.id or r.mal_id or r['#IMDB_ID'])
 if not id then return end
 local a=provider=='kitsu' and obj(r.attributes) or r
 if provider=='jikan' and not animeKind(kind,r.type) then return end
 if provider=='kitsu' and not animeKind(kind,a.subtype) then return end
 local title=str(a.name) or str(a.title_english) or str(a.title) or str(a.canonicalTitle) or str(a['#TITLE'])
 if not title then return end
 local f=common(provider,kind,id,title)
 if provider=='cinemeta' then
  f.overview=M.plain(r.description);f.year=year(r.releaseInfo or r.year or r.released);f.poster_url=M.image(r.poster);f.backdrop_url=M.image(r.background)
  f.rating=num(r.imdbRating);f.genres=strings(r.genres or r.genre);f.people=strings(r.cast);f.source_url='https://www.imdb.com/title/'..id..'/'
 elseif provider=='tvmaze' then
  f.overview=M.plain(r.summary);f.year=year(r.premiered);f.poster_url=M.image(obj(r.image).original or obj(r.image).medium);f.rating=num(obj(r.rating).average);f.genres=strings(r.genres)
  f.studio=str(obj(r.network).name) or str(obj(r.webChannel).name);f.source_url='https://www.tvmaze.com/shows/'..id
  for _,c in ipairs(list(obj(r._embedded).cast)) do if #f.cast>=32 then break end;local name=str(obj(c.person).name,160);if name then f.people[#f.people+1]=name;f.cast[#f.cast+1]={name=name,role=str(obj(c.character).name,240),profile_url=M.image(obj(obj(c.person).image).medium)} end end
 elseif provider=='jikan' then
  f.original_title=str(r.title_japanese);f.overview=M.plain(r.synopsis);f.year=num(r.year) or num(obj(obj(obj(r.aired).prop).from).year);f.poster_url=M.image(obj(obj(r.images).jpg).large_image_url or obj(obj(r.images).jpg).image_url)
  f.rating=num(r.score);f.content_rating=str(r.rating,120);f.studio=str(obj(list(r.studios)[1]).name,240);f.source_url='https://myanimelist.net/anime/'..id
  for _,g in ipairs(list(r.genres)) do if #f.genres<32 and str(g.name,120) then f.genres[#f.genres+1]=str(g.name,120) end end
 elseif provider=='kitsu' then
  f.original_title=str(obj(a.titles).ja_jp);f.overview=M.plain(a.synopsis or a.description);f.year=year(a.startDate);f.poster_url=M.image(obj(a.posterImage).large or obj(a.posterImage).original);f.backdrop_url=M.image(obj(a.coverImage).large or obj(a.coverImage).original)
  f.rating=num(a.averageRating) and num(a.averageRating)/10;f.content_rating=str(a.ageRating,120);f.source_url='https://kitsu.app/anime/'..id
 elseif provider=='imdbot' then
  f.year=num(r['#YEAR']);f.poster_url=M.image(r['#IMG_POSTER']);f.source_url='https://www.imdb.com/title/'..id..'/'
 elseif provider=='tvdb' then
  local tr=obj(obj(r.translations).overviewTranslations);local overview=str(r.overview)
  for _,t in ipairs(tr) do if t.language=='eng' then overview=str(t.overview);break end end
  f.overview=M.plain(overview);f.year=year(r.year or r.firstAired);f.poster_url=M.image(r.image or r.image_url);f.source_url='https://www.thetvdb.com/'..(kind=='show' and 'series/' or 'movies/')..(str(r.slug,200) or id)
  for _,g in ipairs(list(r.genres)) do if #f.genres<32 and str(g.name,120) then f.genres[#f.genres+1]=str(g.name,120) end end
  for _,c in ipairs(list(r.characters)) do if #f.cast>=32 then break end;local name=str(c.personName,160);if name then f.people[#f.people+1]=name;f.cast[#f.cast+1]={name=name,role=str(c.name,240),profile_url=M.image(c.personImgURL)} end end
  -- TVDB score is popularity, not a viewer rating.
 end
 if f.rating and (f.rating<0 or f.rating>10) then f.rating=nil end
 return f
end
function M.decode(raw)
 if type(raw)=='table' then return raw end
 local ok,data=pcall(json.decode,raw or '');return ok and type(data)=='table' and data or nil
end
function M.results(provider,kind,raw)
 local data=M.decode(raw);if not data then return nil,'Provider returned invalid JSON.' end
 if provider=='tmdb' then local rows,why=tmdb.results(data,kind);for _,r in ipairs(rows or {}) do r.provider='tmdb' end;return rows,why end
 if data.ok==false or data.error or data.status=='failure' then return nil,'Provider lookup is currently unavailable.' end
 local rows=provider=='cinemeta' and data.metas or provider=='tvmaze' and data or provider=='imdbot' and data.description or data.data
 if type(rows)~='table' then return nil,'Provider search response has no results list.' end
 local out={};for _,r in ipairs(rows) do if #out>=20 then break end;local f=convert(provider,kind,provider=='tvmaze' and obj(r).show or r);if f then out[#out+1]=f end end;return out
end
function M.details(provider,kind,id,raw)
 id=M.validId(provider,id);if not id then return nil,'Invalid provider id.' end
 local data=M.decode(raw);if not data then return nil,'Provider returned invalid JSON.' end
 if provider=='tmdb' then return tmdb.details(data,kind,tonumber(id)) end
 local row=provider=='cinemeta' and data.meta or provider=='tvmaze' and data or data.data
 local f=convert(provider,kind,row);if not f or f.external_id~=id then return nil,'Provider detail response has the wrong id or media type.' end
 if provider=='kitsu' then for _,g in ipairs(list(data.included)) do if g.type=='genres' and str(obj(g.attributes).name,120) and #f.genres<32 then f.genres[#f.genres+1]=str(g.attributes.name,120) end end end
 return f
end
M.pick=tmdb.pick
-- The authenticated desktop may submit public facts fetched with its private local token.
-- Rebuild a bounded, typed record before touching SQLite; never accept a credential or URL verbatim.
function M.validateFacts(raw,kind)
 if type(raw)~='table' then return nil,'Metadata facts must be an object.' end
 local provider=M.provider(raw.provider);local id=provider and M.validId(provider.id,raw.external_id)
 if not provider or not provider.kinds[kind] or not id or not str(raw.title,4096) then return nil,'Invalid metadata provider, id or title.' end
 local f=common(provider.id,kind,id,str(raw.title,4096))
 for _,key in ipairs({'overview','original_title','tagline','studio','content_rating'}) do f[key]=str(raw[key],key=='overview' and 32768 or 4096) end
 f.year=num(raw.year);if f.year and (f.year<1800 or f.year>2200 or f.year~=math.floor(f.year)) then f.year=nil end
 f.rating=num(raw.rating);if f.rating and (f.rating<0 or f.rating>10) then f.rating=nil end
 f.poster_url=M.image(raw.poster_url);f.backdrop_url=M.image(raw.backdrop_url);f.genres=strings(raw.genres);f.people=strings(raw.people)
 for _,c in ipairs(list(raw.cast)) do if #f.cast>=32 then break end;c=obj(c);if str(c.name,160) then f.cast[#f.cast+1]={name=str(c.name,160),role=str(c.role,240),profile_url=M.image(c.profile_url)} end end
 local links={cinemeta='https://www.imdb.com/title/',imdbot='https://www.imdb.com/title/',tvmaze='https://www.tvmaze.com/shows/',jikan='https://myanimelist.net/anime/',kitsu='https://kitsu.app/anime/',tmdb='https://www.themoviedb.org/'..(kind=='show' and 'tv/' or 'movie/'),tvdb='https://www.thetvdb.com/dereferrer/'..(kind=='show' and 'series/' or 'movie/')}
 f.source_url=links[provider.id]..id
 return f
end
return M
