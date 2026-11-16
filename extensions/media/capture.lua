local f=assert(io.open('scripts/ui_capture.lua','rb'))
local source=f:read('*a');f:close()
source=source:gsub('pages = leaves%(find_strip%(dlg%), {}, {}%)',[[pages = leaves(find_strip(dlg), {}, {})
local selected={};for _,page in ipairs(pages) do if page.title=='Media' or page.title=='Sources' or page.title=='Media server' or page.title=='Metadata' then selected[#selected+1]=page end end;pages=selected]])
source=source:gsub('if tool then','if tool and tool.mediaCaptureState then')
if os.getenv('LUNAR_CAPTURE_DETAIL_ONLY') then
 source=source:gsub('if views and views.states then', [[if views and views.states then
if page.title == 'Media' then views.states = { 'title', 'show' } end]])
end
assert(loadstring(source,'@'..os.getenv('LUNAR_REPO')..'/scripts/ui_capture.lua'))()
