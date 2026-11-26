local Scene=require("core.ui.Background")
local Null=require("core.imgui.backend.Null")
local Draw=require("core.imgui.Draw")
local Reactor=require("core.ui.ThemeReactor")

-- A clock, a pointer and a motion switch the scene reads through the runtime and the
-- theme manager; specs drive them.
local clock,pointer,motion_on,wakes
local function fake_runtime()
    return { now=function() return clock end, pointer=function() return pointer[1],pointer[2],pointer[3] end,
        wakeAt=function(t) wakes[#wakes+1]=t end, animate=function() end }
end

local function compile(v)
    local deps={}
    return Scene._compile(v,deps),deps
end

describe("reactive backgrounds",function()
    local saved_rt, saved_tm, saved_svg
    before_each(function()
        clock,pointer,motion_on,wakes=10,{-1,-1,false},true,{}
        saved_rt=package.loaded["core.imgui.Runtime"]
        package.loaded["core.imgui.Runtime"]=fake_runtime()
        saved_tm=Reactor.themeManager
        Reactor.themeManager=function() return { _motion={ enabled=function() return motion_on end, _scale=1 } } end
        saved_svg=Scene._svg_pixels
        Scene._svg_pixels=function(src,w,h) return string.rep("\255",w*h*4),w,h end
        Scene.clear(); Scene.reset()
    end)
    after_each(function()
        package.loaded["core.imgui.Runtime"]=saved_rt
        Reactor.themeManager=saved_tm
        Scene._svg_pixels=saved_svg
        Scene.clear(); Scene.reset()
    end)

    describe("bindings",function()
        it("interpolates a signal over a range, eased, numbers and colours",function()
            local f,deps=compile({signal="mode",from=10,to=20,range={0.5,1}})
            assert.is_true(deps.mode)
            assert.equal(10,f({mode=0.2})); assert.equal(15,f({mode=0.75})); assert.equal(20,f({mode=3}))
            local e=compile({signal="mode",from=0,to=1,ease="smooth"})
            assert.near(0.15625,e({mode=0.25}),1e-9)
            local c=compile({signal="mode",from="#000000",to="#FF8000"})
            local v=c({mode=0.5})
            assert.near(127.5,v[1],1e-9); assert.near(64,v[2],1e-9); assert.equal(0,v[3]); assert.equal(255,v[4])
        end)
        it("follows stops, waves, rates and proportions",function()
            local s=compile({signal="mode",stops={{0,0},{0.5,10},{1,0}}})
            assert.equal(5,s({mode=0.25})); assert.equal(10,s({mode=0.5})); assert.equal(0,s({mode=1}))
            local w=compile({signal="time",wave="sine",period=4,min=1,max=3})
            assert.near(1,w({time=0}),1e-9); assert.near(3,w({time=2}),1e-9); assert.near(2,w({time=1}),1e-9)
            local r=compile({signal="time",rate=90,wrap=360})
            assert.equal(180,r({time=2})); assert.equal(90,r({time=5}))
            local p=compile({signal="mouse_x",scale=-8,offset=2})
            assert.equal(-6,p({mouse_x=1}))
        end)
        it("combines bindings and takes functions with their declared signals",function()
            local sum,deps=compile({add={1,{signal="rail",scale=2}}})
            assert.equal(3,sum({rail=1})); assert.is_true(deps.rail)
            local prod=compile({mul={{signal="rail",scale=1},{signal="mode",from=1,to=0}}})
            assert.equal(0.5,prod({rail=1,mode=0.5}))
            local fn,fdeps=compile(function(s) return s.width/2 end)
            assert.equal(50,fn({width=100})); assert.is_true(fdeps["*"])
            local layer=Scene._scene_of({layers={{kind="fill",opacity=function(s) return s.rail end,deps={"rail"}}}})
            assert.is_true(layer.deps.rail); assert.is_nil(layer.deps["*"]); assert.is_nil(layer.deps.time)
        end)
        it("knows what each layer reads",function()
            local scene=Scene._scene_of({layers={
                {kind="fill",top="#000000",bottom="#101010"},
                {kind="stars",count=10,twinkle={amount=0.5,share=1}},
                {svg="<svg/>",size=10,parallax=4},
            }})
            assert.same({},scene.layers[1].deps)
            assert.is_true(scene.layers[2].deps.time)
            assert.is_true(scene.layers[3].deps.mouse_x); assert.is_true(scene.layers[3].deps.mouse_y)
            assert.is_nil(scene.layers[3].deps.time)
        end)
    end)

    local function frame(B,dc,p,w,h,live)
        w,h=w or 800,h or 600
        B.frame_begin(); dc:begin(w,h)
        local drawn=Scene.floor(dc,0,0,w,h,p,live~=false)
        B.frame_end()
        return drawn
    end
    local static={background={id="s",layers={{kind="fill",top="#000010",bottom="#000020"},
        {svg="<svg/>",size=32,x=0.5,y=0.5}}}}

    it("draws a static scene once, into the target, and then only its image",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B)
        assert.is_true(frame(B,dc,static))
        assert.equal(1,B.scene_renders)
        for _=1,20 do clock=clock+0.5; frame(B,dc,static) end
        assert.equal(1,B.scene_renders)
        assert.equal(1,Scene.stats().emits); assert.is_true(Scene.stats().skipped>=20)
        -- the floor is the target's image
        local floor
        for _,c in ipairs(B.lastFrame()) do if c[1]=="image" then floor=c end end
        assert.equal(B.SCENE_SHARP,floor[2]); assert.near(800/1024,floor[9],1e-9)
        -- nothing wants a frame on its own
        assert.is_nil(Scene.due())
        -- a new window size draws it again
        frame(B,dc,static,900,600)
        assert.equal(2,B.scene_renders)
    end)

    it("redraws at most RESIZE_HZ times a second during a live resize, then once when it settles",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B)
        frame(B,dc,static,800,600)
        for k=1,5 do clock=clock+0.005; frame(B,dc,static,800+k*10,600) end
        assert.equal(1,B.scene_renders)
        -- the last render stretches over the window meanwhile
        local floor
        for _,c in ipairs(B.lastFrame()) do if c[1]=="image" then floor=c end end
        assert.near(800/1024,floor[9],1e-9)
        assert.near(clock-0.025+1/Scene.RESIZE_HZ,Scene.due(),1e-9)
        clock=Scene.due()
        assert.is_true(Scene.tick(B))
        assert.equal(2,B.scene_renders); assert.is_nil(Scene.due())
    end)

    it("uploads each element once and never again on resize, mode or rail changes",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B)
        local p=require("core.classes.Themes.LunarDarkTheme"):new():palette()
        local l=require("core.classes.Themes.LunarLightTheme"):new():palette()
        frame(B,dc,p); frame(B,dc,l)
        local warm=Scene.stats().uploads
        assert.is_true(warm>0)
        local sizes={{1920,1080},{1100,800},{1400,900}}
        for k=1,30 do
            clock=clock+0.1
            Scene.set("rail",k%2); Scene.set("rail_room",400)
            local s=sizes[(k-1)%#sizes+1]
            frame(B,dc,k%2==0 and p or l,s[1],s[2])
        end
        assert.equal(warm,Scene.stats().uploads)
    end)

    describe("time",function()
        local twinkle={background={id="t",fps=20,layers={{kind="stars",count=5,twinkle={amount=1,share=1,period={2,2}}}}}}
        it("redraws a time-bound layer at its fps and no faster",function()
            local B=Null.new({scene=true}); local dc=Draw.new(B)
            frame(B,dc,twinkle)
            assert.near(clock+1/20,Scene.due(),1e-9)
            -- a frame sooner than the next step draws nothing new
            clock=clock+0.01; frame(B,dc,twinkle)
            assert.equal(1,B.scene_renders)
            clock=clock+0.05; frame(B,dc,twinkle)
            assert.equal(2,B.scene_renders)
        end)
        it("is static with motion off or off the GPU path: time reads 0, nothing is due",function()
            local B=Null.new({scene=true}); local dc=Draw.new(B)
            motion_on=false
            frame(B,dc,twinkle)
            assert.is_nil(Scene.due())
            for _=1,10 do clock=clock+1; frame(B,dc,twinkle) end
            assert.equal(1,B.scene_renders)
            motion_on=true; Scene.clear()
            frame(B,dc,twinkle,800,600,false)   -- WARP / hardware acceleration off
            assert.is_nil(Scene.due())
        end)
        it("presents a scene-only tick without a frame of the UI, and asks for one when refused",function()
            local B=Null.new({scene=true}); local dc=Draw.new(B)
            frame(B,dc,twinkle)
            local before=B.frames
            clock=Scene.due()
            assert.is_true(Scene.tick(B))
            assert.equal(1,B.scene_presents); assert.equal(2,B.scene_renders); assert.equal(before,B.frames)
            -- too soon: nothing changed, nothing drawn
            clock=clock+0.001
            assert.is_true(Scene.tick(B)); assert.equal(2,B.scene_renders)
            B.scene_refuse=true
            clock=clock+0.2
            assert.is_false(Scene.tick(B))
        end)
    end)

    it("redraws a pointer-bound layer only when the pointer moved",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B)
        local par={background={id="m",layers={{svg="<svg/>",size=16,parallax=10}}}}
        pointer={400,300,true}
        frame(B,dc,par)
        assert.is_true(Scene.wantsPointer())
        for _=1,5 do clock=clock+1; frame(B,dc,par) end
        assert.equal(1,B.scene_renders)
        assert.is_nil(Scene.due())
        pointer={600,300,true}
        frame(B,dc,par)
        assert.equal(2,B.scene_renders)
        local img
        for _,c in ipairs(B.scene_calls) do if c[1]=="image" then img=c end end
        -- mouse_x 0.5 across the window, 10 px of parallax: 5 px left of centre
        assert.near(400-8-5,img[3],1e-9)
    end)

    it("eases mode between two palettes of one scene, and jumps to another scene",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B)
        local layers={{kind="fill",top={signal="mode",from="#000000",to="#FFFFFF"},bottom="#000000"}}
        local dark={glassDark=true,background={id="sky",layers=layers}}
        local light={glassDark=false,background={id="sky",layers=layers}}
        frame(B,dc,dark)
        frame(B,dc,light)
        local function top()
            for _,c in ipairs(B.scene_calls) do if c[1]=="rect_gradient" then return c[6] % 256 end end
        end
        assert.equal(0,top())   -- the switch starts from dark
        clock=clock+Scene.MODE_EASE/2
        assert.equal(clock,Scene.due())   -- frames while it moves
        frame(B,dc,light)
        local mid=top()
        assert.is_true(mid>60 and mid<200)
        clock=clock+Scene.MODE_EASE
        frame(B,dc,light)
        assert.equal(255,top())
        -- another scene starts at its own mode
        frame(B,dc,{glassDark=true,background={id="other",layers=layers}})
        assert.equal(0,top())
        -- motion off: the switch is instant
        motion_on=false
        frame(B,dc,light); frame(B,dc,light)
        assert.equal(255,top())
        -- off the GPU path (WARP): one render, no ease
        motion_on=true; Scene.clear()
        frame(B,dc,dark,800,600,false); frame(B,dc,light,800,600,false)
        assert.equal(255,top()); assert.is_nil(Scene.due())
    end)

    it("follows a pushed signal (the rail) and registers new ones",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B)
        Scene.signal("battery",{read=function() return 0.25 end})
        local p={background={id="r",layers={{svg="<svg/>",size=10,opacity={signal="rail",from=0,to=1}},
            {svg="<svg/>",size=10,dx={signal="battery",scale=100}}}}}
        frame(B,dc,p)
        local function images() local n=0; for _,c in ipairs(B.scene_calls) do if c[1]=="image" then n=n+1 end end; return n end
        assert.equal(1,images())   -- the rail is collapsed: its layer is not drawn
        Scene.set("rail",1)
        assert.equal(clock,wakes[#wakes])   -- a layer reads it: a frame is asked for
        frame(B,dc,p)
        assert.equal(2,images())
        Scene.signal("battery",nil)
    end)

    it("draws the layers straight onto the floor without a scene target, static",function()
        local B=Null.new(); local dc=Draw.new(B)
        assert.is_true(frame(B,dc,static))
        local n=0
        for _,c in ipairs(B.lastFrame()) do if c[1]=="image" or c[1]=="rect_gradient" then n=n+1 end end
        assert.equal(2,n)
        assert.is_nil(Scene.textures(B))
    end)

    describe("Lunar's space scene",function()
        local dark=require("core.classes.Themes.LunarDarkTheme"):new():palette()
        local light=require("core.classes.Themes.LunarLightTheme"):new():palette()
        it("is one scene for both modes, which a switch eases",function()
            assert.equal(dark.background.id,light.background.id)
            assert.is_true(#dark.background.layers>=10)
        end)
        -- the crescent: the turned quad centred on the extended rail (x 88); its alpha and
        -- the direction its lit limb (the art's left, -x) faces
        local function crescent(p,rail,room,mode_now)
            local B=Null.new({scene=true}); local dc=Draw.new(B)
            Scene.clear()
            Scene.set("rail",rail); Scene.set("rail_room",room)
            frame(B,dc,p,1920,1080)
            local best,facing=0,nil
            for _,c in ipairs(B.scene_calls) do
                if c[1]=="image_quad" then
                    local cx=(c[3]+c[5]+c[7]+c[9])/4
                    if math.abs(cx-88)<1 and math.abs(c[5]-c[3])+math.abs(c[6]-c[4])>100 then
                        local a=math.floor(c[11]/16777216)
                        if a>=best then
                            best=a
                            -- the art's left edge midpoint minus its centre: where the limb faces
                            local lx,ly=(c[3]+c[9])/2,(c[4]+c[10])/2
                            local cy=(c[4]+c[6]+c[8]+c[10])/4
                            facing={lx-cx,ly-cy}
                        end
                    end
                end
            end
            return best,facing
        end
        local function crescent_alpha(p,rail,room) return (crescent(p,rail,room)) end
        it("shows the crescent only with the rail extended and room below its entries",function()
            for _,p in ipairs({dark,light}) do
                assert.equal(0,crescent_alpha(p,0,400))
                assert.is_true(crescent_alpha(p,1,400)>100)
                assert.equal(0,crescent_alpha(p,1,200))   -- entries would reach it
            end
        end)
        it("lights the crescent from the sun: below the lower right at night, the upper right by day",function()
            local space=require("core.classes.Themes.lunar_space")
            for _,case in ipairs({{dark,0},{light,1}}) do
                local _,f=crescent(case[1],1,400)
                local sx,sy=space.sun_at(case[2])
                local tx,ty=sx*1920-88,sy*1080-(1080-230)
                local dot=(f[1]*tx+f[2]*ty)/(math.sqrt(f[1]^2+f[2]^2)*math.sqrt(tx^2+ty^2))
                assert.is_true(dot>0.99,"limb faces the sun")
            end
            local _,night=crescent(dark,1,400); local _,day=crescent(light,1,400)
            assert.is_true(night[2]>0 and day[2]<0)   -- lit from below at night, from above by day
        end)
        it("dims the night's stars enough for the frame's labels and lets day hide them",function()
            local B=Null.new({scene=true}); local dc=Draw.new(B)
            frame(B,dc,dark,1920,1080)
            local brightest=0
            for _,c in ipairs(B.scene_calls) do
                if c[1]=="image" and c[5]-c[3]<14 then brightest=math.max(brightest,math.floor(c[11]/16777216)) end
            end
            assert.is_true(brightest>0 and brightest<=math.floor(255*0.40+0.5))
            Scene.clear()
            frame(B,dc,light,1920,1080)
            for _,c in ipairs(B.scene_calls) do assert.is_false(c[1]=="image" and c[5]-c[3]<14) end
        end)
    end)
end)
