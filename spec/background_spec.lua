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
    local saved_rt, saved_tm, saved_svg, saved_pal
    before_each(function()
        clock,pointer,motion_on,wakes=10,{-1,-1,false},true,{}
        saved_rt=package.loaded["core.imgui.Runtime"]
        package.loaded["core.imgui.Runtime"]=fake_runtime()
        saved_tm,saved_pal=Reactor.themeManager,Reactor.palette
        Reactor.themeManager=function() return { _motion={ enabled=function() return motion_on end, _scale=1 } } end
        Reactor.palette=function() return nil end
        saved_svg=Scene._svg_pixels
        Scene._svg_pixels=function(src,w,h) return string.rep("\255",w*h*4),w,h end
        Scene.clear(); Scene.reset()
        Scene.signal("rail_room",nil)   -- a rail of an earlier spec registers it; here it is pushed
    end)
    after_each(function()
        package.loaded["core.imgui.Runtime"]=saved_rt
        Reactor.themeManager,Reactor.palette=saved_tm,saved_pal
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
        -- the last frame's lists sample the old size: the settling draw is a full frame
        assert.is_false(Scene.tick(B))
        frame(B,dc,static,850,600)
        assert.equal(2,B.scene_renders); assert.is_nil(Scene.due())
    end)

    it("owes nothing after a resize that comes back within the hold (A -> B -> A)",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B)
        frame(B,dc,static,800,600)
        clock=clock+0.005; frame(B,dc,static,820,600)   -- stretched: a redraw is owed
        assert.is_not_nil(Scene.due())
        clock=clock+0.005; frame(B,dc,static,800,600)   -- back to the target's size
        assert.is_nil(Scene.due())
        for _=1,5 do clock=clock+0.5; frame(B,dc,static,800,600) end
        assert.equal(1,B.scene_renders)
        -- the static path (WARP) too
        Scene.clear()
        frame(B,dc,static,800,600,false)
        clock=clock+0.01; frame(B,dc,static,840,600,false)
        clock=clock+0.01; frame(B,dc,static,800,600,false)
        assert.is_nil(Scene.due())
    end)

    it("eases mode for a shared scene table without an id, keeping pushed signals",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B)
        local bg={layers={{kind="fill",top={signal="mode",from="#000000",to="#FFFFFF"},bottom="#000000"},
            {svg="<svg/>",size=8,opacity={signal="rail",scale=1}}}}
        local dark,light={glassDark=true,background=bg},{glassDark=false,background=bg}
        Scene.set("rail",1)
        frame(B,dc,dark); frame(B,dc,dark)
        local renders=B.scene_renders
        frame(B,dc,dark)
        assert.equal(renders,B.scene_renders)   -- the same scene: nothing new to draw
        frame(B,dc,light)
        assert.equal(1,Scene.lag(clock))        -- an ease, not a jump to light
        assert.near(clock+Scene.MODE_DELAY,Scene.due(),1e-9)
        assert.equal(1,Scene.get("rail"))
    end)

    it("draws one full frame at or after a mode ease's end before scene-only presents",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B)
        local layers={{kind="fill",top={signal="mode",from="#000000",to="#FFFFFF"},bottom="#000000"},
            {kind="stars",count=5,twinkle={amount=1,share=1,period={2,2}}}}
        local dark={glassDark=true,background={id="sky2",layers=layers}}
        local light={glassDark=false,background={id="sky2",layers=layers}}
        frame(B,dc,dark); frame(B,dc,light)
        -- the last full frame of the ease, just before its end
        clock=clock+Scene.MODE_DELAY+Scene.MODE_EASE-0.004
        frame(B,dc,light)
        assert.is_true(Scene.lag(clock)>0)
        -- the deadline: the next wake is at or after the ease's end, and it is a full frame
        local due=Scene.due()
        assert.is_true(due>=clock)
        clock=math.max(due,clock+0.005)
        assert.equal(0,Scene.lag(clock))
        assert.is_false(Scene.tick(B))
        frame(B,dc,light)
        -- then the twinkle goes back to scene-only presents
        clock=Scene.due()
        assert.is_true(Scene.tick(B))
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
        -- the sky starts MODE_DELAY after the UI switched
        assert.near(clock+Scene.MODE_DELAY,Scene.due(),1e-9)
        assert.equal(1,Scene.lag(clock))
        clock=clock+Scene.MODE_DELAY+Scene.MODE_EASE/2
        assert.is_true(Scene.due()<=clock)   -- frames while it moves
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
            Scene.set("rail",rail); Scene.set("rail_settled",rail); Scene.set("rail_room",room)
            -- the crescent lies over the frame's tint: drawn after the floor, onto the frame
            B.frame_begin(); dc:begin(1920,1080)
            Scene.floor(dc,0,0,1920,1080,p,true); Scene.above(dc,0,0,1920,1080)
            B.frame_end()
            local best,facing=0,nil
            for _,c in ipairs(B.lastFrame()) do
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
        it("keeps the crescent out while the rail moves: it follows rail_settled, not rail",function()
            local B=Null.new({scene=true}); local dc=Draw.new(B)
            Scene.set("rail",0.6); Scene.set("rail_settled",0); Scene.set("rail_room",400)
            B.frame_begin(); dc:begin(1920,1080)
            Scene.floor(dc,0,0,1920,1080,dark,true); Scene.above(dc,0,0,1920,1080)
            B.frame_end()
            for _,c in ipairs(B.lastFrame()) do
                if c[1]=="image_quad" and math.abs(c[5]-c[3])+math.abs(c[6]-c[4])>100 then
                    local cx=(c[3]+c[5]+c[7]+c[9])/4
                    assert.is_false(cx<200 and math.floor(c[11]/16777216)>0)
                end
            end
        end)
        it("lights the crescent from the sun: below the lower right at night, the upper right by day",function()
            local space=require("core.classes.Themes.lunar_space")
            for _,case in ipairs({{dark,0},{light,1}}) do
                local _,f=crescent(case[1],1,400)
                local sx,sy=space.sun_at(case[2],1920,1080)
                local tx,ty=sx-88,sy-(1080-230)
                local dot=(f[1]*tx+f[2]*ty)/(math.sqrt(f[1]^2+f[2]^2)*math.sqrt(tx^2+ty^2))
                assert.is_true(dot>0.99,"limb faces the sun")
            end
            local _,night=crescent(dark,1,400); local _,day=crescent(light,1,400)
            assert.is_true(night[2]>0 and day[2]<0)   -- lit from below at night, from above by day
        end)
        it("caps the night's stars in the frame's label strips, brighter behind the sheet; day hides them",function()
            local space=require("core.classes.Themes.lunar_space")
            local B=Null.new({scene=true}); local dc=Draw.new(B)
            frame(B,dc,dark,1920,1080)
            local framed,body=0,0
            for _,c in ipairs(B.scene_calls) do
                if c[1]=="image" and c[5]-c[3]<16 then
                    local x,y=(c[3]+c[5])/2,(c[4]+c[6])/2
                    local a=math.floor(c[11]/16777216)
                    if x<60 or y<46 or y>1080-30 then framed=math.max(framed,a) else body=math.max(body,a) end
                end
            end
            assert.is_true(framed>0 and framed<=math.ceil(255*space.FRAME_STARS))
            assert.is_true(body>framed and body<=math.ceil(255*space.BODY_STARS))
            Scene.clear()
            frame(B,dc,light,1920,1080)
            for _,c in ipairs(B.scene_calls) do assert.is_false(c[1]=="image" and c[5]-c[3]<14) end
        end)
    end)

    describe("art sets, video posters and the lifecycle",function()
        local Color=require("core.imgui.Color")
        local function rgb(v) local r,g,b=Color.unpack(Color.parse(v)); return {r,g,b} end
        it("picks an svg from a set by a signal, every entry made when the scene first shows",function()
            local B=Null.new({scene=true}); local dc=Draw.new(B)
            local made={}
            Scene._svg_pixels=function(src,w,h) made[#made+1]=src; return string.rep("\255",w*h*4),w,h end
            local p={glassDark=true,background={id="set",layers={{svg={signal="mode",set={"<svg>a</svg>","<svg>b</svg>","<svg>c</svg>"}},size=8}}}}
            frame(B,dc,p)
            local before=Scene.stats().uploads
            frame(B,dc,p)
            assert.equal(3,#made); assert.equal(before,Scene.stats().uploads)
            local scene=Scene._scene_of(p.background)
            assert.is_true(scene.layers[1].deps.mode)
            assert.equal("<svg>a</svg>",scene.layers[1].art({mode=0}))
            assert.equal("<svg>b</svg>",scene.layers[1].art({mode=0.5}))
            assert.equal("<svg>c</svg>",scene.layers[1].art({mode=1}))
            -- a switch draws the other entries without a new upload
            frame(B,dc,{glassDark=false,background=p.background})
            clock=clock+2; frame(B,dc,{glassDark=false,background=p.background})
            assert.equal(before,Scene.stats().uploads); assert.equal(3,#made)
        end)
        it("shows a video layer's poster, never loads its file as art, and costs nothing idle",function()
            local B=Null.new({scene=true}); local dc=Draw.new(B)
            local loaded={}
            Scene._svg_pixels=function(src,w,h) loaded[#loaded+1]=src; return string.rep("\255",w*h*4),w,h end
            local p={background={id="v",layers={{kind="video",file="clip.mp4",poster={svg="<svg>poster</svg>"},size=16},
                {kind="video",file="other.mp4",size=16}}}}
            frame(B,dc,p)
            assert.same({"<svg>poster</svg>"},loaded)
            assert.is_nil(Scene._scene_of(p.background).deps.time)
            assert.is_nil(Scene.due())
            for _=1,10 do clock=clock+1; frame(B,dc,p) end
            assert.equal(1,B.scene_renders)
        end)
        it("drops the scene and its idle ticks when the theme leaves it, keeping the rail",function()
            local B=Null.new({scene=true}); local dc=Draw.new(B)
            local twinkle={background={id="t",layers={{kind="stars",count=5,twinkle={amount=1,share=1}}}}}
            Reactor.palette=function() return twinkle end
            Scene.set("rail",1)
            frame(B,dc,twinkle)
            assert.is_not_nil(Scene.due())
            Reactor.palette=function() return {bg="0 0 0"} end   -- Carbon: no scene
            assert.is_nil(Scene.due())
            assert.is_false(Scene.tick(B))
            assert.is_nil(Scene.textures(B))
            assert.equal(1,Scene.get("rail"))
        end)
        it("serves a mode ease with one frame of the UI, its tint held for the whole ease, then one full frame",function()
            local B=Null.new({scene=true}); local dc=Draw.new(B)
            local dark=require("core.classes.Themes.LunarDarkTheme"):new():palette()
            local light=require("core.classes.Themes.LunarLightTheme"):new():palette()
            frame(B,dc,dark,1920,1080)
            assert.equal(dark.glassFrameAlpha,Scene.frameAlpha(dark))
            frame(B,dc,light,1920,1080)
            -- the UI is light, the sky still night: the frame holds its labels' contrast
            local held=Scene.frameAlpha(light)
            assert.is_true(held>light.glassFrameAlpha+0.2)
            -- that frame of the UI serves the ease: the sky moves in scene-only presents, under
            -- a tint that does not change
            local renders,frames=B.scene_renders,B.frames
            clock=clock+Scene.MODE_DELAY+0.01
            assert.is_true(Scene.tick(B))
            clock=clock+Scene.MODE_EASE/2
            assert.is_true(Scene.tick(B))
            assert.equal(renders+2,B.scene_renders); assert.equal(frames,B.frames)
            assert.equal(held,Scene.frameAlpha(light))
            -- after it, one frame of the UI: the tint back to rest
            clock=clock+Scene.MODE_EASE
            assert.is_false(Scene.tick(B))
            frame(B,dc,light,1920,1080)
            assert.equal(0,Scene.lag(clock))
            assert.equal(light.glassFrameAlpha,Scene.frameAlpha(light))
        end)
        it("keeps labels on the frame at 4.5:1 at every step of a switch, both ways",function()
            for _,ui in ipairs({"LunarDarkTheme","LunarLightTheme"}) do
                local p=require("core.classes.Themes."..ui):new():palette()
                local other=require("core.classes.Themes."..(ui=="LunarDarkTheme" and "LunarLightTheme" or "LunarDarkTheme")):new():palette()
                local B=Null.new({scene=true}); local dc=Draw.new(B)
                Scene.clear(); frame(B,dc,other,1920,1080); frame(B,dc,p,1920,1080)
                local start=clock
                local tint=rgb(p.glassFrameTint)
                for k=0,40 do
                    local now=start+k*(Scene.MODE_DELAY+Scene.MODE_EASE)/40
                    local a=Scene.frameAlpha(p,now)
                    local lag=Scene.lag(now)
                    local sky=p.glassDark and lag or 1-lag   -- 0 night .. 1 day
                    local bright,dk=Scene.extremes(p.background,{mode=sky})
                    for _,worst in ipairs({bright,dk}) do
                        local under=Scene.over(worst,tint,a)
                        for _,text in ipairs({p.text,p.textMuted}) do
                            assert.is_true(Scene.ratio(rgb(text),under)>=4.5,ui.." step "..k)
                        end
                    end
                end
            end
        end)
        it("stretches the last render through a resize off the GPU path, drawing once it settles",function()
            local B=Null.new({scene=true}); local dc=Draw.new(B)
            frame(B,dc,static,800,600,false)
            for k=1,10 do clock=clock+0.05; frame(B,dc,static,800+k*10,600,false) end
            assert.equal(1,B.scene_renders)
            assert.near(clock+Scene.RESIZE_SETTLE,Scene.due(),1e-9)
            clock=Scene.due()
            -- the last frame's lists sample the old size: a full frame, not a scene-only present
            assert.is_false(Scene.tick(B))
            frame(B,dc,static,900,600,false)
            assert.equal(2,B.scene_renders); assert.is_nil(Scene.due())
        end)
        it("fades Lunar's moon and sun out on a narrow window, where the pages' controls reach them",function()
            local space=require("core.classes.Themes.lunar_space")
            local bg=space.background()
            local scene=Scene._scene_of(bg)
            local moon,sun
            for _,l in ipairs(scene.layers) do
                if l.def.svg and type(l.def.svg)=="table" then moon=l end
                if l.def.svg==space.SVG.sun then sun=l end
            end
            assert.equal(1,moon.opacity({mode=0,width=1920})); assert.equal(0,moon.opacity({mode=0,width=1084}))
            assert.equal(1,sun.opacity({mode=1,width=1920})); assert.equal(0,sun.opacity({mode=1,width=1084}))
        end)
        it("keeps the moon and the sun whole in the band the pages' right panels share (y 325..483)",function()
            local space=require("core.classes.Themes.lunar_space")
            local scene=Scene._scene_of(space.background())
            for _,size in ipairs({{1920,1080},{1500,940},{1600,900}}) do
                for _,l in ipairs(scene.layers) do
                    local body=(type(l.def.svg)=="table" and l.def.svg.set) or l.def.svg==space.SVG.sun
                    if body then
                        local s={mode=l.def.svg==space.SVG.sun and 1 or 0,width=size[1],height=size[2]}
                        local x,y=l.x(s),l.y(s)
                        if x<0 then x=size[1]+x end
                        local r=l.def.size*l.scale(s)/2+math.abs(l.parallax(s))
                        assert.is_true(y-r>=325 and y+r<=483,"body in the band at "..size[1])
                        assert.near(size[1]-192,x,0.5)
                    end
                end
            end
        end)
        it("derives Lunar's contrast samples from its layer table",function()
            local space=require("core.classes.Themes.lunar_space")
            local bright=Scene.extremes(space.background(),{mode=0})
            local _,dark=Scene.extremes(space.background(),{mode=1})
            local function near(sample,c)
                local i=0
                for v in sample:gmatch("%d+") do i=i+1; assert.is_true(math.abs(tonumber(v)-c[i])<=1) end
            end
            near(space.SAMPLES.dark.frame,bright); near(space.SAMPLES.light.frame,dark)
            -- the moon, sun, galaxy and crescent never lie under labels; the glows count where they reach
            assert.is_true(bright[1]<140)
        end)
    end)
end)
