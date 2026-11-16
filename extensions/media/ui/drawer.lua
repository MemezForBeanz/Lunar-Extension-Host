--- Media inspector backdrop. Native IUP keeps the ordinary split inspector.
local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local Reactor = require("core.ui.ThemeReactor")
local tree = require("core.lib.tree")
local tint = require("libs.tint")
local M = {}
function M.new(iup, page)
    local api = {}
    if not rawget(iup, "_IMGUI") then
        function api:fit() end
        function api:sync() end
        return api
    end
    -- Canvas fills blend directly; flatlabel first repaints its opaque parent.
    local scrim = iup.canvas{BORDER="NO", _IUPLUNAR_OVERLAY="YES", FLOATING="YES", CANFOCUS="NO"}
    local shadow = iup.canvas{BORDER="NO", _IUPLUNAR_OVERLAY="YES", FLOATING="YES", CANFOCUS="NO"}
    iup.Append(page.inspectorOverlay, scrim)
    iup.Append(page.inspectorOverlay, shadow)
    local active
    function api:_afterThemePass()
        local p = Reactor.palette()
        if not p.bg then return end
        iup.SetAttribute(scrim, "BGCOLOR", p.bg .. " 160")
        local light = tint.isLight(p.bg)
        iup.SetAttribute(shadow, "BGCOLOR", (light and p.text or p.bg) .. (light and " 48" or " 200"))
        iup.SetAttribute(page.inspector, "FRAME", active and "YES" or "NO")
        iup.SetAttribute(page.inspector, "FRAMECOLOR", p.borderStrong01 or p.border)
    end
    function api:fit(width)
        active = page.inspectorOpen and width < L.PAGE.config + L.PAGE.main_min + L.PAGE.inspector + L.PAGE.padding * 2 + L.PAGE.gutter * 2
        for _, w in ipairs({scrim, shadow}) do
            Kit.show(iup, w, active)
            iup.SetAttribute(w, "FLOATING", "YES")
        end
        if not active then self:_afterThemePass(); return end
        local nav = page.config and width - L.PAGE.padding * 2 >= L.PAGE.config_break and page.configSize + L.PAGE.gutter or 0
        local available = width - L.PAGE.padding * 2 - nav
        local height = tonumber((iup.GetAttribute(page.inspectorFrame, "RASTERSIZE") or ""):match("x(%d+)$")) or L.PAGE.dock
        iup.SetAttribute(scrim, "POSITION", "0,0")
        iup.SetAttribute(scrim, "RASTERSIZE", L.size(available, height))
        iup.SetAttribute(shadow, "POSITION", math.max(0, available - page.inspectorSize - L.px(3)) .. "," .. L.px(2))
        iup.SetAttribute(shadow, "RASTERSIZE", L.size(page.inspectorSize + L.px(3), height))
        -- Paint the floating inspector after its backdrop and shadow.
        tree.place(iup, page.inspectorOverlay, page.inspector)
        self:_afterThemePass()
    end
    function api:sync()
        if active and not page.inspectorOpen then self:fit(page.width) end
    end
    Reactor.register(api)
    return api
end
return M
