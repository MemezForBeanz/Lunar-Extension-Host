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
rawset(_G, 'LUNAR_SOURCE_DIR', stage)
local errors = {}
iup.Message = function(title, message) errors[#errors+1]=tostring(title)..': '..tostring(message) end
iup.MainLoop = function()
 local shell = assert(rawget(_G, 'LUNAR_DEV_SHELL'))
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
 local prior_fullscreen = iup.GetAttribute(shell.host.dialog, 'FULLSCREEN')
 assert(ext.now_playing.toggleFullscreen())
 iup.Flush()
 assert(iup.GetAttribute(shell.host.dialog, 'FULLSCREEN') == 'YES', 'Fullscreen control did not change the dialog')
 shell.host:_dispatchKey(iup.K_ESC)
 iup.Flush()
 assert((iup.GetAttribute(shell.host.dialog, 'FULLSCREEN') == 'YES') == (prior_fullscreen == 'YES'), 'Escape did not restore the dialog')
 local downloads = ext._modules:require('ui.discover').new(shell.host, {
  libraries={{id=7,name='Owned test library'}},
  on_downloads=function(done) done({
   {id=1,title='Owned episode',state='running',bytes=25,total_bytes=100},
   {id=2,title='Retry fixture',state='failed',error='Fixture error'},
  }) end,
 })
 downloads.setProviders({{id='video-page',kind='website',name='Owned fixture'}})
 local download_dialog=iup.dialog({downloads.widget,rastersize='1000x720',title='Isolated download controls'})
 iup.Show(download_dialog);downloads.tick();iup.Refresh(download_dialog);iup.LoopStep();iup.Destroy(download_dialog)
 assert(#errors==0, table.concat(errors, '\n'))
 print('Media UI constructed, mapped and refreshed: library, title/match, discovery, server and player')
 ext:shutdown()
 shell.host:removeOwned(ext)
end
dofile(repo..'/src/lua/core/main.lua')
