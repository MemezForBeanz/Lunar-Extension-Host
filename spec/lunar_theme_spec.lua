--- Lunar Dark / Lunar Light themes and the lunar_rules builder.
--
-- The contract under test: a theme role REPLACES the class rule (ThemeManager
-- selects `rules[role] or rules[cls]`), so every role must be complete, and
-- every role the app's widgets name must exist in every builder's output.

local carbon = require("core.classes.Themes.carbon_rules")
local fluent = require("core.classes.Themes.fluent_rules")
local lunar  = require("core.classes.Themes.lunar_rules")

-- A representative palette with the full token set (carbon's expanded names).
local function palette()
    local p = {
        bg = "10 10 10", layer01 = "20 20 20", layer02 = "30 30 30",
        layerHover01 = "40 40 40", layerSelected01 = "50 50 50",
        borderSubtle01 = "60 60 60", borderStrong01 = "70 70 70",
        text = "200 200 200", textMuted = "150 150 150",
        accent = "100 100 250", accentText = "255 255 255",
        error = "220 30 40", success = "30 160 70", warning = "230 190 120",
        warningText = "10 10 10", info = "80 180 190",
        font = "Segoe UI, 10",
        gradTop = "100 100 250", gradBottom = "50 50 120",
        radius = 4, radiusFrame = 6,
        gradEnabled = true, accentHover = "120 120 255",
    }
    p.surface, p.surface2 = p.layer01, p.layerHover01
    p.border, p.borderStrong = p.borderSubtle01, p.borderStrong01
    p.listBg, p.listText, p.listSelText = p.layer01, p.text, p.accent
    return p
end

local NEW_ROLES = {
    "error_label", "success_label", "warning_label", "info_label",
    "mono", "mono_hint", "list_mono", "statusbar", "statusbar_text",
    "ghost_btn", "link_btn", "icon_btn",
}

describe("lunar_rules", function()
    it("provides complete mono lists and inactive button colors in every builder", function()
        for _, builder in ipairs({ carbon, fluent, lunar }) do
            local rules = builder.build(palette())
            for key, value in pairs(rules.list_bordered) do
                if key ~= "font" then assert.equal(value, rules.list_mono[key], key) end
            end
            assert.equal("Consolas, 9", rules.list_mono.font)
            for _, role in ipairs({ "flatbutton", "primary_btn", "actionbutton", "ghost_btn",
                                    "danger_btn", "warning_btn", "info_btn", "link_btn", "icon_btn" }) do
                assert.is_string(rules[role].inactivebg, role)
                assert.equal(palette().textMuted, rules[role].inactivefg, role)
            end
        end
    end)
    it("covers every role carbon_rules emits, so no widget is left unstyled", function()
        local c, l = carbon.build(palette()), lunar.build(palette())
        for role in pairs(c) do
            assert.is_table(l[role], "lunar_rules is missing role '" .. tostring(role) .. "'")
        end
    end)

    it("defines the semantic and status roles", function()
        local l = lunar.build(palette())
        for _, role in ipairs(NEW_ROLES) do
            assert.is_table(l[role], "missing " .. role)
        end
        assert.equal("220 30 40", l.error_label.fg)
        assert.truthy(l.mono.font:find("Consolas"))
    end)

    it("gives every button role a complete, stateful definition", function()
        local l = lunar.build(palette())
        for _, role in ipairs({ "primary_btn", "actionbutton", "ghost_btn",
                                "danger_btn", "warning_btn", "info_btn" }) do
            local r = l[role]
            assert.is_table(r, role)
            -- Complete: roles replace class rules, so bg/fg/font must be there.
            assert.truthy(r.bg, role .. " bg")
            assert.truthy(r.fg, role .. " fg")
            assert.truthy(r.font, role .. " font")
            -- Stateful: hover and pressed are distinct steps.
            assert.truthy(r.hover, role .. " hover")
            assert.truthy(r.pressed, role .. " pressed")
            assert.not_equal(r.hover, r.pressed, role .. " hover == pressed")
        end
        -- The main verb is the only filled button at rest.
        assert.equal(palette().accent, l.primary_btn.bg)
        assert.not_equal(palette().accent, l.actionbutton.bg)
        -- Every button wears the body font: text and control stay proportionate.
        for _, role in ipairs({ "primary_btn", "actionbutton", "ghost_btn" }) do
            assert.equal(palette().font, l[role].font)
        end
    end)

    it("sizes buttons at VS Code scale, not Carbon slabs", function()
        local l, c = lunar.build(palette()), carbon.build(palette())
        for _, rules in ipairs({ l, c }) do
            for _, role in ipairs({ "primary_btn", "actionbutton", "danger_btn",
                                    "warning_btn", "info_btn" }) do
                assert.equal("12x5", rules[role].padding, role)
            end
            assert.equal("8x3", rules.ghost_btn.padding)
            assert.equal("4x4", rules.icon_btn.padding)
            assert.equal("2x1", rules.link_btn.padding)
        end
        -- The hyperlink never grows a fill or a border.
        assert.equal(l.link_btn.bg, l.link_btn.hover)
        assert.equal(0, l.link_btn.borderwidth)
    end)

    it("keeps gradients off the buttons (fork hover keeps the endpoint fixed)", function()
        local l = lunar.build(palette())
        for _, role in ipairs({ "primary_btn", "actionbutton", "ghost_btn",
                                "danger_btn", "warning_btn", "info_btn", "dropbutton" }) do
            assert.is_nil(l[role].gradcolor, role .. " must not carry a gradient")
        end
        assert.truthy(l.shellheader.gradcolor)
        assert.truthy(l.accentstrip.gradcolor)
    end)
end)

describe("carbon_rules and fluent_rules", function()
    it("also define the new roles, so every theme answers them", function()
        local c = carbon.build(palette())
        local f = fluent.build(palette())
        for _, role in ipairs(NEW_ROLES) do
            assert.is_table(c[role], "carbon missing " .. role)
            assert.is_table(f[role], "fluent missing " .. role)
        end
    end)
end)

describe("Lunar themes", function()
    it("register as lunar_dark (dark) and lunar_light (light)", function()
        local dark = require("core.classes.Themes.LunarDarkTheme"):new()
        local light = require("core.classes.Themes.LunarLightTheme"):new()
        assert.equal("lunar_dark", dark:id())
        assert.equal("lunar_light", light:id())
        assert.is_true(dark:isDark())
        assert.is_false(light:isDark())
        assert.is_table(dark:rules().primary_btn)
        assert.is_table(light:rules().primary_btn)
    end)

    it("pairs as the Match-system defaults", function()
        local SystemTheme = require("core.lib.SystemTheme")
        assert.equal("lunar_dark", SystemTheme.DEFAULT_DARK)
        assert.equal("lunar_light", SystemTheme.DEFAULT_LIGHT)
    end)
end)

describe("ThemeManager pressed-state mapping", function()
    local ThemeManager = require("core.classes.ThemeManager")

    it("resolves disabled flatbutton colors without unsupported IUP attributes", function()
        for _, builder in ipairs({ carbon, fluent, lunar }) do
            local rule = builder.build(palette()).primary_btn
            local active = ThemeManager._attrsFromRule({}, "flatbutton", rule)
            local inactive = ThemeManager._attrsFromRule({}, "flatbutton", rule, true)
            assert.equal(rule.bg, active.BGCOLOR)
            assert.equal(rule.inactivebg, inactive.BGCOLOR)
            assert.equal(rule.inactivefg, inactive.FGCOLOR)
            assert.equal(rule.inactivebg, inactive.HLCOLOR)
            assert.equal(rule.inactivebg, inactive.BORDERCOLOR)
            if rule.gradcolor then assert.equal(rule.inactivebg, inactive.GRADIENTCOLOR) end
            assert.is_nil(inactive.BGINACTIVE)
            assert.is_nil(inactive.TEXTINACTIVE)
            assert.are.same(active, ThemeManager._attrsFromRule({}, "flatbutton", rule, false))
            local label = ThemeManager._attrsFromRule({}, "flatlabel", rule, true)
            assert.equal(rule.bg, label.BGCOLOR)
        end
    end)

    it("reapplies button state on tree notification and theme changes", function()
        local widget = { ACTIVE = "YES" }
        local applied
        local manager = {
            _iup = { GetAttribute = function(w, key) return w[key] end },
            _attrsFromRule = ThemeManager._attrsFromRule,
            _isInactive = ThemeManager._isInactive,
            _themeapply = { apply_save = function(_, attrs) applied = attrs; return {} end },
            _mergeOriginals = function() end,
        }
        local rules = lunar.build(palette())
        ThemeManager._applyElement(manager, widget, rules, "flatbutton", "primary_btn")
        assert.equal(rules.primary_btn.bg, applied.BGCOLOR)
        widget.ACTIVE = "NO"
        ThemeManager._applyElement(manager, widget, rules, "flatbutton", "primary_btn")
        assert.equal(rules.primary_btn.inactivebg, applied.BGCOLOR)
        local changed = palette()
        changed.layer01, changed.surface = "80 80 80", "80 80 80"
        rules = fluent.build(changed)
        ThemeManager._applyElement(manager, widget, rules, "flatbutton", "primary_btn")
        assert.equal("80 80 80", applied.BGCOLOR)
        widget.ACTIVE = "YES"
        ThemeManager._applyElement(manager, widget, rules, "flatbutton", "primary_btn")
        assert.equal(rules.primary_btn.bg, applied.BGCOLOR)
        assert.equal(rules.primary_btn.gradcolor, applied.GRADIENTCOLOR)
    end)

    it("maps pressed/pressedtext to PSCOLOR/TEXTPSCOLOR over the hover default", function()
        local attrs = ThemeManager._attrsFromRule({}, "flatbutton", {
            hover = "1 2 3", pressed = "4 5 6",
            hovertext = "7 8 9", pressedtext = "10 11 12",
        })
        assert.equal("1 2 3", attrs.HLCOLOR)
        assert.equal("4 5 6", attrs.PSCOLOR)
        assert.equal("7 8 9", attrs.TEXTHLCOLOR)
        assert.equal("10 11 12", attrs.TEXTPSCOLOR)
    end)

    it("keeps the old behaviour when only hover is given", function()
        local attrs = ThemeManager._attrsFromRule({}, "flatbutton", { hover = "1 2 3" })
        assert.equal("1 2 3", attrs.HLCOLOR)
        assert.equal("1 2 3", attrs.PSCOLOR)
    end)
end)
