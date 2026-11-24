local Glass=require("core.ui.Glass")
local audit=require("scripts.theme_contrast")
local Null=require("core.imgui.backend.Null")
local Draw=require("core.imgui.Draw")

local function palette(name) return require("core.classes.Themes."..name):new():palette() end
local function ops(B)
    local out={}
    for _,call in ipairs(B.lastFrame()) do out[call[1]]=(out[call[1]] or 0)+1 end
    return out
end

describe("Lunar glass",function()
    local real_load, loads
    before_each(function()
        real_load=Glass._load_png
        loads={}
        -- Baked images stand in as tiny solid PNGs; the specs count the loads.
        Glass._load_png=function(name)
            loads[#loads+1]=name
            return string.rep(string.char(40,44,50,255),16*9),16,9
        end
    end)
    after_each(function() Glass._load_png=real_load; Glass.setEnabled(true); Glass.clear() end)

    for _,name in ipairs({"LunarDarkTheme","LunarLightTheme"}) do
        it(name.." meets text, state and composited-glass contrast",function()
            local failures,count=audit.audit(require("core.classes.Themes."..name):new())
            assert.is_true(count>100)
            assert.same({},failures)
        end)
        it(name.." keeps the background under glass labels inside the luminance bound",function()
            local p=palette(name)
            assert.is_true(audit.inBound(p,audit.composite(p,false)))
            assert.is_true(audit.inBound(p,audit.composite(p,true)))
        end)
    end

    it("flags a composite past the bound",function()
        local p=palette("LunarDarkTheme")
        assert.is_false(audit.inBound(p,"90 96 106"))
        assert.is_true(audit.inBound(p,"64 70 80"))
        local l=palette("LunarLightTheme")
        assert.is_false(audit.inBound(l,"180 186 196"))
        assert.is_true(audit.inBound(l,"201 207 216"))
    end)

    it("ships the baked backdrops, their softened copies and the shadow",function()
        local repo=os.getenv("LUNAR_REPO") or "."
        for _,f in ipairs({"lunar-dark","lunar-dark-blur","lunar-light","lunar-light-blur","shadow"}) do
            local fh=io.open(repo.."/assets/glass/"..f..".png","rb")
            assert.is_not_nil(fh,f)
            assert.equal("\137PNG",fh:read(4)); fh:close()
        end
    end)

    it("loads each mode once and never again on resize or repeated light/dark switches",function()
        local B=Null.new(); local dc=Draw.new(B)
        local dark,light=palette("LunarDarkTheme"),palette("LunarLightTheme")
        B.frame_begin(); dc:begin(1920,1080)
        Glass.paint(dc,0,0,1920,40,"chrome",dark)
        Glass.paint(dc,0,0,1920,40,"chrome",light)
        B.frame_end()
        local warm=Glass.stats().generations
        local loaded=#loads
        local sizes={{1400,900},{1100,800},{1600,1000},{1000,700},{1920,1080}}
        for k=1,30 do
            local s=sizes[(k-1)%#sizes+1]
            B.frame_begin(); dc:begin(s[1],s[2])
            local p=k%2==0 and dark or light
            Glass.paint(dc,0,0,s[1],s[2],"floor",p)
            Glass.paint(dc,0,0,s[1],40,"chrome",p)
            Glass.paint(dc,100,100,300,200,"floating",p)
            B.frame_end()
        end
        assert.equal(warm,Glass.stats().generations)
        assert.equal(loaded,#loads)
        -- two images per mode and the shared shadow
        local count=0; for _ in pairs(B.textures) do count=count+1 end
        assert.equal(5,count)
        Glass.clear(); assert.is_nil(next(B.textures))
    end)

    it("draws a chrome surface in one sample, one tint and one rim",function()
        local B=Null.new(); local dc=Draw.new(B)
        B.frame_begin(); dc:begin(1920,1080)
        Glass.paint(dc,0,40,48,1000,"chrome",palette("LunarDarkTheme"),14)
        B.frame_end()
        local n=ops(B)
        assert.equal(1,n.image_rounded_uv); assert.equal(1,n.rim); assert.equal(1,n.rect_filled)
        assert.is_nil(n.image); assert.is_nil(n.image_nine); assert.is_nil(n.line)
    end)

    it("draws a floating surface as shadow, see-through lip, opaque well and one bevel",function()
        local B=Null.new(); local dc=Draw.new(B)
        local p=palette("LunarLightTheme")
        B.frame_begin(); dc:begin(1920,1080)
        Glass.paint(dc,200,200,400,300,"floating",p,16)
        B.frame_end()
        local n=ops(B)
        assert.equal(1,n.image_nine); assert.equal(1,n.rim); assert.equal(4,n.rect_filled)
        assert.is_nil(n.image_rounded_uv); assert.is_nil(n.rect)
        local fills={}
        for _,call in ipairs(B.lastFrame()) do
            if call[1]=="rect_filled" then fills[#fills+1]=call end
            if call[1]=="rim" then assert.equal(2,call[11]) end
        end
        -- the lip: the whole surface in a translucent tint, so what is underneath carries through
        local C=require("core.imgui.Color")
        local _,_,_,a=C.unpack(fills[1][6])
        assert.equal(math.floor(255*p.glassFloatingAlpha+0.5),a)
        -- the well: opaque, 8 px in from every edge, its last two pixels blending into the lip
        assert.equal(206,fills[2][2]); local _,_,_,f1=C.unpack(fills[2][6]); assert.equal(math.floor(255*0.35),f1)
        assert.equal(207,fills[3][2]); local _,_,_,f2=C.unpack(fills[3][6]); assert.is_true(f2>f1 and f2<255)
        assert.equal(208,fills[4][2]); assert.equal(208,fills[4][3]); assert.equal(592,fills[4][4]); assert.equal(492,fills[4][5])
        local _,_,_,wa=C.unpack(fills[4][6]); assert.equal(255,wa)
    end)

    it("bends what lies under a floating surface at the bevel and softens it in the lip",function()
        local B=Null.new(); local dc=Draw.new(B)
        local window=B.window
        B.window=function(op,...) if op=="frame_copy" then return -7,1920,1080 end return window(op,...) end
        B.frame_begin(); dc:begin(1920,1080)
        Glass.paint(dc,200,200,400,300,"floating",palette("LunarDarkTheme"),16,nil,10)
        B.frame_end()
        local taps={}
        for _,call in ipairs(B.lastFrame()) do if call[1]=="image_rounded_uv" and call[2]==-7 then taps[#taps+1]=call end end
        assert.equal(5,#taps)
        -- the whole surface, sampled 2 px in from each edge: the view bends at the rim
        assert.equal(200,taps[1][3]); assert.near(202/1920,taps[1][7],1e-9); assert.near(598/1920,taps[1][9],1e-9)
        -- inside the bevel: four half-pixel taps averaging to about 1.5 px of softening
        for k=2,5 do assert.equal(202,taps[k][3]); assert.equal(14,taps[k][12]) end
        assert.near((202-0.75)/1920,taps[2][7],1e-9); assert.near((202+0.75)/1920,taps[5][7],1e-9)
        -- the lip is 10 px here: the well starts 10 px in
        local wells=0
        for _,call in ipairs(B.lastFrame()) do if call[1]=="rect_filled" and call[2]==210 then wells=wells+1 end end
        assert.equal(1,wells)
    end)

    it("eases the rim's hover lift over 110 ms and only while it moves",function()
        local R={t=0,animated=0}
        package.loaded["core.imgui.Runtime"],R.real=setmetatable({now=function() return R.t end,animate=function() R.animated=R.animated+1 end},{}),package.loaded["core.imgui.Runtime"]
        local Reactor=require("core.ui.ThemeReactor")
        local tm=Reactor.themeManager
        Reactor.themeManager=function() return {_motion={enabled=function() return true end,_scale=1}} end
        local st={}
        assert.equal(0,Glass.ease(st,false))
        assert.near(0,Glass.ease(st,true),1e-9)
        R.t=0.055; local half=Glass.ease(st,true); assert.is_true(half>0.4 and half<0.6)
        R.t=0.2; local n=R.animated; assert.equal(1,Glass.ease(st,true)); assert.equal(n,R.animated)
        Reactor.themeManager=function() return {_motion={enabled=function() return false end}} end
        assert.equal(0,Glass.ease(st,false))
        Reactor.themeManager=tm
        package.loaded["core.imgui.Runtime"]=R.real
    end)

    it("lifts the rim's highlight by ten points at full hover",function()
        local B=Null.new(); local dc=Draw.new(B)
        local p=palette("LunarDarkTheme")
        B.frame_begin(); dc:begin(800,600)
        Glass.paint(dc,0,0,200,40,"chrome",p,8,nil,nil,0)
        Glass.paint(dc,0,0,200,40,"chrome",p,8,nil,nil,1)
        B.frame_end()
        local rims={}
        for _,call in ipairs(B.lastFrame()) do if call[1]=="rim" then rims[#rims+1]=call end end
        local C=require("core.imgui.Color")
        local _,_,_,a0=C.unpack(rims[1][7]); local _,_,_,a1=C.unpack(rims[2][7])
        assert.near(25.5,a1-a0,1)
    end)

    it("splits the rail into a cap round its entries and one round its foot",function()
        local tabs=require("core.imgui.widgets.flattabs")
        local real=tabs.extraRects
        tabs.extraRects=function() return {{0,56,48,32},{0,1000,48,32}} end
        local B=Null.new(); local dc=Draw.new(B)
        B.frame_begin(); dc:begin(1920,1080)
        Glass.paint(dc,0,40,48,1000,"caps",palette("LunarDarkTheme"),14,{})
        B.frame_end()
        tabs.extraRects=real
        local samples={}
        for _,call in ipairs(B.lastFrame()) do if call[1]=="image_rounded_uv" then samples[#samples+1]=call end end
        assert.equal(2,#samples)
        assert.equal(44,samples[1][4]); assert.equal(92,samples[1][6])      -- top cap ends under "+"
        assert.equal(996,samples[2][4]); assert.equal(1036,samples[2][6])   -- foot cap round the chevron
    end)

    it("maps the backdrop by cover scaling from the top-left and bends it through the rim",function()
        local B=Null.new(); local dc=Draw.new(B)
        B.frame_begin(); dc:begin(1100,800)
        Glass.paint(dc,0,0,1100,800,"floor",palette("LunarDarkTheme"))
        Glass.paint(dc,100,50,200,100,"chrome",palette("LunarDarkTheme"),0)
        B.frame_end()
        local floor,chrome
        for _,call in ipairs(B.lastFrame()) do
            if call[1]=="image_rounded_uv" then if floor then chrome=call else floor=call end end
        end
        -- 1100x800 is taller than the 16:9 image: height fills, width is cropped on the right.
        assert.near(0,floor[7],1e-9); assert.near(0,floor[8],1e-9)
        assert.near(1,floor[10],1e-9)
        assert.is_true(floor[9]<1)
        -- the chrome samples 2 px in from each edge: a 1.02x lens at its rim
        local s=800/9
        assert.near((100+2)/(16*s),chrome[7],1e-9)
        assert.near((300-2)/(16*s),chrome[9],1e-9)
    end)

    it("paints children of glass surfaces with nothing of their own",function()
        local B=Null.new(); local dc=Draw.new(B)
        B.frame_begin(); dc:begin(128,128)
        for _,kind in ipairs({"content","chrome_content","none"}) do
            Glass.paint(dc,0,0,128,32,kind,palette("LunarDarkTheme"))
        end
        B.frame_end()
        for _,call in ipairs(B.lastFrame()) do assert.equal("layer",call[1]) end
    end)

    it("keeps the layout with solid fills when glass is off",function()
        Glass.setEnabled(false)
        local B=Null.new(); local dc=Draw.new(B)
        B.frame_begin(); dc:begin(800,600)
        Glass.paint(dc,0,0,800,600,"floor",palette("LunarDarkTheme"))
        Glass.paint(dc,0,0,800,40,"chrome",palette("LunarDarkTheme"))
        B.frame_end()
        local n=ops(B)
        assert.is_nil(n.image_rounded_uv); assert.is_nil(n.rim)
        assert.equal(2,n.rect_filled)
        assert.equal(0,Glass.stats().bytes); assert.same({},loads)
    end)

    it("falls back to a flat floor when the baked image is missing",function()
        Glass._load_png=function() return nil end
        local B=Null.new(); local dc=Draw.new(B)
        B.frame_begin(); dc:begin(800,600)
        Glass.paint(dc,0,0,800,40,"chrome",palette("LunarDarkTheme"))
        B.frame_end()
        assert.equal(1,ops(B).image_rounded_uv)
    end)

    it("samples in clipped strips on a backend without the glass calls",function()
        local B=Null.new(); B.image_rounded_uv=nil; B.rim=nil; B.image_nine=nil
        local dc=Draw.new(B)
        B.frame_begin(); dc:begin(800,600)
        Glass.paint(dc,10,10,200,100,"chrome",palette("LunarDarkTheme"),16)
        B.frame_end()
        local n=ops(B)
        assert.is_true(n.image>16)
        assert.equal(1,n.rect)
    end)

    it("shifts and fades the glass calls when a recording is replayed",function()
        local B=Null.new(); local dc=Draw.new(B)
        B.frame_begin(); dc:begin(800,600)
        dc:record()
        Glass.paint(dc,10,10,200,100,"floating",palette("LunarDarkTheme"),16)
        local list=dc:stop()
        dc:replay(list,5,7,0.5)
        B.frame_end()
        local seen={}
        for _,call in ipairs(B.lastFrame()) do
            if call[1]=="rim" then seen.rim=call end
            if call[1]=="image_nine" then seen.nine=call end
        end
        assert.equal(15,seen.rim[2]); assert.equal(17,seen.rim[3])
        assert.is_true(seen.nine[3]<10)
    end)

    it("passes image subrectangles through the Null backend",function()
        require("core.imgui.widgets.image")
        local E=require("core.imgui.Element")
        local B=Null.new()
        local dc=Draw.new(B)
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

    it("gives the work sheet, its bands and the transport capsule their materials",function()
        local rules=require("core.classes.Themes.LunarDarkTheme"):new():rules()
        assert.equal("card",rules.workspace_sheet.glass); assert.equal(14,rules.workspace_sheet.radius)
        assert.equal("none",rules.workspace_band.glass)
        assert.equal("chrome",rules.transport_capsule.glass)
        assert.equal(16,rules.palette_frame.radius)
        assert.is_not_nil(rules.primary_btn.gradcolor)
        -- themes without glass keep a plain card for the player
        local carbonless=require("core.classes.Themes.OneDarkProTheme"):new():rules()
        assert.is_nil(carbonless.transport_capsule.glass)
    end)

    it("insets the sheet wide and narrow and keeps its left edge as the rail changes",function()
        local Frame=require("core.ui.WorkspaceFrame")
        local Reactor=require("core.ui.ThemeReactor")
        local real=Reactor.palette
        Reactor.palette=function() return palette("LunarDarkTheme") end
        local iup={_IMGUI=true}
        local width=48
        Frame.setRail(function() return width end)
        Frame.setWidth(1920)
        local m=Frame.metrics(iup)
        assert.same({band=12,left=56,top=14,right=12,bottom=12},m)
        Frame.setWidth(1100)
        m=Frame.metrics(iup)
        assert.same({band=12,left=32,top=6,right=8,bottom=4},m)
        width=176
        assert.equal(8,Frame.metrics(iup).left)
        Frame.setWidth(1920); width=48
        Reactor.palette=function() return palette("CarbonWhiteTheme") end
        assert.same({band=12,left=0,top=0,right=0,bottom=0},Frame.metrics(iup))
        Reactor.palette=real
    end)

    describe("on a hardware device",function()
        -- A backend whose live device can run the glass shader (lunar_ui_glass_ready).
        local function hardware(ready)
            local B=Null.new(); local asked=0
            B.glass_ready=function() asked=asked+1; return ready==nil and true or ready() end
            return B,function() return asked end
        end
        local function frame(B,dc,w,h,fn) B.frame_begin(); dc:begin(w,h); fn(); B.frame_end() end
        local function calls(B,op)
            local out={}
            for _,c in ipairs(B.lastFrame()) do if c[1]==op then out[#out+1]=c end end
            return out
        end

        it("draws chrome as one shader surface: no baked sample, tint or rim",function()
            local B=hardware(); local dc=Draw.new(B); local p=palette("LunarDarkTheme")
            frame(B,dc,1920,1080,function() Glass.paint(dc,0,40,48,1000,"chrome",p,14) end)
            local n=ops(B)
            assert.equal(1,n.glass); assert.is_nil(n.image_rounded_uv); assert.is_nil(n.rim); assert.is_nil(n.rect_filled)
            local g=calls(B,"glass")[1]
            assert.same({0,40,48,1040,14,1},{g[2],g[3],g[4],g[5],g[6],g[7]})
            assert.equal(Glass.LENS.chrome.band,g[11]); assert.equal(Glass.LENS.chrome.thickness,g[12])
            -- it samples the floor's own images (no frame copy), mapped by cover scaling
            assert.is_number(g[15]); assert.is_number(g[16]); assert.are_not.equal(g[15],g[16])
            assert.near(1/1920,g[17],1e-9); assert.near(1/1080,g[18],1e-9)   -- a 16:9 image over 1920x1080
            assert.equal("shader",Glass.path(dc))
        end)

        it("draws floating glass as shadow, shader lip and opaque well, without the frame copy",function()
            local B=hardware(); local dc=Draw.new(B); local p=palette("LunarLightTheme")
            local copies=0
            B.window=function(op) if op=="frame_copy" then copies=copies+1; return -7,1920,1080 end end
            frame(B,dc,1920,1080,function() Glass.paint(dc,200,200,400,300,"floating",p,16,nil,nil,0.5) end)
            local n=ops(B)
            assert.equal(1,n.image_nine); assert.equal(1,n.glass); assert.is_nil(n.rim); assert.is_nil(n.image_rounded_uv)
            assert.equal(0,copies)
            local g=calls(B,"glass")[1]
            assert.equal(0,g[7])                        -- floating
            assert.equal(Glass.LENS.floating.band,g[11])        -- 3 px of lens, falling off over 4 px
            assert.equal(3,g[12])
            assert.equal(0.5,g[13])                     -- hover lift
            -- it eases into the well over the lip, splits no colour and is unbounded
            assert.equal(p.glassLip,g[20]); assert.is_true(g[19]~=0)
            assert.equal(0,g[21]); assert.equal(0,g[23]); assert.near(0.08,g[24],1e-9)
            -- the well is still opaque, 8 px in
            local well=calls(B,"rect_filled"); well=well[#well]
            local C=require("core.imgui.Color")
            assert.equal(208,well[2]); local _,_,_,a=C.unpack(well[6]); assert.equal(255,a)
            -- the shadow comes first, the well after the glass
            local order={}
            for _,c in ipairs(B.lastFrame()) do order[#order+1]=c[1] end
            local function at(op) for i,o in ipairs(order) do if o==op then return i end end end
            assert.is_true(at("image_nine")<at("glass") and at("glass")<at("rect_filled"))
        end)

        it("draws a tooltip as frosted glass with no well, its luminance bounded",function()
            for _,name in ipairs({"LunarDarkTheme","LunarLightTheme"}) do
                local B=hardware(); local dc=Draw.new(B); local p=palette(name)
                frame(B,dc,1920,1080,function() Glass.paint(dc,300,300,180,28,"floating",p,12,nil,4,nil,Glass.TIP_STATE,Glass.TIP_STYLE) end)
                local g=calls(B,"glass")[1]
                assert.equal(3,g[7]); assert.equal(0,g[20])     -- frost, no hollow
                assert.is_nil(ops(B).rect_filled)               -- no opaque well
                assert.equal(p.glassDark and 0.0622 or -0.62,g[23])
                assert.equal(0,g[21])
            end
        end)

        it("splits a quarter px of colour at the palette and Activity only",function()
            local rules=require("core.classes.Themes.LunarDarkTheme"):new():rules()
            assert.equal(0.25,rules.palette_frame.chroma)
            assert.is_nil(rules.dropdown_list.chroma); assert.is_nil(rules.contextmenu.chroma)
            local B=hardware(); local dc=Draw.new(B); local p=palette("LunarDarkTheme")
            frame(B,dc,1920,1080,function() Glass.paint(dc,200,200,600,300,"floating",p,16,nil,10,0,{},rules.palette_frame) end)
            assert.equal(0.25,calls(B,"glass")[1][21])
        end)

        it("draws the transport as live glass over its artwork, extended 24 px under it",function()
            local rules=require("core.classes.Themes.LunarDarkTheme"):new():rules()
            assert.is_true(rules.transport_capsule.live)
            local B=hardware(); local dc=Draw.new(B); local p=palette("LunarDarkTheme")
            local state={glass_art={tex=42,x=130,y=1000,w=32,h=48}}
            frame(B,dc,1920,1080,function() Glass.paint(dc,120,990,1600,64,"chrome",p,999,nil,nil,0,state,rules.transport_capsule) end)
            local order=calls(B,"image_rounded_uv")
            assert.equal(1,#order); assert.equal(42,order[1][2])
            -- the artwork reaches 24 px right of itself, the capsule bounds the rest
            assert.same({120,990,186,1054},{order[1][3],order[1][4],order[1][5],order[1][6]})
            local g=calls(B,"glass")[1]
            assert.equal(2,g[7]); assert.equal(6,g[11]); assert.equal(3,g[12]); assert.equal(0.25,g[21])
            assert.equal(0.0622,g[23])
            local C=require("core.imgui.Color"); local _,_,_,a=C.unpack(g[8]); assert.equal(191,a)   -- 25% artwork
        end)

        it("turns the light toward a nearby pointer, eased, and keeps it fixed with reduced motion",function()
            local R=package.loaded["core.imgui.Runtime"]
            local saved=R and {R.pointer,R.now,R.animate}
            R=R or {}; package.loaded["core.imgui.Runtime"]=R
            local now,px,py=0,700,150
            R.pointer=function() return px,py,true end; R.now=function() return now end; R.animate=function() end
            local Reactor=require("core.ui.ThemeReactor")
            local real=Reactor.themeManager
            local enabled=true
            Reactor.themeManager=function() return {_motion={enabled=function() return enabled end,_scale=1}} end
            local state={}
            local dc={}
            assert.equal(0,Glass.light(dc,state,100,100,400,100))         -- far: at rest
            px,py=520,150; now=1
            assert.equal(0,Glass.light(dc,state,100,100,400,100))         -- starts easing
            now=1.2
            assert.near(math.rad(20),Glass.light(dc,state,100,100,400,100),1e-9)   -- capped at 20 degrees
            assert.is_true(Glass.wantsPointer(520,150,true)); assert.is_false(Glass.wantsPointer(900,900,true) and Glass.wantsPointer(900,900,true))
            enabled=false
            assert.equal(0,Glass.light(dc,{},100,100,400,100))
            Reactor.themeManager=real
            if saved then R.pointer,R.now,R.animate=saved[1],saved[2],saved[3] else package.loaded["core.imgui.Runtime"]=nil end
        end)

        it("keeps the search field one rounded pill: no square of the strip's colour behind it",function()
            for _,name in ipairs({"LunarDarkTheme","LunarLightTheme"}) do
                local rules=require("core.classes.Themes."..name):new():rules()
                assert.equal("content",rules.commandbar.glass); assert.equal(14,rules.commandbar.radius)
                assert.equal(14,rules.commandbar_text.radius)
            end
        end)

        it("keeps the floor and the matte card the same on both paths",function()
            local function draw(B)
                local dc=Draw.new(B); local p=palette("LunarDarkTheme")
                frame(B,dc,1920,1080,function()
                    Glass.paint(dc,0,0,1920,1080,"floor",p); Glass.paint(dc,100,60,1700,900,"card",p)
                end)
                return ops(B)
            end
            assert.same(draw(Null.new()),draw((hardware())))
        end)

        it("asks the device once per frame, and follows a fallback to WARP at the next frame",function()
            local live=true
            local B,asked=hardware(function() return live end); local dc=Draw.new(B); local p=palette("LunarDarkTheme")
            frame(B,dc,1920,1080,function()
                for k=1,5 do Glass.paint(dc,0,k*40,1920,40,"chrome",p) end
                Glass.paint(dc,100,100,300,200,"floating",p)
            end)
            assert.equal(1,asked()); assert.equal(6,ops(B).glass)
            live=false   -- the hardware device was removed and re-made on WARP
            frame(B,dc,1920,1080,function() Glass.paint(dc,0,40,1920,40,"chrome",p) end)
            assert.equal(2,asked()); assert.is_nil(ops(B).glass); assert.equal(1,ops(B).image_rounded_uv)
            assert.equal("baked",Glass.path(dc))
        end)

        it("uses the baked path on WARP, an SDL host and with hardware acceleration off",function()
            for _,B in ipairs({hardware(function() return false end),Null.new()}) do
                local dc=Draw.new(B); local p=palette("LunarDarkTheme")
                frame(B,dc,1920,1080,function()
                    Glass.paint(dc,0,0,1920,40,"chrome",p); Glass.paint(dc,100,100,300,200,"floating",p)
                end)
                assert.is_nil(ops(B).glass); assert.equal(2,ops(B).rim)
                assert.equal("baked",Glass.path(dc))
            end
        end)

        it("leaves Carbon and glass-off surfaces solid even on hardware",function()
            local B=hardware(); local dc=Draw.new(B)
            frame(B,dc,1920,1080,function()
                Glass.paint(dc,0,0,1920,40,"chrome",palette("CarbonWhiteTheme"))
                Glass.paint(dc,100,100,300,200,"floating",palette("CarbonWhiteTheme"))
            end)
            assert.is_nil(ops(B).glass)
            Glass.setEnabled(false)
            frame(B,dc,1920,1080,function() Glass.paint(dc,0,0,1920,40,"chrome",palette("LunarDarkTheme")) end)
            assert.is_nil(ops(B).glass)
        end)

        it("generates and uploads nothing after warm-up across resizes and light/dark switches",function()
            local B=hardware(); local dc=Draw.new(B)
            local dark,light=palette("LunarDarkTheme"),palette("LunarLightTheme")
            frame(B,dc,1920,1080,function() Glass.paint(dc,0,0,1920,40,"chrome",dark); Glass.paint(dc,0,0,1920,40,"chrome",light) end)
            local warm,loaded=Glass.stats().generations,#loads
            local uploads=0; local tex=B.texture; B.texture=function(...) uploads=uploads+1; return tex(...) end
            local sizes={{1400,900},{1100,800},{1600,1000},{1000,700},{1920,1080}}
            for k=1,30 do
                local s=sizes[(k-1)%#sizes+1]; local p=k%2==0 and dark or light
                frame(B,dc,s[1],s[2],function()
                    Glass.paint(dc,0,0,s[1],s[2],"floor",p); Glass.paint(dc,0,0,s[1],40,"chrome",p)
                    Glass.paint(dc,100,100,300,200,"floating",p)
                end)
            end
            assert.equal(warm,Glass.stats().generations); assert.equal(loaded,#loads); assert.equal(0,uploads)
        end)

        it("shifts and fades a recorded shader surface when it is replayed",function()
            local B=hardware(); local dc=Draw.new(B); local p=palette("LunarDarkTheme")
            B.frame_begin(); dc:begin(1920,1080)
            dc:record(false); Glass.paint(dc,10,10,100,40,"chrome",p); local rec=dc:stop()
            dc:replay(rec,5,7,0.5)
            B.frame_end()
            local g=calls(B,"glass")[1]
            assert.same({15,17,115,57},{g[2],g[3],g[4],g[5]})
            local C=require("core.imgui.Color"); local _,_,_,a=C.unpack(g[14]); assert.near(128,a,1)
        end)
    end)
end)
