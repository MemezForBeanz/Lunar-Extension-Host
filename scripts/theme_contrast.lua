-- Headless WCAG audit. Run with LuaJIT from the repository root.
local lunar = require("core.classes.Themes.lunar_rules")
local M = {}
local function channels(c) local t={} for v in tostring(c):gmatch("%d+") do t[#t+1]=tonumber(v) end return t end
--- The composited background under glass labels: the palette's worst backdrop sample
-- (`glassSampleWorst`, measured from assets/glass by gen_glass_assets.py) under the tint.
function M.composite(p,floating)
    local tint=channels(floating and (p.glassFloatingTint or p.layer03) or (p.glassChromeTint or p.layer01))
    local a=floating and (p.glassFloatingAlpha or .76) or (p.glassChromeAlpha or .58)
    local s=channels(p.glassSampleWorst or p.bg)
    local c={}
    for i=1,3 do c[i]=math.floor(s[i]*(1-a)+tint[i]*a+0.5) end
    return table.concat(c," ")
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
            -- Final pixels: the worst sample of the baked backdrop (brightest in the dark
            -- mode, darkest in the light) under the surface's tint, and every state on it.
            local floating=r.glass=="floating" or r.glass=="content"
            local under=M.composite(p,floating)
            check(role,"glass",r.fg,under,4.5)
            if r.tabsfg then check(role,"glass tabs",r.tabsfg,under,4.5) end
            if not M.inBound(p,under) then
                count=count+1; failures[#failures+1]=role..".glass bound "..under
            end
        end
        end
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
