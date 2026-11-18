-- The approved TMDB logo is the asset used by TMDB's own API documentation.
local Kit = require('core.ui.Kit')
local L = require('core.lib.CarbonLayout')
local M = {}
function M.new(iup)
 local source = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
 local root = source:match('^(.*)/ui/[^/]+$')
 local image
 local ok, icons = pcall(require, 'core.ui.VectorIcon')
 if ok and icons.available and root then image = icons.imageHandle(iup, { path = root .. '/assets/tmdb.svg', size = 80 }) end
 local logo = iup.flatlabel({ TITLE = image and '' or 'TMDB', IMAGE = image, RASTERSIZE = '80x80', THEMEROLE = 'reading' })
 local content = iup.hbox({ logo, iup.flatlabel({
  TITLE = 'This product uses the TMDB API but is not endorsed or certified by TMDB.\nTMDB: https://www.themoviedb.org | TVDB: https://www.thetvdb.com\nTVmaze (CC BY-SA): https://www.tvmaze.com | Jikan / MAL: https://jikan.moe\nKitsu: https://kitsu.app | Cinemeta: https://www.stremio.com',
  THEMEROLE = 'reading_muted', TEXTWRAP = 'YES', EXPAND = 'HORIZONTAL', ALIGNMENT = 'ALEFT:ACENTER' }),
  GAP = L.gap(4), ALIGNMENT = 'ACENTER', EXPAND = 'HORIZONTAL' })
 Kit.show(iup, content, false)
 local toggle = Kit.disclosure(iup, {title='Provider attribution', on_change=function(open) Kit.show(iup, content, open); iup.Refresh(content) end})
 return iup.vbox({toggle,content,GAP=L.gap(2),EXPAND='HORIZONTAL'})
end
return M
