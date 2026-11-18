local Glass=require("core.ui.Glass")
local audit=require("scripts.theme_contrast")
describe("Lunar glass",function()
    after_each(function() Glass.setEnabled(true); Glass.clear() end)
    for _,name in ipairs({"LunarDarkTheme","LunarLightTheme"}) do
        it(name.." meets text and control contrast",function()
            local failures,count=audit.audit(require("core.classes.Themes."..name):new())
            assert.is_true(count>100)
            assert.same({},failures)
        end)
    end
    it("generates stable pixels and a smaller blurred copy",function()
        local p=require("core.classes.Themes.LunarDarkTheme"):new():palette()
        local a,w,h,b,bw,bh=Glass.pixels(p,128,128)
        local again=Glass.pixels(p,128,128)
        assert.equal(a,again)
        assert.equal(w*h*4,#a); assert.equal(bw*bh*4,#b)
        assert.is_true(#b<#a)
        assert.is_true((1920*1088/4+1920*1088/16)*4<3*1024*1024)
    end)
    it("has a live opaque fallback",function()
        Glass.setEnabled(false)
        assert.is_false(Glass.enabled())
        assert.equal(0,Glass.stats().bytes)
    end)
    it("keeps the silver bloom within seven percent linear luminance and off the right floor",function()
        local p=require("core.classes.Themes.LunarDarkTheme"):new():palette()
        local pixels,w,h=Glass.pixels(p,256,256)
        local function light(v)
            v=v/255
            return v<=.04045 and v/12.92 or ((v+.055)/1.055)^2.4
        end
        local left=pixels:byte(1)
        local right=pixels:byte((w-1)*4+1)
        local foot=pixels:byte((h-1)*w*4+1)
        assert.is_true(light(left)-light(right)>.065)
        assert.is_true(light(left)-light(right)<.075)
        assert.is_true(foot>left-12)
        assert.equal(11,right)
    end)
    it("keeps chrome labels AA at the actual brightest sampled bloom",function()
        local lunar=require("core.classes.Themes.lunar_rules")
        for _,name in ipairs({"LunarDarkTheme","LunarLightTheme"}) do
            local theme=require("core.classes.Themes."..name):new()
            local p=theme:palette()
            local pixels=Glass.pixels(p,128,128)
            local r,g,b=pixels:byte(1,3)
            for _,rule in pairs(theme:rules()) do
                if rule.glass and rule.glass~="card" and rule.fg then
                    local floating=rule.glass=="floating" or rule.glass=="content"
                    local tint=floating and (p.glassDark and p.layer03 or "255 255 255") or p.layer01
                    local a=floating and p.glassFloatingAlpha or p.glassChromeAlpha
                    local channels={r,g,b}; local i=0
                    for v in tint:gmatch("%d+") do
                        i=i+1; channels[i]=math.floor(channels[i]*(1-a)+tonumber(v)*a)
                    end
                    assert.is_true(lunar.contrast(rule.fg,table.concat(channels," "))>=4.5)
                end
            end
        end
    end)
    it("paints content without adding a second rim or shadow",function()
        local B=require("core.imgui.backend.Null").new()
        local dc=require("core.imgui.Draw").new(B)
        local p=require("core.classes.Themes.LunarDarkTheme"):new():palette()
        B.frame_begin(); dc:begin(128,128)
        Glass.paint(dc,0,0,128,32,"content",p)
        B.frame_end()
        for _,call in ipairs(B.lastFrame()) do assert.is_not.equal("rect",call[1]); assert.is_not.equal("line",call[1]) end
    end)
    it("reuses two textures, releases them on a size change, and emits UV sampling",function()
        local B=require("core.imgui.backend.Null").new()
        local dc=require("core.imgui.Draw").new(B)
        local p=require("core.classes.Themes.LunarDarkTheme"):new():palette()
        dc:begin(128,128)
        Glass.paint(dc,0,0,128,32,"chrome",p)
        local generations=Glass.stats().generations
        Glass.paint(dc,0,32,128,32,"chrome",p)
        assert.equal(generations,Glass.stats().generations)
        local count=0; for _ in pairs(B.textures) do count=count+1 end
        assert.equal(2,count)
        dc:begin(256,128); Glass.paint(dc,0,0,256,32,"chrome",p)
        count=0; for _ in pairs(B.textures) do count=count+1 end
        assert.equal(2,count)
        Glass.clear(); assert.is_nil(next(B.textures))
    end)
    it("passes image subrectangles through the Null backend",function()
        require("core.imgui.widgets.image")
        local E=require("core.imgui.Element")
        local B=require("core.imgui.backend.Null").new()
        local dc=require("core.imgui.Draw").new(B)
        local img=E.new("imagergba",{width=1,height=1,pixels=string.char(1,2,3,255)})
        B.frame_begin(); dc:begin(100,100)
        dc:image(img,0,0,10,10,{u1=.1,v1=.2,u2=.7,v2=.8})
        B.frame_end()
        local found
        for _,call in ipairs(B.lastFrame()) do if call[1]=="image" then found=call end end
        assert.is_not_nil(found)
        assert.equal(.1,found[7]); assert.equal(.8,found[10])
        E.destroy(img)
    end)
    it("keeps native-parent fills from overwriting a prepainted glass surface",function()
        local E=require("core.imgui.Element")
        require("core.imgui.widgets.flatlabel")
        local original=E.globals.DLGBGCOLOR
        E.globals.DLGBGCOLOR="240 240 240"
        local el=E.new("flatlabel",{TITLE="Popup"})
        local count=0
        local dc={material={glass="floating"},fill=function() count=count+1 end}
        local st={x=0,y=0,w=100,h=30}
        local F=require("core.imgui.widgets.flatdraw")
        F.parentBackground(el,dc,st)
        assert.equal(0,count)
        dc.material=nil
        F.parentBackground(el,dc,st)
        assert.equal(1,count)
        E.globals.DLGBGCOLOR=original
        E.destroy(el)
    end)
end)
