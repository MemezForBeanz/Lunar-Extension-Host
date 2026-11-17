local ThemeManager = require("core.classes.ThemeManager")
local Tokens = require("core.lib.MotionTokens")
local box = require("spec.support.config_sandbox")
local Settings = require("core.classes.SettingsManager")
local json = require("cjson")

describe("Carbon v11 modes", function()
    local names = { "CarbonWhite", "CarbonG10", "CarbonG90", "CarbonG100" }
    it("keeps complete source tokens and opaque legacy palette aliases", function()
        for _, name in ipairs(names) do
            local t = require("core.classes.Themes." .. name .. "Theme"):new()
            local p = t:palette()
            assert.equal("carbon", t:family())
            assert.equal(0, p.radius)
            assert.is_false(p.glass)
            assert.equal(p.textPrimary, p.text)
            assert.equal(p.interactive, p.accent)
            assert.equal(p.supportError, p.error)
            assert.is_string(p.carbonTokens.skeletonBackground)
            assert.is_string(p.carbonTokens.focusInset)
            assert.is_table(p.carbonTokens.bodyCompact01)
            assert.equal("IBM Plex Sans, 11", p.font)
        end
    end)
    it("pairs each mode reversibly", function()
        local m = setmetatable({}, { __index = ThemeManager })
        for a,b in pairs({ carbon_white = "carbon_g100", carbon_g10 = "carbon_g90" }) do
            assert.equal(b, m:counterpart(a))
            assert.equal(a, m:counterpart(b))
        end
    end)
    it("uses neutral scrollbar tokens for every Carbon role", function()
        for _, name in ipairs(names) do
            local t = require("core.classes.Themes." .. name .. "Theme"):new()
            local p, rules = t:palette(), t:rules()
            for _, role in ipairs({"page_column", "outputlog", "list", "flatrows", "flatrows_plain", "flatgrid_plain"}) do
                assert.equal(p.borderStrong01 or p.border, rules[role].scrollfg)
                assert.equal(p.text, rules[role].scrollpress)
                assert.equal(8, rules[role].scrollsize)
            end
        end
    end)
    it("provides solid primary buttons and bottom-border fields", function()
        for _, name in ipairs(names) do
            local t = require("core.classes.Themes." .. name .. "Theme"):new()
            local p, r = t:palette(), t:rules()
            assert.equal(p.buttonPrimary, r.primary_btn.bg)
            assert.equal(p.buttonPrimaryHover, r.primary_btn.hover)
            assert.equal(p.buttonPrimaryActive, r.primary_btn.pressed)
            assert.equal(40, r.primary_btn.controlheight)
            assert.equal("BOTTOM", r.text.borderstyle)
            assert.equal(p.focus, r.text.focuscolor)
            assert.equal(p.text, r.flatrows.seltext)
            assert.equal(0, r.flatrows.itemradius)
            assert.equal("16x4", r.flatlist.padding)
            assert.equal("16x8", r.flattabs_sub.tabspadding)
            assert.equal(p.toggleOff, r.flattoggle.switchoff)
            assert.equal(p.layerSelected01, r.flattoggle.pressed)
            assert.equal(p.text, r.flattoggle.pressedtext)
            assert.equal(p.iconPrimary, r.flattoggle.checkon)
            assert.equal(p.field01, r.dropbutton.pressed)
            assert.equal(p.text, r.dropbutton.pressedtext)
            assert.is_not.equal(r.primary_btn.bg, r.primary_btn.inactivebg)
            assert.is_not.equal(r.actionbutton.fg, r.actionbutton.inactivefg)
            assert.equal(p.layer01, r.actionbutton.bg)
            assert.equal(p.layerSelected02, r.flatrows_plain.selbg)
            assert.equal(p.text, r.flatrows_plain.seltext)
            assert.equal("LEADING", r.settings_nav_on.borderstyle)
        end
    end)
end)

describe("Carbon side-nav leading marker", function()
    it("draws the accent only on the leading edge", function()
        local iup = require("core.imgui.iup")
        local F = require("core.imgui.widgets.flatdraw")
        local e = iup.flatbutton{ CARBONSTYLE = "YES", BORDERSTYLE = "LEADING" }
        local drawn
        local dc = { fill = function(_, x,y,w,h) drawn = {x,y,w,h} end }
        F.borderAttrib(e, dc, 10,20,0,99,0,39,3,"15 98 254","255 255 255",true)
        assert.same({10,20,3,40}, drawn)
    end)
end)

