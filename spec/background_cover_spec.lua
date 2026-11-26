local Scene=require("core.ui.Background")
local Null=require("core.imgui.backend.Null")
local Draw=require("core.imgui.Draw")
local Reactor=require("core.ui.ThemeReactor")

-- Whole-or-hidden layers (`whole = true`): a body partly covered by the layout laid over it
-- fades out; wholly clear or wholly covered, it shows.
local clock,motion_on,wakes
describe("whole-or-hidden background layers",function()
    local saved_rt,saved_tm,saved_svg,saved_pal
    before_each(function()
        clock,motion_on,wakes=10,true,{}
        saved_rt=package.loaded["core.imgui.Runtime"]
        package.loaded["core.imgui.Runtime"]={ now=function() return clock end, pointer=function() return -1,-1,false end,
            wakeAt=function(t) wakes[#wakes+1]=t end, animate=function() end }
        saved_tm,saved_pal=Reactor.themeManager,Reactor.palette
        Reactor.themeManager=function() return { _motion={ enabled=function() return motion_on end, _scale=1 } } end
        Reactor.palette=function() return nil end
        saved_svg=Scene._svg_pixels
        Scene._svg_pixels=function(src,w,h) return string.rep("\255",w*h*4),w,h end
        Scene.clear(); Scene.reset()
    end)
    after_each(function()
        package.loaded["core.imgui.Runtime"]=saved_rt
        Reactor.themeManager,Reactor.palette=saved_tm,saved_pal
        Scene._svg_pixels=saved_svg
        Scene.clear(); Scene.reset()
    end)

    -- a 100 px body centred at (600, 300) in an 800 x 600 window
    local function scene() return {background={id="w",layers={{kind="fill",top="#000010",bottom="#000020"},
        {svg="<svg/>",size=100,unit="px",x=600,y=300,whole=true}}}} end
    -- one frame of the UI: the floor, then `rects` painted as opaque fills over it
    local function frame(B,dc,p,rects,live)
        B.frame_begin(); dc:begin(800,600)
        Scene.floor(dc,0,0,800,600,p,live~=false)
        for _,r in ipairs(rects or {}) do dc:fill(r[1],r[2],r[3],r[4],r[5] or "#202020") end
        Scene.cover(dc.cover)
        B.frame_end()
    end
    local function body_alpha(B)
        local a=0
        for _,c in ipairs(B.scene_calls) do if c[1]=="image" then a=math.floor(c[11]/16777216)%256 end end
        return a
    end

    it("classifies a box as clear, covered or partial against the rects over it",function()
        assert.equal("clear",Scene.coverage(0,0,100,100,{}))
        assert.equal("clear",Scene.coverage(0,0,100,100,{{200,0,300,100}}))
        assert.equal("covered",Scene.coverage(0,0,100,100,{{-10,-10,110,110}}))
        -- two rects meeting edge to edge cover it whole
        assert.equal("covered",Scene.coverage(0,0,100,100,{{-10,-10,50,110},{50,-10,110,110}}))
        -- a gap between two panels
        assert.equal("partial",Scene.coverage(0,0,100,100,{{-10,-10,110,40},{-10,60,110,110}}))
        assert.equal("partial",Scene.coverage(0,0,100,100,{{50,50,200,200}}))
        -- gaps of 2, 3 and 4 px between two rows of panels, anywhere across the box (a
        -- sampling grid could step over them)
        for gap=2,4 do
            for y=1,95,7 do
                assert.equal("partial",Scene.coverage(0,0,100,100,{{-10,-10,110,y},{-10,y+gap,110,110}}),
                    "gap "..gap.." at "..y)
                assert.equal("partial",Scene.coverage(0,0,100,100,{{-10,-10,y,110},{y+gap,-10,110,110}}),
                    "column gap "..gap.." at "..y)
            end
        end
        -- many rects tiling it with no gap
        local tiles={}
        for i=0,9 do tiles[#tiles+1]={i*10,-5,i*10+10,50}; tiles[#tiles+1]={-5,50,105,105} end
        tiles[#tiles+1]={-5,-5,0,50}; tiles[#tiles+1]={100,-5,105,50}
        assert.equal("covered",Scene.coverage(0,0,100,100,tiles))
        -- only touching its edge: clear
        assert.equal("clear",Scene.coverage(0,0,100,100,{{100,0,200,100},{-50,-50,0,150}}))
    end)

    it("hides a body behind a 2-4 px gap between two opaque panels",function()
        for gap=2,4 do
            Scene.clear(); Scene.reset()
            local B=Null.new({scene=true}); local dc=Draw.new(B); local p=scene()
            -- the body spans y 250..350; the gap falls between two 8 px rows of the old grid
            frame(B,dc,p,{{500,200,200,99},{500,299+gap,200,100}})
            assert.equal("partial",(Scene.coverState(2)),"gap "..gap)
        end
    end)

    it("shows a body whole when nothing covers it and when a panel covers it all",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B); local p=scene()
        frame(B,dc,p,{})
        assert.equal("clear",(Scene.coverState(2)))
        frame(B,dc,p,{{500,200,200,200}})
        assert.equal("covered",(Scene.coverState(2)))
        local _,v=Scene.coverState(2); assert.equal(1,v)
    end)

    it("hides a partly covered body from the first layout it meets, in that first frame",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B); local p=scene()
        -- a panel over its top half, another below: a gap across its middle
        frame(B,dc,p,{{500,200,200,90},{500,320,200,100}})
        assert.equal("partial",(Scene.coverState(2)))
        local _,v=Scene.coverState(2); assert.equal(0,v)
        -- the scene this first frame presents (its last emitted list) already leaves it out
        assert.equal(0,body_alpha(B))
        frame(B,dc,p,{{500,200,200,90},{500,320,200,100}})
        assert.equal(0,body_alpha(B))
    end)

    it("shows a clear body in the first frame, emitting the scene once",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B); local p=scene()
        frame(B,dc,p,{})
        assert.equal(255,body_alpha(B))
        assert.equal(1,B.scene_renders)
    end)

    it("counts a replayed recording's fills inside the recording's own clip, as drawn directly",function()
        local function run(replayed)
            Scene.clear(); Scene.reset()
            local B=Null.new({scene=true}); local dc=Draw.new(B); local p=scene()
            B.frame_begin(); dc:begin(800,600)
            Scene.floor(dc,0,0,800,600,p,true)
            local function paint()
                -- a canvas 200 x 60 at (500, 200) whose fill overflows below its clip
                dc:clip_push(500,200,200,60)
                dc:fill(500,200,200,300,"#202020")
                dc:clip_pop()
            end
            if replayed then
                dc:record(); paint(); local list=dc:stop()
                dc:replay(list)
            else
                paint()
            end
            local rects=dc.cover
            Scene.cover(rects); B.frame_end()
            return rects, (Scene.coverState(2))
        end
        local direct, ds = run(false)
        local replay, rs = run(true)
        assert.same(direct, replay)
        assert.same({{500,200,700,260}}, direct)
        assert.equal("partial", ds); assert.equal(ds, rs)
    end)

    it("fades out over COVER_FADE as a layout leaves it partly covered, and back in",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B); local p=scene()
        frame(B,dc,p,{})
        local renders=B.scene_renders
        frame(B,dc,p,{{500,200,200,90}})       -- now only its top is covered
        assert.equal("partial",(Scene.coverState(2)))
        assert.is_true(#wakes>0)
        -- the fade is scheduled for the idle loop: scene-only presents, not frames of the UI
        local due=Scene.due(); assert.is_not_nil(due)
        clock=clock+Scene.COVER_FADE/2
        assert.is_true(Scene.tick(B))
        assert.is_true(B.scene_renders>renders)
        local mid=body_alpha(B); assert.is_true(mid>40 and mid<215,"half way: "..mid)
        clock=clock+Scene.COVER_FADE
        assert.is_true(Scene.tick(B))
        assert.equal(0,body_alpha(B))
        -- the last value drawn, nothing more is owed
        assert.is_nil(Scene.due())
        -- covered whole again: it fades back in
        frame(B,dc,p,{{500,200,200,200}})
        clock=clock+Scene.COVER_FADE*2
        assert.is_true(Scene.tick(B))
        assert.equal(255,body_alpha(B))
    end)

    it("counts only opaque fills of at least COVER_MIN px, on the main window's base layer",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B); local p=scene()
        frame(B,dc,p,{{500,200,200,90,"32 32 32 128"}})   -- translucent: not a cover
        assert.equal("clear",(Scene.coverState(2)))
        frame(B,dc,p,{{560,260,10,10}})                    -- too small to count
        assert.equal("clear",(Scene.coverState(2)))
        B.frame_begin(); dc:begin(800,600)
        Scene.floor(dc,0,0,800,600,p,true)
        dc:layer("overlay"); dc:fill(500,200,200,90,"#202020"); dc:layer(0)   -- a menu
        Scene.cover(dc.cover); B.frame_end()
        assert.equal("clear",(Scene.coverState(2)))
    end)

    it("cuts a fill to its clip, and counts a sliding page where it will rest",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B); local p=scene()
        B.frame_begin(); dc:begin(800,600)
        Scene.floor(dc,0,0,800,600,p,true)
        -- the strip's client (0..800); the arriving page is 300 px to the right of its place
        dc:clip_push(0,0,800,600)
        local saved=dc:coverShift(300,0,0,0,800,600,false)
        dc:offset_push(300,0)
        dc:fill(200,200,500,90,"#202020")   -- drawn at 500..1000 (clipped at 800), rests at 200..700
        dc:offset_pop(); dc:coverRestore(saved)
        local gone=dc:coverShift(0,0,0,0,0,0,true)
        dc:fill(500,320,200,100,"#202020")  -- the leaving page: never counts
        dc:coverRestore(gone)
        dc:clip_pop()
        assert.same({{200,200,700,290}},dc.cover)
        Scene.cover(dc.cover); B.frame_end()
        assert.equal("partial",(Scene.coverState(2)))
    end)

    it("decides where the sky is going: the sun's place at the mode it eases to",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B)
        local layers={{kind="fill",top="#000010",bottom="#000020"},
            {svg="<svg/>",size=100,unit="px",x=600,y={signal="mode",from=700,to=300},whole=true}}
        local dark={glassDark=true,background={id="m",layers=layers}}
        local light={glassDark=false,background={id="m",layers=layers}}
        local panel={{500,200,200,90}}
        frame(B,dc,dark,panel)
        assert.equal("clear",(Scene.coverState(2)))   -- below the window, nothing over it
        frame(B,dc,light,panel)                        -- the ease starts: it will rest at y 300
        assert.equal("partial",(Scene.coverState(2)))
    end)

    -- one frame of the UI in a W x H window
    local function frame_at(B,dc,p,W,H,rects,live)
        B.frame_begin(); dc:begin(W,H)
        Scene.floor(dc,0,0,W,H,p,live~=false)
        for _,r in ipairs(rects or {}) do dc:fill(r[1],r[2],r[3],r[4],r[5] or "#202020") end
        Scene.cover(dc.cover)
        B.frame_end()
    end
    -- the floor's image of the scene target on the frame just ended: its uv at the window's
    -- bottom-right corner
    local function floor_uv(B)
        for _,c in ipairs(B.last) do
            if c[1]=="image" and c[2]==B.SCENE_SHARP then return c[9],c[10] end
        end
    end

    it("keeps a held resize's size when the cover redraws the scene in that frame (motion off)",function()
        motion_on=false
        local B=Null.new({scene=true}); local dc=Draw.new(B); local p=scene()
        frame_at(B,dc,p,800,600,{})
        assert.equal(255,body_alpha(B))
        -- the window grows within RESIZE_SETTLE: the floor keeps the 800 x 600 render,
        -- stretched; the layout laid over it now leaves the body partly covered
        local W,H,partial=900,650,{{500,200,200,90},{500,320,200,100}}
        for _,step in ipairs({ {partial,0}, {{},255}, {partial,0} }) do
            clock=clock+0.02
            local renders=B.scene_renders
            frame_at(B,dc,p,W,H,step[1])
            -- on that same present: the body is right, rendered at the held size ...
            assert.equal(step[2],body_alpha(B))
            assert.equal(renders+1,B.scene_renders)
            assert.same({800,600},B.scene_size)
            -- ... and the floor and the glass map the window onto that render
            local u,v=floor_uv(B)
            local tw,th=math.ceil(800/256)*256,math.ceil(600/256)*256
            assert.near(800/tw,u,1e-9); assert.near(600/th,v,1e-9)
            local _,_,ku,kv=Scene.textures(B)
            assert.near(u,ku*W,1e-9); assert.near(v,kv*H,1e-9)
        end
        -- the size has held: its own redraw comes, at the new size
        clock=clock+Scene.RESIZE_SETTLE+0.01
        frame_at(B,dc,p,W,H,partial)
        assert.same({W,H},B.scene_size)
        assert.equal(0,body_alpha(B))
        local u=floor_uv(B)
        assert.near(W/math.ceil(W/256)/256,u,1e-9)
    end)

    it("recolours the direct-draw floor's body in the frame that found the change",function()
        -- no scene target (an SDL host, the Null backend): the layers straight onto the list;
        -- motion off, so each change is instant
        motion_on=false
        local B=Null.new(); local dc=Draw.new(B); local p=scene()
        local function drawn()
            local a
            for _,c in ipairs(B.last) do
                if c[1]=="image" then a=math.floor(c[11]/16777216)%256 end
            end
            return a
        end
        local partial={{500,200,200,90},{500,320,200,100}}
        frame_at(B,dc,p,800,600,partial)
        assert.equal(0,drawn())       -- the first layout: hidden at once
        clock=clock+0.02
        frame_at(B,dc,p,800,600,{})
        assert.equal(255,drawn())     -- clear again: shown in that same frame
        clock=clock+0.02
        frame_at(B,dc,p,800,600,partial)
        assert.equal(0,drawn())
        clock=clock+0.02
        frame_at(B,dc,p,800,600,partial)
        assert.equal(0,drawn())       -- unchanged: drawn hidden from the start
    end)

    it("switches at once off the GPU path (static scene)",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B); local p=scene()
        frame(B,dc,p,{},false)
        frame(B,dc,p,{{500,200,200,90}},false)
        local _,v=Scene.coverState(2); assert.equal(0,v)
    end)

    it("draws an `above` layer over the frame's tint, not into the scene target",function()
        local B=Null.new({scene=true}); local dc=Draw.new(B)
        local p={background={id="a",layers={{kind="fill",top="#000010",bottom="#000020"},
            {svg="<svg/>",size=40,unit="px",x=100,y=500,above=true}}}}
        B.frame_begin(); dc:begin(800,600)
        Scene.floor(dc,0,0,800,600,p,true)
        local in_scene=0
        for _,c in ipairs(B.scene_calls) do if c[1]=="image" then in_scene=in_scene+1 end end
        assert.equal(0,in_scene)
        local before=#B.frame_calls
        Scene.above(dc,0,0,800,600)
        local img
        for i=before+1,#B.frame_calls do if B.frame_calls[i][1]=="image" then img=B.frame_calls[i] end end
        B.frame_end()
        assert.is_not_nil(img)
        assert.near(80,img[3],1e-9); assert.near(480,img[4],1e-9)
    end)

    it("marks Lunar's moon and sun whole-or-hidden, and its crescents over the frame",function()
        local space=require("core.classes.Themes.lunar_space")
        local scene=Scene._scene_of(space.background())
        local n=0
        for _,l in ipairs(scene.layers) do if l.whole then n=n+1 end end
        assert.equal(2,n)
        assert.is_true(scene.wholes)
        local above=0
        for _,l in ipairs(scene.layers) do if l.def.above then above=above+1 end end
        assert.equal(2,above); assert.is_true(scene.aboves)
    end)
end)
