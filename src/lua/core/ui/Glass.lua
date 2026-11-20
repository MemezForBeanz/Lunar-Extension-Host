--- Static, opt-in Lunar glass. Only two textures survive a size/theme change.
local Color = require("core.imgui.Color")
local Reactor = require("core.ui.ThemeReactor")
local M = {}
local enabled, cache, theme, rules, floating_dialog = true
local floor, ceil, exp = math.floor, math.ceil, math.exp
local shapes = setmetatable({}, {__index=function(t,r) local v={radius=r}; rawset(t,r,v); return v end})
local shadows={}
for i=1,12 do shadows[i]={radius=12+i,thickness=1} end
local function linear(c)
    c=c/255
    return c<=0.04045 and c/12.92 or ((c+0.055)/1.055)^2.4
end
local function srgb(c)
    c=math.min(1,c)
    return floor(255*(c<=0.0031308 and c*12.92 or 1.055*c^(1/2.4)-0.055)+0.5)
end
local function sample(dc,c,tex,left,top,right,bottom)
    dc:_emit("image",tex,left+dc.ox,top+dc.oy,right+dc.ox,bottom+dc.oy,
        (left+dc.ox)/c.w,(top+dc.oy)/c.h,(right+dc.ox)/c.w,(bottom+dc.oy)/c.h,dc:_color(0xFFFFFFFF))
end
local function release()
    if cache and cache.B and cache.B.texture_free then
        for _,c in pairs(cache.by_palette) do
            if c.sharp then cache.B.texture_free(c.sharp) end
            if c.blur then cache.B.texture_free(c.blur) end
        end
    end
    cache = nil
end
function M.setEnabled(value) enabled = value == true; if not enabled then release() end end
function M.enabled() return enabled end
function M.clear() release(); theme, rules, floating_dialog = nil, nil, nil end
function M.stats()
    local bytes = 0
    if cache then for _,c in pairs(cache.by_palette) do bytes = bytes + (c.bytes or 0) end end
    return { bytes = bytes, generations = M.generations or 0 }
end