describe("Carbon native scrollbar", function()
    it("uses the whole track without arrow hit targets and paints a neutral thin thumb", function()
        local iup = require("core.imgui.iup")
        local Element = require("core.imgui.Element")
        local Scroll = require("core.imgui.widgets.winscrollbar")
        local widget = iup.text{ CARBONSTYLE="YES", SB_BACKCOLOR="244 244 244", SB_FORECOLOR="141 141 141" }
        local bar = { x=0,y=0,w=17,h=100,max=1000,page=100,pos=0 }
        Scroll.set(widget, bar)
        assert.equal(0, Scroll.geometry(bar).arrow)
        local fills = {}
        Scroll.draw(widget, Element.state(widget), {fill=function(_,x,y,w,h,color) fills[#fills+1]={x,y,w,h,color} end})
        assert.equal("244 244 244", fills[1][5])
        assert.equal(4, fills[2][3])
        assert.equal("141 141 141", fills[2][5])
        iup.Destroy(widget)
    end)
end)

describe("Carbon table density", function()
    it("maps compact and two-line rows to the same two sizes across pages", function()
        local iup = require("core.imgui.iup")
        local Classes = require("core.imgui.Classes")
        for requested, expected in pairs({[32]=32,[36]=32,[48]=48,[56]=48}) do
            local widget = iup.flatrows{CARBONSTYLE="YES",ROWHEIGHT=tostring(requested)}
            local _, height = Classes.get("flatrows").natural(widget)
            assert.equal(expected*5, height)
            iup.Destroy(widget)
        end
    end)
end)

describe("theme-neutral field underline", function()
    it("draws a one-pixel bottom edge without a rectangle", function()
        local iup = require("core.imgui.iup")
        local F = require("core.imgui.widgets.flatdraw")
        local e = iup.dropbutton{ BORDERSTYLE = "BOTTOM" }
        local drawn
        local dc = { line = function(_, x1,y1,x2,y2,color,width) drawn = {x1,y1,x2,y2,width} end }
        F.borderAttrib(e, dc, 10,20,0,99,0,39,1,"100 100 100","255 255 255",true)
        assert.same({10,59,109,59,1}, drawn)
    end)
end)

describe("Classic settings migration", function()
    it("migrates all three settings, saves once, and preserves extension data", function()
        local root = box.new_root("carbon_migration")
        box.mkdir(box.app_dir(root))
        local path = box.join(box.app_dir(root), "settings.json")
        local f = assert(io.open(path, "w"))
        f:write(json.encode({ settings_schema = 2, theme = "classic", theme_light = "classic",
            theme_dark = "classic_dark", extension_option = "keep" })); f:close()
        box.with_root(root, function()
            local s = Settings:new(); s:load()
            assert.equal("carbon_white", s:get("theme"))
            assert.equal("carbon_white", s:get("theme_light"))
            assert.equal("carbon_g100", s:get("theme_dark"))
            assert.equal("keep", s:get("extension_option"))
            local again = Settings:new(); again:load()
            assert.equal("carbon_white", again:get("theme"))
        end)
    end)
end)

describe("Carbon motion audit", function()
    it("keeps disclosures on screen and pairs popup entrance/exit curves", function()
        assert.equal("standard", Tokens.role("settings_expand").curve)
        assert.equal(110, Tokens.role("disclosure").duration)
        for _, kind in ipairs({ "menu", "dropdown", "tooltip", "notification" }) do
            assert.equal("entrance", Tokens.role(kind .. "_enter").curve)
            assert.equal("exit", Tokens.role(kind .. "_exit").curve)
        end
        assert.equal(500, Tokens.role("tooltip_enter").delay)
    end)
end)


describe("Carbon field icon", function()
    it("keeps a fixed-size magnifier inside the label despite field padding", function()
        local iup = require("core.imgui.iup")
        local Element = require("core.imgui.Element")
        local Classes = require("core.imgui.Classes")
        local icon = iup.user{ WIDTH = "16", HEIGHT = "16" }
        iup.SetHandle("carbon_search_icon_spec", icon)
        local label = iup.label{ IMAGE = "carbon_search_icon_spec", TITLE = "", PADDING = "16x8", CARBONSTYLE = "YES" }
        local st = Element.state(label)
        st.x, st.y, st.w, st.h = 0, 0, 16, 16
        local drawn
        local dc = { image = function(_, _, x,y,w,h) drawn = {x,y,w,h} end }
        Classes.get("label").draw(label, st, dc)
        assert.same({0,0,16,16}, drawn)
    end)
end)
