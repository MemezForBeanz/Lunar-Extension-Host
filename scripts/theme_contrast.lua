-- Headless WCAG audit. Run with LuaJIT from the repository root.
local lunar = require("core.classes.Themes.lunar_rules")
local M = {}
local function channels(c) local t={} for v in tostring(c):gmatch("%d+") do t[#t+1]=tonumber(v) end return t end
--- The composited background under glass labels: the palette's worst backdrop sample
-- (`glassSampleWorst`, measured from assets/glass by gen_glass_assets.py) under the tint.
-- Over a reactive background (core.ui.Scene) the shell's labels lie on the frame: the
-- scene's worst pixel (`glassSampleWorst`, lunar_space.SAMPLES) under the frame's tint.
function M.composite(p,floating)
    local tint=channels(floating and (p.glassFloatingTint or p.layer03) or (p.glassChromeTint or p.layer01))
    local a=floating and (p.glassFloatingAlpha or .76) or (p.glassChromeAlpha or .58)
    local s=channels(p.glassSampleWorst or p.bg)
    if p.background then
        -- floating glass sees the frame (the scene already under the frame's tint)
        if floating then s=channels(M.composite(p,false))
        else tint=channels(p.glassFrameTint or p.bg); a=p.glassFrameAlpha or 0 end
    end
    local c={}
    for i=1,3 do c[i]=math.floor(s[i]*(1-a)+tint[i]*a+0.5) end
    return table.concat(c," ")
end
-- Roles whose labels sit on chrome glass (title strip, rail caps, status strip, the
-- transport) and roles whose text sits on the floating surfaces' opaque wells.
M.ON_CHROME={"titlebar_button","titlebar_tabs","titlebar_title","statusbar_text","statusbar_button","icon_btn",
    "tool_rail","reading","reading_muted","keycap"}
M.ON_WELL={"palette_text","palette_prompt","palette_hint","palette_list","palette_rows","dropdown_list",
    "toast_title","toast_body","toast_close"}
-- Floating surfaces named explicitly, with the roles whose text they carry: Activity
-- (rows, header, hint on its opaque well) and the tooltip (frosted glass, no well).
M.SURFACES={
    {name="activity",roles={"palette_text","palette_list","palette_hint"},on="well"},
    {name="tooltip",on="bound"},
    {name="transport",roles={"reading","reading_muted","icon_btn"},on="bound"},
}
--- The darkest (dark) or lightest (light) final background the GPU glass may leave under
-- text: frosted and live glass bound their luminance to 0.0622 / 0.62 (core.ui.Glass).
function M.boundGrey(p)
    local L=p.glassDark and (p.glassLumMax or 0.0622) or (p.glassLumMin or 0.62)
    local c=L<=0.0031308 and L*12.92 or 1.055*L^(1/2.4)-0.055
    -- round away from the bound, as the shader's result can sit exactly on it
    local v=p.glassDark and math.ceil(c*255) or math.floor(c*255)
    return v.." "..v.." "..v
end
--- The spec's bound on that background: relative luminance <= 0.0622 (dark) / >= 0.62 (light).
function M.inBound(p,colour)
    local L=(lunar.contrast(colour,"0 0 0")*0.05)-0.05
    if p.glassDark then return L<=0.0622 end
    return L>=0.62
end
function M.audit(theme, output)
    local p, rules = theme:palette(), theme:rules()
    local failures, count = {}, 0
    local function check(role,state,fg,bg,minimum)
        if not fg or not bg then return end
        local ratio=lunar.contrast(fg,bg)
        count=count+1
        if output then output(string.format("%s.%s %.2f:1 (%.1f required)",role,state,ratio,minimum)) end
        if ratio+0.001 < minimum then failures[#failures+1]=role.."."..state.." "..string.format("%.2f",ratio) end
    end
    for role,r in pairs(rules) do
        -- snap_preview is a translucent docking indicator; it contains no text.
        if role ~= "snap_preview" then
        local bg=r.bg or p.layer02 or p.bg
        check(role,"text",r.fg,bg,4.5)
        if r.hover then check(role,"hover",r.hovertext or r.fg,r.hover,4.5) end
        if r.pressed then check(role,"pressed",r.pressedtext or r.fg,r.pressed,4.5) end
        if r.selbg then check(role,"selected",r.seltext or r.fg,r.selbg,4.5) end
        check(role,"secondary",r.secondary,bg,4.5)
        check(role,"inactive",r.inactivefg,r.inactivebg or bg,4.5)
        check(role,"tabs",r.tabsfg,r.tabsbg or bg,4.5)
        if r.glass and r.glass~="card" and r.glass~="none" and p.glass then
            local floating=r.glass=="floating" or r.glass=="content"
            if floating then
                -- Floating text sits on the opaque well inside the text-free lip.
                local well=p.glassTextWell or p.layer03
                check(role,"well",r.fg,well,4.5)
                check(role,"well secondary",r.secondary,well,4.5)
            else
                -- Chrome labels: the worst sample of the baked backdrop where labels sit
                -- (brightest dark, darkest light) under the tint, on final pixels.
                local under=M.composite(p,false)
                check(role,"glass",r.fg,under,4.5)
                if r.tabsfg then check(role,"glass tabs",r.tabsfg,under,4.5) end
                if not M.inBound(p,under) then
                    count=count+1; failures[#failures+1]=role..".glass bound "..under
                end
            end
        end
        end
    end
    if p.glass then
        -- Every state on its final background: chrome roles over the composited glass (at
        -- its worst sample), well roles over the opaque well. A translucent state fill is
        -- blended over that background first.
        local chrome_bg=M.composite(p,false)
        local well=p.glassTextWell or p.layer03
        local function final(fill,under)
            if not fill then return under end
            local f=channels(fill)
            if not f[4] or f[4]>=255 then return fill end
            local u=channels(under); local a=f[4]/255; local out={}
            for i=1,3 do out[i]=math.floor(f[i]*a+u[i]*(1-a)+0.5) end
            return table.concat(out," ")
        end
        local function states(role,r,under)
            local fg=r.fg
            check(role,"final rest",fg,under,4.5)
            if r.hover then check(role,"final hover",r.hovertext or fg,final(r.hover,under),4.5) end
            if r.selbg then check(role,"final selected",r.seltext or fg,final(r.selbg,under),4.5) end
            if r.pressed then check(role,"final pressed",r.pressedtext or r.hovertext or fg,final(r.pressed,under),4.5) end
            if r.secondary then check(role,"final secondary",r.secondary,under,4.5) end
            -- muted body text can sit in any of those states too (Activity rows, menus)
            local muted=p.textMuted
            check(role,"final muted rest",muted,under,4.5)
            if r.hover then check(role,"final muted hover",muted,final(r.hover,under),4.5) end
            if r.selbg then check(role,"final muted selected",muted,final(r.selbg,under),4.5) end
            if r.pressed then check(role,"final muted pressed",muted,final(r.pressed,under),4.5) end
        end
        for _,role in ipairs(M.ON_CHROME) do
            local r=rules[role]
            if r then states(role,r,chrome_bg) end
        end
        for _,role in ipairs(M.ON_WELL) do
            local r=rules[role]
            if r then states(role,r,well) end
        end
        if not M.inBound(p,chrome_bg) then count=count+1; failures[#failures+1]="chrome bound "..chrome_bg end
        -- the explicit list: each surface's roles in every state on its final background
        local bound=M.boundGrey(p)
        for _,surface in ipairs(M.SURFACES) do
            local under=surface.on=="well" and well or bound
            if surface.name=="tooltip" then
                local fg=p.textInverse or p.text
                check("tooltip","final rest",fg,under,4.5)
                check("tooltip","final muted rest",p.textMuted,under,4.5)
            end
            for _,role in ipairs(surface.roles or {}) do
                local r=rules[role]
                if r then states(surface.name..":"..role,r,under) end
            end
        end
    end
    if p.glass and p.glassTextWell then
        -- Muted text on the wells (palette results, Activity rows, toasts).
        check("glassTextWell","text",p.text,p.glassTextWell,4.5)
        check("glassTextWell","muted",p.textMuted,p.glassTextWell,4.5)
    end
    for _,role in ipairs({"text","dropbutton","text_focus"}) do
        local r=rules[role]; check(role,"boundary",r.border,r.bg,3)
    end
    for _,role in ipairs({"flattoggle","flattoggle_noborder"}) do
        local r=rules[role]
        check(role,"on knob",r.switchknob,r.switchon,3)
        check(role,"off knob",r.switchknob,r.switchoff,3)
    end
    return failures,count
end
if ... ~= "scripts.theme_contrast" then
    local id=arg and arg[1] or "lunar_dark"
    local name=id=="lunar_light" and "LunarLightTheme" or "LunarDarkTheme"
    local failures,count=M.audit(require("core.classes.Themes."..name):new(),print)
    print(count.." pairs; "..#failures.." failures")
    if #failures>0 then os.exit(1) end
end
return M
