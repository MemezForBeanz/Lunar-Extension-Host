local ffi = require("ffi")
local function to_image(addr, w, h)
    if not addr or w <= 0 or h <= 0 then return nil, "invalid image dimensions" end
    local p = ffi.cast("const uint8_t*", addr)
    local bytes = ffi.string(p, w * h * 4)
    return require("core.imgui.widgets.image").imagergba{ WIDTH = w, HEIGHT = h, PIXELS = bytes }
end
return { to_image = to_image, sizeofs = require("svgicon_sizes").sizeofs }
