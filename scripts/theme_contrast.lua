-- Headless WCAG audit. Run with LuaJIT from the repository root.
local lunar = require("core.classes.Themes.lunar_rules")
local M = {}
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
        if r.glass and r.glass~="card" and r.fg then
            -- Worst neutral glow (+18 sRGB) under the specified tint.
            local tint=r.glass=="floating" and (p.glassDark and p.layer03 or "255 255 255") or p.layer01
            local a=r.glass=="floating" and (p.glassDark and .88 or .9) or (p.glassDark and .78 or .82)
            local c,t={},{}; for v in p.bg:gmatch("%d+") do c[#c+1]=tonumber(v)+18 end
            for v in tint:gmatch("%d+") do t[#t+1]=tonumber(v) end
            for i=1,3 do c[i]=math.floor(math.min(255,c[i])*(1-a)+t[i]*a) end
            check(role,"glass",r.fg,table.concat(c," "),4.5)
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
