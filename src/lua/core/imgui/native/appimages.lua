local names = {"lunar_icon_32"}
local function load(name)
    if name ~= "lunar_icon_32" then return nil, "no embedded image named '" .. tostring(name) .. "'" end
    local f = io.open((LUNAR_EXE_DIR or "") .. "\\assets\\lunar-icon-32.png", "rb")
    if not f then return nil, "embedded image unavailable" end
    f:close()
    return require("core.imgui.native.pngimage").to_image((LUNAR_EXE_DIR or "") .. "\\assets\\lunar-icon-32.png")
end
return {load = load, names = function() return names end}
