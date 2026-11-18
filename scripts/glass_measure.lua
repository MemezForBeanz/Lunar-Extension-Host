-- Run only through cap-ui.ps1 -Script scripts/glass_measure.lua.
-- LUNAR_GLASS_MEASURE=perf|memory|idle selects the existing measurement script.
local here=debug.getinfo(1,"S").source:gsub("^@",""):gsub("\\","/")
local root=assert(here:match("^(.*)/scripts/[^/]+$"))
LUNAR_SOURCE_DIR=root
for name in pairs(package.preload) do
    local path=root.."/src/lua/"..name:gsub("%.","/")..".lua"
    local f=io.open(path,"r")
    if f then f:close(); package.preload[name]=function(...) return assert(loadfile(path))(...) end end
end
local iup=require("iup")
assert(rawget(iup,"_IMGUI"),"ImGui measurement only")
package.loaded["core.imgui.Draw"]=nil
package.loaded["core.imgui.Runtime"]=nil
require("core.imgui.Runtime").init(require("core.imgui.backend.Native"))
local exit=os.exit
os.exit=function(code) -- luacheck: ignore 122 (records the stats, then exits)
    local stats=require("core.ui.Glass").stats()
    local f=assert(io.open(arg[1].."/glass.txt","w"))
    f:write(string.format("texture bytes: %d; generations: %d\n",stats.bytes,stats.generations)); f:close()
    return exit(code)
end
arg[2]="10"
local mode=os.getenv("LUNAR_GLASS_MEASURE") or "idle"
local script=({perf="imgui_perf",memory="ui_memory",idle="imgui_idle"})[mode]
assert(script,"unknown measurement")
return dofile(root.."/scripts/"..script..".lua")
