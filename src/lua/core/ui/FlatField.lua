--- A text field drawn by the app instead of by Windows.
--
-- IUP has no flat text control, so a field is a native edit with its border removed,
-- inside a rounded `flatframe` that draws the edge. This is that pair as one widget,
-- with what the bare pattern was missing: the edge lights up in the accent colour
-- while the field has focus, and an optional leading icon sits inside it.
--
-- @classmod core.ui.FlatField
-- @usage
--   local FlatField = require("core.ui.FlatField")   -- or ctx.ui.FlatField
--   local search = FlatField.new(iup, {
--       cue = "Search settings...", icon = icon_dir .. "/search.svg",
--       on_change = function(text) filter(text) end,
--   })
--   parent_box:append(search.widget)

local L = require("core.lib.CarbonLayout")
local VectorIcon = require("core.ui.VectorIcon")

local FlatField = {}
FlatField.__index = FlatField

--- Create a field.
-- @param iup the IUP binding
-- @tparam[opt] table opts
-- @tparam[opt] string opts.value starting text
-- @tparam[opt] string opts.cue greyed hint while empty
-- @tparam[opt] string opts.icon path of an SVG to show at the left
-- @tparam[opt] number opts.width fixed width in pixels; fills the row when omitted
-- @tparam[opt] boolean opts.password hide the text
-- @tparam[opt] function opts.on_change `fn(text)` on every edit
-- @tparam[opt] function opts.on_submit `fn(text)` on Enter
function FlatField.new(iup, opts)
	opts = opts or {}
	local self = setmetatable({ _iup = iup }, FlatField)

	local text = iup.text({
		BORDER = "NO",
		EXPAND = "HORIZONTAL",
		VALUE = opts.value or "",
		CUEBANNER = opts.cue,
		PASSWORD = opts.password and "YES" or nil,
		THEMEROLE = "text",
	})
	self.text = text

	local row = { text, ALIGNMENT = "ACENTER", GAP = L.gap(2), EXPAND = "HORIZONTAL" }
	if opts.icon then
		local icon = VectorIcon.new(iup, { path = opts.icon, size = 16, role = "textMuted" })
		table.insert(row, 1, icon:widget())
	end

	self.widget = iup.flatframe({
		iup.hbox(row),
		TITLE = "",
		MARGIN = L.margin(3, 2),
		EXPAND = opts.width and "NO" or "HORIZONTAL",
		RASTERSIZE = opts.width and (opts.width .. "x") or nil,
		THEMEROLE = "text",
	})

	local field = self
	function text:valuechanged_cb()
		if opts.on_change then opts.on_change(iup.GetAttribute(text, "VALUE") or "") end
		return iup.DEFAULT
	end
	function text:k_any(c)
		if c == iup.K_CR and opts.on_submit then
			opts.on_submit(iup.GetAttribute(text, "VALUE") or "")
			return iup.IGNORE
		end
		return iup.CONTINUE
	end
	function text:getfocus_cb()
		field:_edge(true)
		return iup.DEFAULT
	end
	function text:killfocus_cb()
		field:_edge(false)
		return iup.DEFAULT
	end
	return self
end

-- Swap the frame's role so the theme decides the colour, and the next theme switch
-- leaves a focused field correctly lit.
function FlatField:_edge(focused)
	local iup, frame = self._iup, self.widget
	iup.SetAttribute(frame, "THEMEROLE", focused and "text_focus" or "text")
	local theme = require("core.ui.ThemeReactor").themeManager()
	if theme then pcall(theme.themeWidget, theme, frame) end
end

--- The field's text.
function FlatField:value()
	return self._iup.GetAttribute(self.text, "VALUE") or ""
end

--- Replace the text.
function FlatField:setValue(value)
	self._iup.SetAttribute(self.text, "VALUE", value or "")
end

return FlatField