-- Deterministic pixels at half resolution; blur is quarter resolution and separable
-- Gaussian (24 window pixels). No noise, randomness, or texture work during idle.
function M.pixels(p, w, h)
    local ffi = require("ffi") -- optional: paint falls back to opaque without it
    local sw, sh = ceil(w / 2), ceil(h / 2)
    local r,g,b = Color.unpack(Color.parse(p.bg))
    r,g,b=linear(r),linear(g),linear(b)
    local bw,bh = ceil(sw/2),ceil(sh/2)
    local sharp, data = {}, ffi.new("float[?]",bw*bh*3)
    for y=0,sh-1 do
        local row = {}
        for x=0,sw-1 do
            -- The spec's +7% is luminance, not 7% of an sRGB byte. A broad
            -- crescent bloom reaches the rail's foot and fades out by 60% width.
            -- Generate in linear light so tinting does not erase its shoulder.
            local u=math.min(1,x/sw/(p.glassBloomWidth or 0.60))
            local glow=(p.glassBloom or (p.glassDark and 0.07 or 0.18))*(1-u^4)^2*exp(-0.5*(y/sh/(p.glassBloomHeight or 1.4))^2)
            local rr,gg,bb=srgb(r+glow),srgb(g+glow),srgb(b+glow)
            row[#row+1] = string.char(rr,gg,bb,255)
            if x%2==0 and y%2==0 then
                local i=(floor(y/2)*bw+floor(x/2))*3
                data[i],data[i+1],data[i+2]=rr,gg,bb
            end
        end
        sharp[#sharp+1] = table.concat(row)
    end
    local kernel,total = {},0
    for i=-18,18 do local v=exp(-i*i/72); kernel[i]=v; total=total+v end
    local temp = ffi.new("float[?]",bw*bh*3)
    for y=0,bh-1 do for x=0,bw-1 do
        local rr,gg,bb=0,0,0
        for k=-18,18 do
            local i=(y*bw+math.max(0,math.min(bw-1,x+k)))*3
            local weight=kernel[k]/total
            rr,gg,bb=rr+data[i]*weight,gg+data[i+1]*weight,bb+data[i+2]*weight
        end
        local i=(y*bw+x)*3
        temp[i],temp[i+1],temp[i+2]=rr,gg,bb
    end end
    local blur = {}
    for y=0,bh-1 do
        local row={}
        for x=0,bw-1 do
            local rr,gg,bb=0,0,0
            for k=-18,18 do
                local i=(math.max(0,math.min(bh-1,y+k))*bw+x)*3
                local weight=kernel[k]/total
                rr,gg,bb=rr+temp[i]*weight,gg+temp[i+1]*weight,bb+temp[i+2]*weight
            end
            row[#row+1]=string.char(floor(rr),floor(gg),floor(bb),255)
        end
        blur[#blur+1]=table.concat(row)
    end
    return table.concat(sharp),sw,sh,table.concat(blur),bw,bh
end
-- The backdrop is a smooth glow, so it is generated once per palette at a fixed
-- size (BASE_W x BASE_H) and stretched by the GPU to any window size. Resizing never
-- regenerates it, and each palette keeps its own pair, so switching light/dark back
-- and forth after the first time costs nothing.
local BASE_W, BASE_H = 1024, 576
local function textures(dc,p)
    local w,h = ceil((dc.window_w or 1920)/128)*128,ceil((dc.window_h or 1080)/128)*128
    if not cache or cache.B~=dc.B then release(); cache={B=dc.B,by_palette={}} end
    local c=cache.by_palette[p]
    if not c then
        c={}
        cache.by_palette[p]=c
        if dc.B.texture then
            local ok,a,sw,sh,b,bw,bh=pcall(M.pixels,p,BASE_W,BASE_H)
            if ok then
                local uploaded, sharp, blur = pcall(function() return dc.B.texture(a,sw,sh),dc.B.texture(b,bw,bh) end)
                if uploaded then c.sharp,c.blur=sharp,blur end
                c.bytes=(sw*sh+bw*bh)*4
                M.generations=(M.generations or 0)+1
            end
        end
    end
    -- UVs map window coordinates onto the stretched texture.
    c.w,c.h=w,h
    -- Subpixel stars stay at window resolution, independent of the glow texture.
    -- Cached geometry avoids six-pixel stars after texture upsampling; it is cheap
    -- (one entry per 12000 px), so it follows the window size.
    if p.glassDark and (c.stars_w~=w or c.stars_h~=h) then
        c.stars,c.stars_w,c.stars_h={},w,h
        local seed=731
        local function random() seed=(seed*48271)%2147483647; return seed/2147483647 end
        for i=1,floor(w*h/12000) do
            c.stars[i]={floor(random()*w)+.5,floor(random()*h)+.5,
                Color.pack(255,255,255,31+floor(random()*58)),random()>.55}
        end
    end
    return c
end

--- Paint in window coordinates; native popups use their own static backdrop.
function M.paint(dc,x,y,w,h,kind,p,radius)
    p=p or Reactor.palette()
    if kind=="card" then
        dc:fill(x,y,w,h,p.layer02,shapes[12])
        dc:rect(x,y,w,h,p.glassDark and "255 255 255 15" or "0 0 0 15",shapes[12])
        return
    end
    local floating=kind=="floating" or kind=="content"
    local bg=kind=="floor" and p.bg or (floating and (p.layer03 or p.layer02) or p.layer01)
    if not bg then return end
    local c=enabled and p.glass and textures(dc,p)
    local tex=c and (kind=="floor" and c.sharp or c.blur)
    local options=shapes[kind=="content" and 0 or radius or (floating and 12 or 0)]
    if kind=="floating" and p.glass then
        for i=12,1,-1 do
            dc:rect(x-i,y+4-i,w+2*i,h+2*i,Color.pack(0,0,0,p.glassDark and 7 or 3),shadows[i])
        end
    end
    dc:fill(x,y,w,h,bg,options)
    if tex then
        dc:clip_push(x,y,w,h)
        -- Clip the sampled image to the same rounded contour as the tint. The
        -- backend's rounded image primitive cannot yet sample UV subrectangles.
        local rad=math.min(options.radius,w/2,h/2)
        if rad>0 then
            for row=0,ceil(rad)-1 do
                local inset=rad-math.sqrt(math.max(0,rad*rad-(rad-row-.5)^2))
                sample(dc,c,tex,x+inset,y+row,x+w-inset,y+row+1)
                sample(dc,c,tex,x+inset,y+h-row-1,x+w-inset,y+h-row)
            end
            sample(dc,c,tex,x,y+ceil(rad),x+w,y+h-ceil(rad))
        else sample(dc,c,tex,x,y,x+w,y+h) end
        dc:clip_pop()
        if kind~="floor" then
            local tint=floating and (p.glassDark and p.layer03 or "255 255 255") or p.layer01
            local alpha=floating and (p.glassFloatingAlpha or (p.glassDark and 0.88 or 0.90))
                or (p.glassChromeAlpha or (p.glassDark and 0.78 or 0.82))
            dc:fill(x,y,w,h,Color.alpha(Color.parse(tint),alpha),options)
        end
    end
    -- Stars belong to the chrome sample too: painting only the floor let the
    -- opaque chrome undercoat erase them before the glass was composited.
    if tex and c.stars and not floating then
        dc:clip_push(x,y,w,h)
        for _,star in ipairs(c.stars) do
            if star[1]>=x and star[1]<x+w and star[2]>=y and star[2]<y+h then
                local extent=star[4] and 1 or 0
                dc:line(star[1]-extent,star[2],star[1]+extent,star[2],star[3],1)
                if star[4] then dc:line(star[1],star[2]-1,star[1],star[2]+1,star[3],1) end
            end
        end
        dc:clip_pop()
    end
    if tex and kind~="floor" and kind~="content" and kind~="chrome_content" then
        dc:rect(x,y,w,h,p.glassRim or (p.glassDark and "255 255 255 15" or "0 0 0 20"),options)
        dc:line(x+options.radius,y+0.5,x+w-options.radius,y+0.5,p.glassTopRim or (p.glassDark and "255 255 255 36" or "255 255 255 204"))
    end
end

-- Resolve flags once per theme, rather than allocating rules per widget/frame.
function M.material(el,st)
    local manager=Reactor.themeManager()
    local active=manager and manager:activeTheme()
    if active~=theme then
        -- Textures are cached per palette, so a theme switch keeps them for the way back.
        theme=active; rules=active and active:rules() or {}
        floating_dialog={bg=rules.dialog and rules.dialog.bg,glass="floating",radius=12}
    end
    if not rules then return end
    local p=active and active:palette()
    if not p or not p.glass then return end
    local role=st.attrs.THEMEROLE or st.classname
    local r=rules[role]
    if r and r.glass=="floor" and st.attrs.PARENTDIALOG then r=floating_dialog end
    if r and r.glass then return r,p end
end
return M
