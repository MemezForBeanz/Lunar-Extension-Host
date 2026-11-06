--- The window's own furniture, the same in every rule set: the top bar and what shares it.
--
-- The rule sets call this last, with the few colours that differ between them. The bar sits
-- on the dialog's background, because the part of it nothing covers is the dialog.
--
-- @module core.classes.Themes.shell_rules

--- Add the shell's roles to a rule set.
-- @tparam table rules the rule set
-- @tparam table p the palette
-- @tparam table c `{ well, hover, selected, border, radius, font, small_font }`
return function(rules, p, c)
	local floor = rules.dialog and rules.dialog.bg or p.bg
	rules.titlebar_window = { bg = floor, fg = p.text, muted = p.textMuted, hover = c.hover, pressed = c.selected }
	rules.titlebar_title = { fg = p.textMuted, font = c.font }
	rules.titlebar_button = {
		bg = floor, fg = p.textMuted, border = floor, borderwidth = 0, radius = c.radius,
		hover = c.hover, hovertext = p.text, pressed = c.selected, pressedtext = p.text,
		padding = "0x0", focusfeedback = false,
	}
	rules.titlebar_tabs = {
		bg = floor, fg = p.text, font = c.font, activeline = p.accent,
		tabsbg = floor, tabsfg = p.textMuted,
		border = floor, borderwidth = 0,
		hover = c.hover, selbg = floor,
		radius = c.radius, focusfeedback = false, showlines = false,
		tabspadding = "12x7",
	}
	-- The tool rail continues the bar down the left: one L of chrome around the page.
	rules.tool_rail = {
		bg = rules.flattabs_sub and rules.flattabs_sub.bg or c.well, fg = p.text, font = c.font,
		activeline = p.accent, tabsbg = floor, tabsfg = p.textMuted,
		border = floor, borderwidth = 0,
		hover = c.hover, selbg = c.selected, selrow = c.selected,
		radius = c.radius, focusfeedback = false, showlines = false,
		tabspadding = "16x8",
	}
	rules.pane_split = {}
	for key, value in pairs(rules.split or {}) do rules.pane_split[key] = value end
	rules.pane_split.fixedbar = true

	-- The field's frame draws the edge; the button in it only carries the hint.
	rules.commandbar = {
		bg = c.well, fg = p.textMuted, font = c.small_font,
		border = c.border, borderwidth = 1, showborder = true, radius = c.radius,
		padding = "10x3",
		hover = c.hover, hovertext = p.text,
		pressed = c.selected, pressedtext = p.text,
	}
	rules.commandbar_text = {
		bg = c.well, fg = p.textMuted, font = c.small_font,
		border = c.well, borderwidth = 0, radius = c.radius, padding = "8x0",
		hover = c.well, hovertext = p.text, pressed = c.well, pressedtext = p.text,
	}
	rules.keycap = {
		bg = c.hover, fg = p.textMuted, font = c.small_font,
		border = c.border, borderwidth = 1, showborder = true, radius = c.radius, padding = "6x1",
		hover = c.hover, hovertext = p.text, pressed = c.selected, pressedtext = p.text,
	}
	rules.statusbar_button = rules.statusbar_button or {
		bg = floor, fg = p.textMuted, border = floor, borderwidth = 0, radius = c.radius,
		hover = c.hover, pressed = c.selected,
	}
	return rules
end
