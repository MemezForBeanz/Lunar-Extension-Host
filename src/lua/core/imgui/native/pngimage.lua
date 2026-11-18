local function to_image(path, height)
    local pixels, w, h = require("imagecodec").png_rgba(path)
    if not pixels then return nil, w end
    local target = tonumber(height)
    if target and target > 0 and target ~= h then
        local nw = math.max(1, math.floor(w * target / h + 0.5))
        -- Keep decoding in the native module; callers still receive a valid
        -- RGBA image when no scaling is requested.
        if nw ~= w then return nil, "PNG scaling is unavailable in the ImGui codec" end
    end
    return require("core.imgui.widgets.image").imagergba{ WIDTH = w, HEIGHT = h, PIXELS = pixels }
end
return { to_image = to_image }
