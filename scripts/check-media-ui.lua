-- Run in the development GUI host with LUNAR_MEDIA_TEST_ROOT set to a staged package.
-- Uses an isolated profile, no real server credentials, and no interactive input.
local repo = assert(LUNAR_SOURCE_DIR, 'A development GUI build is required')
local stage = assert(os.getenv('LUNAR_MEDIA_TEST_ROOT'), 'Set LUNAR_MEDIA_TEST_ROOT')
package.path = repo..'/src/lua/?.lua;'..repo..'/vendor/luarocks-tree/share/lua/5.1/?.lua;'..repo..'/vendor/luarocks-tree/share/lua/5.1/?/init.lua;'..repo..'/vendor/copas/?.lua;'..package.path
local iup = require('iup')
local platform = require('core.platform')
platform.config_dir = function() return stage..'/profile/config' end
platform.cache_dir = function() return stage..'/profile/cache' end
platform.secret_get = function() return nil end
_G.arg = {}
LUNAR_SOURCE_DIR = stage
local errors = {}
iup.Message = function(title, message) errors[#errors+1]=tostring(title)..': '..tostring(message) end
iup.MainLoop = function()
 local shell = assert(LUNAR_DEV_SHELL)
 local ext = assert(shell.host._owner_by_extension_id.media, table.concat(errors, '\n'))
 assert(ext.runtime.state=='ready', 'Contained player runtime was not ready')
 local Client = ext._modules:require('libs.client')
 local model = Client.modelFrom({{id=1,name='Films',items={{id=1,title='Example Film',year=2020,kind='movie',overview='A metadata description.',genres='Drama'}}}},
  {analysis='on',files=1,metadata={configured=false,state='needs_token',matched=0,queued=0},runtime={state='ready'}})
 ext.library.setModel(model)
 ext.library.open(model.films[1])
 ext.sources_page.setData({}, {{id='9anime',kind='website',name='9anime',summary='Browse series and episodes'}})
 ext.server.setModel(model)
 assert(ext.metadata_client and ext.metadata_page, 'Standalone metadata was not constructed')
 for _, index in ipairs({1,3,4,5,2}) do shell.host:focusTab(ext,index);iup.Refresh(shell.host.tabs);iup.LoopStep() end
 assert(#errors==0, table.concat(errors, '\n'))
 print('Media UI constructed, mapped and refreshed: library, title/match, discovery, server and player')
 ext:shutdown()
 shell.host:removeOwned(ext)
end
dofile(repo..'/src/lua/core/main.lua')
