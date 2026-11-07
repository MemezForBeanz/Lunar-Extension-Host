-- Opt-in integration check of public source browsing/resolution. No saved user catalog.
local root = os.getenv('LUNAR_REPO') or '.'
package.path = root..'/extensions/media-server/?.lua;'..root..'/src/lua/?.lua;'..root..'/vendor/luasec/src/?.lua;'..root..'/vendor/luasocket/src/?.lua;'..root..'/vendor/luarocks-tree/share/lua/5.1/?.lua;'..root..'/vendor/luarocks-tree/share/lua/5.1/?/init.lua;'..root..'/vendor/copas/?.lua;'..package.path
local Web = require('libs.websources')
local Discovery = require('libs.discovery')
local http = require('core.lib.http')
local ca = os.getenv('LUNAR_CA_FILE') or root..'/build/win/bin/certs/cacert.pem'
local d = Discovery.new({ providers = function() return Web.SITES end,
 http = function(request, done) request.cafile=ca; done(http.request(request)) end,
 spawn = function() error('This check expects a directly playable public video.') end })
local job = assert(d:begin({provider='9anime',url='https://9anime.or.at/anime/one-piece/',details=true}))
for _=1,8 do d:tick(); if d:poll(job.id).state=='ready' then break end end
local result = assert(d:poll(job.id))
assert(result.state=='ready', result.error)
assert(#result.result.items>0, 'No episodes found')
print('9anime episode catalog: '..#result.result.items..' entries')
local latest = result.result.items[#result.result.items]
local resolved, problem
d:resolve(latest.url, function(answer, why) resolved,problem=answer,why end)
for _=1,8 do d:tick(); if resolved or problem then break end end
assert(resolved, problem or 'Video did not resolve')
local response, why = http.request({url=resolved.url,method='HEAD',headers={Referer=resolved.headers[1]:sub(10)},timeout=15,max_bytes=65536,cafile=ca})
assert(response and response.ok, why or (response and tostring(response.status)))
print('9anime latest episode: resolved direct stream; authenticated-by-site HEAD succeeded')
for _, provider in ipairs({'kissanime','wco'}) do
 local lookup=assert(d:begin({provider=provider}))
 for _=1,8 do d:tick();local state=d:poll(lookup.id).state;if state=='ready' or state=='failed' then break end end
 local page=d:poll(lookup.id)
 if page.state=='ready' then print(provider..' catalog: '..#page.result.items..' entries')
 else print(provider..' catalog: '..tostring(page.error or page.state)) end
end
d:close()
