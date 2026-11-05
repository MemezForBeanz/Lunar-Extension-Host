--- A code view: monospaced text with line numbers, syntax colour, and the hooks a
-- language feature needs (diagnostic marks, hover, typed characters, a caret).
--
-- It wraps IupScintilla (`require("sci")`, built by cmake/IupScintilla.cmake) and
-- **knows nothing about language servers**. `core.ui.CodeBinder` connects one to
-- a server; a pane that only shows JSON or a log uses it bare.
--
-- **It themes itself.** Every colour comes from the active theme's palette
-- (`core.ui.ThemeReactor`) and is recomputed on a theme switch: the surface and
-- text from the page roles, syntax from `accentBright`, `success`, `warning` and
-- `info`, diagnostics from `error`, `warning` and `info`. A syntax colour that
-- would be hard to read on the surface is pulled toward the text colour until it
-- reaches 4.5:1, so a light theme's yellow does not become invisible code.
--
-- **It draws its own scrollbars.** Scintilla's are Win32 scrollbars, which no
-- theme reaches; they are turned off and replaced by two thin bars drawn with
-- the same colours as every other flat scrollbar.
--
-- Without Scintilla in the build (`CodeView.available()` is false) the view is a
-- plain read-only text box: the text still shows, the marks and hooks are inert.
--
-- Lines and columns are zero-based; columns are **bytes** of UTF-8, which is what
-- Scintilla counts.
--
-- @classmod core.ui.CodeView
local L = require("core.lib.CarbonLayout")

local ok_reactor, ThemeReactor = pcall(require, "core.ui.ThemeReactor")
if not ok_reactor then ThemeReactor = nil end

-- The native module, loaded the first time a view is wanted: requiring it
-- registers Scintilla's window class, which a session with no code never needs.
local sci
local sci_tried = false
local function native()
	if not sci_tried then
		sci_tried = true
		local ok, module = pcall(require, "sci")
		if ok then sci = module end
	end
	return sci
end

local CodeView = {}
CodeView.__index = CodeView

--- Is the real code view (Scintilla) in this build?
function CodeView.available()
	return native() ~= nil
end

-- Scintilla message numbers (vendor/iup-src/iup/srcscintilla/scintilla3112/include).
local SCI = {
	SETTECHNOLOGY = 2630, GETTECHNOLOGY = 2631, SETBUFFEREDDRAW = 2035, SETFONTQUALITY = 2611,
	SETHSCROLLBAR = 2130, SETVSCROLLBAR = 2280, SETCODEPAGE = 2037, USEPOPUP = 2371,
	SETMOUSEDWELLTIME = 2264, SETTABWIDTH = 2036, SETCARETWIDTH = 2188,
	SETSCROLLWIDTH = 2274, GETSCROLLWIDTH = 2275, SETSCROLLWIDTHTRACKING = 2516,
	SETXOFFSET = 2397, GETXOFFSET = 2398,
	GETFIRSTVISIBLELINE = 2152, SETFIRSTVISIBLELINE = 2613, LINESONSCREEN = 2370,
	GETLINECOUNT = 2154, VISIBLEFROMDOCLINE = 2220, ENSUREVISIBLE = 2232,
	POSITIONFROMLINE = 2167, LINEFROMPOSITION = 2166, GETLINEENDPOSITION = 2136, GETLENGTH = 2006,
	POINTXFROMPOSITION = 2164, POINTYFROMPOSITION = 2165, TEXTHEIGHT = 2279, TEXTWIDTH = 2276,
	POSITIONFROMPOINTCLOSE = 2023,
	GETCURRENTPOS = 2008, GOTOPOS = 2025, SETSEL = 2160, GETCHARAT = 2007,
	WORDSTARTPOSITION = 2266, WORDENDPOSITION = 2267,
	SETTARGETSTART = 2190, SETTARGETEND = 2192, REPLACETARGET = 2194,
	SETREADONLY = 2171, SETSAVEPOINT = 2014, EMPTYUNDOBUFFER = 2175, GETMODIFY = 2159,
	SETWRAPMODE = 2268, SETEOLMODE = 2031,
	STYLESETFORE = 2051, STYLESETBACK = 2052, STYLESETBOLD = 2053, STYLESETITALIC = 2054,
	STYLESETSIZE = 2055, STYLESETFONT = 2056, STYLECLEARALL = 2050,
	SETSELFORE = 2067, SETSELBACK = 2068, SETCARETFORE = 2069,
	SETCARETLINEVISIBLE = 2096, SETCARETLINEBACK = 2098, SETCARETLINEVISIBLEALWAYS = 2655,
	SETFOLDMARGINCOLOUR = 2290, SETFOLDMARGINHICOLOUR = 2291,
	SETMARGINTYPEN = 2240, SETMARGINWIDTHN = 2242, SETMARGINMASKN = 2244,
	SETMARGINLEFT = 2155, SETMARGINRIGHT = 2157,
	SETEXTRAASCENT = 2525, SETEXTRADESCENT = 2527,
	MARKERDEFINE = 2040, MARKERSETFORE = 2041, MARKERSETBACK = 2042, MARKERADD = 2043,
	MARKERDELETEALL = 2045,
	INDICSETSTYLE = 2080, INDICSETFORE = 2082, INDICSETUNDER = 2510,
	SETINDICATORCURRENT = 2500, INDICATORFILLRANGE = 2504, INDICATORCLEARRANGE = 2505,
	SETLEXERLANGUAGE = 4006, SETKEYWORDS = 4005, SETPROPERTY = 4004, COLOURISE = 4003,
}
local STYLE_DEFAULT, STYLE_LINENUMBER, STYLE_BRACELIGHT, STYLE_BRACEBAD = 32, 33, 34, 35
local SC_CP_UTF8 = 65001
local SC_TECHNOLOGY_DIRECTWRITE = 1
local SC_EFF_QUALITY_LCD_OPTIMIZED = 3
local SC_MARGIN_SYMBOL, SC_MARGIN_NUMBER = 0, 1
local SC_MARK_CIRCLE, SC_MARK_SMALLRECT = 0, 3
local INDIC_SQUIGGLE, INDIC_DOTS = 1, 10

-- Margins: 0 holds line numbers, 1 the diagnostic marks.
local MARGIN_NUMBERS, MARGIN_MARKS = 0, 1
local MARKS_WIDTH = 14
-- Diagnostic severities 1..4 use markers 0..3 and indicators 8..11 (0..7 belong
-- to lexers).
local FIRST_INDICATOR = 8
local SCROLLBAR_SIZE = 10
local MIN_THUMB = 28

local WINDOWS = package.config:sub(1, 1) == "\\"

-- ---------------------------------------------------------------------------
-- Languages
-- ---------------------------------------------------------------------------

local C_KEYWORDS = "auto break case char const continue default do double else enum extern float for goto if "
	.. "inline int long register restrict return short signed sizeof static struct switch typedef union "
	.. "unsigned void volatile while _Bool _Complex bool true false NULL "
	.. "alignas alignof and and_eq asm bitand bitor catch class compl concept consteval constexpr constinit "
	.. "const_cast co_await co_return co_yield decltype delete dynamic_cast explicit export friend mutable "
	.. "namespace new noexcept not not_eq nullptr operator or or_eq private protected public "
	.. "reinterpret_cast requires static_assert static_cast template this thread_local throw try typeid "
	.. "typename using virtual wchar_t xor xor_eq override final"
local C_TYPES = "size_t ssize_t ptrdiff_t intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t "
	.. "uint32_t uint64_t FILE string vector map set unique_ptr shared_ptr"

--- What each language looks like: its Scintilla lexer, keyword lists, and which
-- theme role colours each lexer style. Roles: `comment`, `keyword`, `type`,
-- `string`, `number`, `preprocessor`, `operator`, `property`, `error`.
CodeView.LANGUAGES = {
	text = { lexer = "null", styles = {} },
	lua = {
		lexer = "lua",
		keywords = {
			[0] = "and break do else elseif end false for function goto if in local nil not or repeat return then true until while",
			[1] = "assert collectgarbage dofile error getmetatable ipairs load loadfile loadstring next pairs pcall print "
				.. "rawequal rawget rawlen rawset require select setmetatable tonumber tostring type unpack xpcall",
			[2] = "string table math io os coroutine debug package bit jit ffi",
		},
		styles = {
			[1] = "comment", [2] = "comment", [3] = "comment", [4] = "number", [5] = "keyword",
			[6] = "string", [7] = "string", [8] = "string", [9] = "preprocessor", [10] = "operator",
			[12] = "error", [13] = "type", [14] = "type", [20] = "preprocessor",
		},
	},
	c = {
		lexer = "cpp",
		keywords = { [0] = C_KEYWORDS, [1] = C_TYPES },
		styles = {
			[1] = "comment", [2] = "comment", [3] = "comment", [15] = "comment", [17] = "comment", [18] = "comment",
			[4] = "number", [5] = "keyword", [16] = "type", [6] = "string", [7] = "string", [13] = "string",
			[20] = "string", [9] = "preprocessor", [10] = "operator", [12] = "error", [27] = "number",
			[23] = "comment", [24] = "comment",
		},
	},
	python = {
		lexer = "python",
		keywords = {
			[0] = "False None True and as assert async await break class continue def del elif else except finally "
				.. "for from global if import in is lambda nonlocal not or pass raise return try while with yield match case",
			[1] = "abs all any bool bytes dict enumerate filter float int len list map max min object open print "
				.. "range repr set sorted str sum super tuple type zip self cls",
		},
		styles = {
			[1] = "comment", [12] = "comment", [2] = "number", [3] = "string", [4] = "string", [6] = "string",
			[7] = "string", [16] = "string", [17] = "string", [18] = "string", [19] = "string",
			[5] = "keyword", [14] = "type", [8] = "type", [9] = "property", [10] = "operator",
			[13] = "error", [15] = "preprocessor",
		},
	},
	csharp = {
		lexer = "cpp",
		keywords = {
			[0] = "abstract as base break case catch checked class const continue default delegate do else enum event "
				.. "explicit extern false finally fixed for foreach goto if implicit in interface internal is lock "
				.. "namespace new null operator out override params private protected public readonly record ref return "
				.. "sealed sizeof stackalloc static struct switch this throw true try typeof unchecked unsafe using "
				.. "virtual void volatile while var async await get set init when where yield nameof partial required",
			[1] = "bool byte char decimal double dynamic float int long object sbyte short string uint ulong ushort "
				.. "nint nuint Task List Dictionary IEnumerable Console String",
		},
		styles = {
			[1] = "comment", [2] = "comment", [3] = "comment", [15] = "comment", [17] = "comment", [18] = "comment",
			[4] = "number", [5] = "keyword", [16] = "type", [6] = "string", [7] = "string", [13] = "string",
			[9] = "preprocessor", [10] = "operator", [12] = "error", [27] = "number",
		},
	},
	json = {
		lexer = "json",
		keywords = { [0] = "true false null" },
		properties = { ["lexer.json.allow.comments"] = "1", ["lexer.json.escape.sequence"] = "1" },
		styles = {
			[1] = "number", [2] = "string", [3] = "error", [4] = "property", [5] = "number",
			[6] = "comment", [7] = "comment", [8] = "operator", [9] = "string", [11] = "keyword",
			[12] = "keyword", [13] = "error",
		},
	},
}
CodeView.LANGUAGES.cpp = CodeView.LANGUAGES.c

local EXTENSIONS = {
	lua = "lua", c = "c", h = "c", cc = "cpp", cpp = "cpp", cxx = "cpp", hh = "cpp", hpp = "cpp", hxx = "cpp",
	py = "python", pyi = "python", cs = "csharp", json = "json", jsonc = "json",
}

--- The language a file name suggests, or `"text"`.
function CodeView.languageOf(path)
	local ext = tostring(path or ""):lower():match("%.([%w]+)$")
	return (ext and EXTENSIONS[ext]) or "text"
end

-- ---------------------------------------------------------------------------
-- Colour
-- ---------------------------------------------------------------------------

local function parse_rgb(value)
	local r, g, b = tostring(value or ""):match("^%s*(%d+)%s+(%d+)%s+(%d+)")
	if not r then return nil end
	return tonumber(r), tonumber(g), tonumber(b)
end

local function luminance(r, g, b)
	local function channel(v)
		v = v / 255
		if v <= 0.03928 then return v / 12.92 end
		return ((v + 0.055) / 1.055) ^ 2.4
	end
	return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
end

--- The WCAG contrast ratio between two `"R G B"` colours.
function CodeView.contrast(a, b)
	local ar, ag, ab = parse_rgb(a)
	local br, bg, bb = parse_rgb(b)
	if not (ar and br) then return 1 end
	local la, lb = luminance(ar, ag, ab), luminance(br, bg, bb)
	if la < lb then la, lb = lb, la end
	return (la + 0.05) / (lb + 0.05)
end

local function mix(a, b, t)
	local ar, ag, ab = parse_rgb(a)
	local br, bg, bb = parse_rgb(b)
	if not (ar and br) then return a end
	local function lerp(x, y) return math.floor(x + (y - x) * t + 0.5) end
	return string.format("%d %d %d", lerp(ar, br), lerp(ag, bg), lerp(ab, bb))
end

--- `color`, pulled toward `text` just far enough to read on `surface`.
-- @tparam string color
-- @tparam string surface
-- @tparam string text
-- @tparam[opt=4.5] number ratio the contrast to reach
function CodeView.readable(color, surface, text, ratio)
	ratio = ratio or 4.5
	if not parse_rgb(color) then return text end
	local out = color
	for step = 1, 10 do
		if CodeView.contrast(out, surface) >= ratio then return out end
		out = mix(color, text, step / 10)
	end
	return out
end

--- The colours a code view uses, worked out from a theme palette.
-- @tparam table palette `"R G B"` strings (`core.classes.Themes.Theme`)
-- @treturn table `surface`, `text`, `muted`, `selection`, `caret_line`, `gutter`,
--   `scroll`, `scroll_hover`, `scroll_press`, the syntax roles, and `severity[1..4]`
function CodeView.colors(palette)
	local p = palette or {}
	local surface = p.layer01 or p.surface or p.bg or "255 255 255"
	local text = p.text or "0 0 0"
	local muted = p.textMuted or mix(text, surface, 0.4)
	local accent = p.accentBright or p.accent or text
	local function role(color, ratio) return CodeView.readable(color or text, surface, text, ratio) end
	return {
		surface = surface,
		text = text,
		muted = muted,
		-- Line numbers sit back from the code, but stay readable (3:1).
		gutter = CodeView.readable(mix(muted, surface, 0.35), surface, muted, 3),
		selection = p.accentSoft or p.layerSelected01 or p.surface2 or mix(surface, text, 0.2),
		caret_line = mix(surface, p.layerHover01 or p.surface2 or text, p.layerHover01 and 0.55 or 0.06),
		scroll = p.borderStrong01 or p.borderStrong or muted,
		scroll_hover = muted,
		scroll_press = p.accent or text,
		comment = role(muted, 3.5),
		keyword = role(accent),
		type = role(p.info or accent),
		string = role(p.success),
		number = role(p.warning),
		preprocessor = role(mix(accent, p.info or accent, 0.5)),
		property = role(accent),
		operator = text,
		error = role(p.error, 3),
		severity = { role(p.error, 3), role(p.warning, 3), role(p.info or accent, 3), role(muted, 3) },
	}
end

-- A monospaced face from a theme font (`"Segoe UI, 10"`): the size follows the theme.
function CodeView.font(theme_font)
	local size = tonumber(tostring(theme_font or ""):match("(%d+)%s*$")) or 10
	return WINDOWS and "Consolas" or "DejaVu Sans Mono", size
end

local function bgr(color)
	local r, g, b = parse_rgb(color)
	if not r then return 0 end
	return r + g * 256 + b * 65536
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

local function palette()
	return (ThemeReactor and ThemeReactor.palette()) or {}
end

--- Create a code view.
--
-- @tparam userdata iup
-- @tparam[opt] table opts
-- @tparam[opt="text"] string opts.language a key of `CodeView.LANGUAGES`
-- @tparam[opt=true] boolean opts.read_only
-- @tparam[opt=true] boolean opts.line_numbers
-- @tparam[opt=false] boolean opts.wrap wrap long lines
-- @tparam[opt=true] boolean opts.framed draw the standard recessed edge around it
-- @tparam[opt] string opts.text
function CodeView.new(iup, opts)
	opts = opts or {}
	native()
	local self = setmetatable({
		_iup = iup,
		_language = CodeView.LANGUAGES[opts.language] and opts.language or "text",
		_read_only = opts.read_only ~= false,
		_line_numbers = opts.line_numbers ~= false,
		_wrap = opts.wrap == true,
		_text = opts.text or "",
		_diagnostics = {},
		_ready = false,
		rich = sci ~= nil,
	}, CodeView)
	if sci then self:_buildScintilla() else self:_buildPlain() end
	if opts.framed == false then
		self._widget = self._body
	else
		self._widget = iup.flatframe({ self._body, TITLE = "", MARGIN = L.margin(1), EXPAND = "YES", THEMEROLE = "well" })
	end
	if ThemeReactor then ThemeReactor.register(self) end
	return self
end

--- The widget to put in a layout.
function CodeView:widget() return self._widget end

--- The text control itself (an `iup.scintilla`, or an `iup.text` without Scintilla).
function CodeView:control() return self._control end

function CodeView:_buildPlain()
	local iup = self._iup
	self._control = iup.text({
		MULTILINE = "YES", READONLY = self._read_only and "YES" or "NO", EXPAND = "YES",
		WORDWRAP = self._wrap and "YES" or "NO", BORDER = "NO", FONT = "Consolas, 10",
		VALUE = self._text, THEMEROLE = "outputlog",
	})
	local view = self
	function self._control:valuechanged_cb()
		view._text = iup.GetAttribute(view._control, "VALUE") or ""
		if view._on_change then view._on_change(view._text) end
		return iup.DEFAULT
	end
	self._body = self._control
	self._ready = true
end

function CodeView:_send(message, wparam, lparam)
	return sci.send(self._control, message, wparam or 0, lparam or 0)
end

function CodeView:_buildScintilla()
	local iup = self._iup
	local view = self
	local control = iup.scintilla({
		EXPAND = "YES", BORDER = "NO", SCROLLBAR = "NO",
		VISIBLECOLUMNS = "20", VISIBLELINES = "4",
	})
	self._control = control

	function control:map_cb()
		view:_configure()
		return iup.DEFAULT
	end
	function control:valuechanged_cb()
		if view._setting then return iup.DEFAULT end
		view:_syncNumbers()
		view:_updateBars()
		if view._on_change then view._on_change(view:text()) end
		return iup.DEFAULT
	end
	function control:action(insert, _, length, text)
		if insert == 1 and length == 1 and view._on_char and not view._setting then
			view._typed = text
		end
		return iup.DEFAULT
	end
	function control:updatecontent_cb()
		-- The character is reported after it is in the buffer, so a completion
		-- request made from here sees the text it is about.
		local typed = view._typed
		view._typed = nil
		if typed and view._on_char then view._on_char(typed) end
		return iup.DEFAULT
	end
	function control:caret_cb(line, column)
		if view._on_caret then view._on_caret(line, column) end
		return iup.DEFAULT
	end
	function control:dwell_cb(state, position, x, y)
		if not view._on_hover then return iup.DEFAULT end
		if state == 1 and position >= 0 then
			local line = view:_send(SCI.LINEFROMPOSITION, position)
			local column = position - view:_send(SCI.POSITIONFROMLINE, line)
			view._on_hover(line, column, view:_screenPoint(position))
		else
			view._on_hover(nil)
		end
		return iup.DEFAULT
	end
	function control:updatevscroll_cb() view:_updateBars(); if view._on_scroll then view._on_scroll() end; return iup.DEFAULT end
	function control:updatehscroll_cb() view:_updateBars(); if view._on_scroll then view._on_scroll() end; return iup.DEFAULT end
	function control:k_any(key)
		if view._on_key and view._on_key(key) then return iup.IGNORE end
		return iup.CONTINUE
	end
	function control:button_cb(button, pressed, x, y, status)
		if view._on_click and button == iup.BUTTON1 and pressed == 1 then
			local position = view:_send(SCI.POSITIONFROMPOINTCLOSE, x, y)
			if position >= 0 then
				local line = view:_send(SCI.LINEFROMPOSITION, position)
				local column = position - view:_send(SCI.POSITIONFROMLINE, line)
				if view._on_click(line, column, status) then return iup.IGNORE end
			end
		end
		return iup.DEFAULT
	end
	function control:killfocus_cb()
		if view._on_blur then view._on_blur() end
		return iup.DEFAULT
	end

	self._vbar = self:_scrollbar(true)
	self._hbar = self:_scrollbar(false)
	self._body = iup.vbox({
		iup.hbox({ control, self._vbar.canvas, MARGIN = "0x0", GAP = "0" }),
		iup.hbox({ self._hbar.canvas, iup.canvas({ RASTERSIZE = SCROLLBAR_SIZE .. "x" .. SCROLLBAR_SIZE, BORDER = "NO",
			CANFOCUS = "NO", EXPAND = "NO", THEMEROLE = "codeview_corner" }), MARGIN = "0x0", GAP = "0" }),
		MARGIN = "0x0", GAP = "0", EXPAND = "YES",
	})
	-- The corner square between the two bars is a blank surface.
	local corner = iup.GetChild(iup.GetChild(self._body, 1), 1)
	self._corner = corner
	function corner:action()
		iup.DrawBegin(corner)
		local w, h = iup.DrawGetSize(corner)
		iup.SetAttribute(corner, "DRAWSTYLE", "FILL")
		iup.SetAttribute(corner, "DRAWCOLOR", view._colors and view._colors.surface or "255 255 255")
		iup.DrawRectangle(corner, 0, 0, w - 1, h - 1)
		iup.DrawEnd(corner)
		return iup.DEFAULT
	end
end

-- ---------------------------------------------------------------------------
-- Scrollbars
-- ---------------------------------------------------------------------------

-- Where the view is and how much there is: `first`, `page`, `total` in lines
-- (vertical) or pixels (horizontal).
function CodeView:_scrollState(vertical)
	if vertical then
		local total = self:_send(SCI.VISIBLEFROMDOCLINE, self:_send(SCI.GETLINECOUNT))
		return self:_send(SCI.GETFIRSTVISIBLELINE), self:_send(SCI.LINESONSCREEN), total
	end
	local width = tonumber(tostring(self._iup.GetAttribute(self._control, "RASTERSIZE") or ""):match("^(%d+)x")) or 0
	local margins = (self._number_width or 0) + MARKS_WIDTH + 8
	local page = math.max(1, width - margins)
	return self:_send(SCI.GETXOFFSET), page, self:_send(SCI.GETSCROLLWIDTH)
end

function CodeView:_scrollTo(vertical, first)
	local _, page, total = self:_scrollState(vertical)
	first = math.max(0, math.min(math.floor(first + 0.5), math.max(0, total - page)))
	if vertical then self:_send(SCI.SETFIRSTVISIBLELINE, first) else self:_send(SCI.SETXOFFSET, first) end
	self:_updateBars()
end

function CodeView:_scrollbar(vertical)
	local iup = self._iup
	local view = self
	local bar = { vertical = vertical, hover = false, drag = nil }
	local canvas = iup.canvas({
		RASTERSIZE = vertical and (SCROLLBAR_SIZE .. "x") or ("x" .. SCROLLBAR_SIZE),
		EXPAND = vertical and "VERTICAL" or "HORIZONTAL",
		BORDER = "NO", CANFOCUS = "NO",
	})
	bar.canvas = canvas

	-- The thumb's start and length along the bar, or nil when everything fits.
	local function thumb(length)
		if not view._ready then return nil end
		local first, page, total = view:_scrollState(vertical)
		if total <= page or length <= 0 then return nil end
		local size = math.max(MIN_THUMB, math.floor(length * page / total))
		if size >= length then return nil end
		local start = math.floor((length - size) * first / (total - page) + 0.5)
		return math.max(0, math.min(start, length - size)), size, total - page
	end

	function canvas:action()
		iup.DrawBegin(canvas)
		local w, h = iup.DrawGetSize(canvas)
		local colors = view._colors or CodeView.colors(palette())
		iup.SetAttribute(canvas, "DRAWSTYLE", "FILL")
		iup.SetAttribute(canvas, "DRAWCOLOR", colors.surface)
		iup.DrawRectangle(canvas, 0, 0, w - 1, h - 1)
		local start, size = thumb(vertical and h or w)
		if start then
			iup.SetAttribute(canvas, "DRAWCOLOR",
				(bar.drag and colors.scroll_press) or (bar.hover and colors.scroll_hover) or colors.scroll)
			-- A 6px pill: a rectangle with a 1px notch off each corner.
			local a, b = start + 1, start + size - 2
			if vertical then
				iup.DrawRectangle(canvas, 2, a + 1, w - 3, b - 1)
				iup.DrawRectangle(canvas, 3, a, w - 4, b)
			else
				iup.DrawRectangle(canvas, a + 1, 2, b - 1, h - 3)
				iup.DrawRectangle(canvas, a, 3, b, h - 4)
			end
		end
		iup.DrawEnd(canvas)
		return iup.DEFAULT
	end

	local function along(x, y) return vertical and y or x end
	local function length()
		local w, h = tostring(iup.GetAttribute(canvas, "RASTERSIZE") or ""):match("^(%d+)x(%d+)")
		return tonumber(vertical and h or w) or 0
	end

	function canvas:button_cb(button, pressed, x, y)
		if button ~= iup.BUTTON1 then return iup.DEFAULT end
		if pressed == 0 then
			bar.drag = nil
			iup.Update(canvas)
			return iup.DEFAULT
		end
		local start, size = thumb(length())
		if not start then return iup.DEFAULT end
		local at = along(x, y)
		if at >= start and at < start + size then
			bar.drag = at - start
		else
			-- A click on the track pages toward it.
			local first, page = view:_scrollState(vertical)
			view:_scrollTo(vertical, first + (at < start and -page or page))
		end
		iup.Update(canvas)
		return iup.DEFAULT
	end
	function canvas:motion_cb(x, y)
		if not bar.drag then return iup.DEFAULT end
		local len = length()
		local _, size, range = thumb(len)
		if not size or len <= size then return iup.DEFAULT end
		view:_scrollTo(vertical, (along(x, y) - bar.drag) * range / (len - size))
		return iup.DEFAULT
	end
	function canvas:enterwindow_cb() bar.hover = true; iup.Update(canvas); return iup.DEFAULT end
	function canvas:leavewindow_cb() bar.hover = false; iup.Update(canvas); return iup.DEFAULT end
	return bar
end

function CodeView:_updateBars()
	if not (self._ready and self._vbar) then return end
	pcall(self._iup.Update, self._vbar.canvas)
	pcall(self._iup.Update, self._hbar.canvas)
end

-- ---------------------------------------------------------------------------
-- Configuration and theme
-- ---------------------------------------------------------------------------

function CodeView:_configure()
	self._ready = true
	self:_send(SCI.SETCODEPAGE, SC_CP_UTF8)
	-- The Win32 scrollbars: gone. The bars beside the control stand in for them.
	self:_send(SCI.SETHSCROLLBAR, 0)
	self:_send(SCI.SETVSCROLLBAR, 0)
	-- DirectWrite text where the platform has it; Scintilla stays on GDI if not.
	if WINDOWS then
		self:_send(SCI.SETTECHNOLOGY, SC_TECHNOLOGY_DIRECTWRITE)
		if self:_send(SCI.GETTECHNOLOGY) == SC_TECHNOLOGY_DIRECTWRITE then self:_send(SCI.SETBUFFEREDDRAW, 0) end
		self:_send(SCI.SETFONTQUALITY, SC_EFF_QUALITY_LCD_OPTIMIZED)
	end
	self:_send(SCI.USEPOPUP, 0)
	self:_send(SCI.SETMOUSEDWELLTIME, 450)
	self:_send(SCI.SETTABWIDTH, 4)
	self:_send(SCI.SETCARETWIDTH, 2)
	self:_send(SCI.SETSCROLLWIDTH, 1)
	self:_send(SCI.SETSCROLLWIDTHTRACKING, 1)
	self:_send(SCI.SETWRAPMODE, self._wrap and 1 or 0)
	self:_send(SCI.SETEXTRAASCENT, 1)
	self:_send(SCI.SETEXTRADESCENT, 1)
	self:_send(SCI.SETMARGINLEFT, 0, 8)
	self:_send(SCI.SETMARGINRIGHT, 0, 8)
	self:_send(SCI.SETMARGINTYPEN, MARGIN_NUMBERS, SC_MARGIN_NUMBER)
	self:_send(SCI.SETMARGINTYPEN, MARGIN_MARKS, SC_MARGIN_SYMBOL)
	self:_send(SCI.SETMARGINMASKN, MARGIN_MARKS, 15)   -- markers 0..3
	self:_send(SCI.SETMARGINWIDTHN, MARGIN_MARKS, self._line_numbers and MARKS_WIDTH or 0)
	for margin = 2, 4 do self:_send(SCI.SETMARGINWIDTHN, margin, 0) end
	for severity = 1, 4 do
		self:_send(SCI.MARKERDEFINE, severity - 1, severity <= 2 and SC_MARK_CIRCLE or SC_MARK_SMALLRECT)
		self:_send(SCI.INDICSETSTYLE, FIRST_INDICATOR + severity - 1, severity <= 2 and INDIC_SQUIGGLE or INDIC_DOTS)
		self:_send(SCI.INDICSETUNDER, FIRST_INDICATOR + severity - 1, 1)
	end
	self:_applyTheme()
	self:_applyLanguage()
	self:_putText(self._text)
	self:_send(SCI.SETREADONLY, self._read_only and 1 or 0)
	self:_drawDiagnostics()
	if self._pending_goto then
		local target = self._pending_goto
		self._pending_goto = nil
		self:goTo(target.line, target.column, target.end_line, target.end_column)
	end
end

function CodeView:_applyTheme()
	local p = palette()
	local colors = CodeView.colors(p)
	self._colors = colors
	if not self._ready then return end
	if not sci then return end
	local face, size = CodeView.font(p.font)
	sci.sends(self._control, SCI.STYLESETFONT, STYLE_DEFAULT, face)
	self:_send(SCI.STYLESETSIZE, STYLE_DEFAULT, size)
	self:_send(SCI.STYLESETFORE, STYLE_DEFAULT, bgr(colors.text))
	self:_send(SCI.STYLESETBACK, STYLE_DEFAULT, bgr(colors.surface))
	self:_send(SCI.STYLECLEARALL)
	self:_send(SCI.STYLESETFORE, STYLE_LINENUMBER, bgr(colors.gutter))
	self:_send(SCI.STYLESETBACK, STYLE_LINENUMBER, bgr(colors.surface))
	self:_send(SCI.STYLESETFORE, STYLE_BRACELIGHT, bgr(colors.keyword))
	self:_send(SCI.STYLESETBOLD, STYLE_BRACELIGHT, 1)
	self:_send(SCI.STYLESETFORE, STYLE_BRACEBAD, bgr(colors.error))
	self:_send(SCI.SETFOLDMARGINCOLOUR, 1, bgr(colors.surface))
	self:_send(SCI.SETFOLDMARGINHICOLOUR, 1, bgr(colors.surface))
	self:_send(SCI.SETCARETFORE, bgr(colors.text))
	self:_send(SCI.SETCARETLINEVISIBLE, 1)
	self:_send(SCI.SETCARETLINEVISIBLEALWAYS, 1)
	self:_send(SCI.SETCARETLINEBACK, bgr(colors.caret_line))
	self:_send(SCI.SETSELFORE, 0, 0)
	self:_send(SCI.SETSELBACK, 1, bgr(colors.selection))
	for severity = 1, 4 do
		local color = bgr(colors.severity[severity])
		self:_send(SCI.MARKERSETFORE, severity - 1, color)
		self:_send(SCI.MARKERSETBACK, severity - 1, color)
		self:_send(SCI.INDICSETFORE, FIRST_INDICATOR + severity - 1, color)
	end
	self:_styleLanguage()
	self._digits = nil
	self:_syncNumbers()
	self:_updateBars()
	if self._corner then pcall(self._iup.Update, self._corner) end
end

--- Put the control's own look back after a generic theme pass.
-- FONT and FGCOLOR on IupScintilla rewrite every style, and both are inherited, so
-- theming anything above this control undoes the code font and the language colours.
-- The lexer keeps its place: only the style table needs writing again.
function CodeView:restyle()
	if self._ready then self:_applyTheme() end
end

function CodeView:_afterThemePass()
	self:_onThemeApply()
end

-- Called by core.ui.ThemeReactor after every theme switch.
function CodeView:_onThemeApply()
	local ok = pcall(self.restyle, self)
	if not ok then self._ready = false end   -- the control is gone
end

function CodeView:_styleLanguage()
	local language = CodeView.LANGUAGES[self._language] or CodeView.LANGUAGES.text
	local colors = self._colors
	for style, role in pairs(language.styles) do
		self:_send(SCI.STYLESETFORE, style, bgr(colors[role] or colors.text))
		if role == "comment" then self:_send(SCI.STYLESETITALIC, style, 1) end
	end
end

function CodeView:_applyLanguage()
	if not (self._ready and sci) then return end
	local language = CodeView.LANGUAGES[self._language] or CodeView.LANGUAGES.text
	sci.sends(self._control, SCI.SETLEXERLANGUAGE, 0, language.lexer)
	for set, words in pairs(language.keywords or {}) do
		sci.sends(self._control, SCI.SETKEYWORDS, set, words)
	end
	for name, value in pairs(language.properties or {}) do
		self._iup.SetAttribute(self._control, "PROPERTY", name .. "=" .. value)
	end
	-- Styles are per lexer: clear the last language's, then colour this one's.
	self:_send(SCI.STYLECLEARALL)
	self:_send(SCI.STYLESETFORE, STYLE_LINENUMBER, bgr(self._colors.gutter))
	self:_send(SCI.STYLESETBACK, STYLE_LINENUMBER, bgr(self._colors.surface))
	self:_styleLanguage()
	self:_send(SCI.COLOURISE, 0, -1)
end

-- Keep the line-number margin as wide as the longest number needs.
function CodeView:_syncNumbers()
	if not (self._ready and sci) then return end
	if not self._line_numbers then
		self._number_width = 0
		self:_send(SCI.SETMARGINWIDTHN, MARGIN_NUMBERS, 0)
		return
	end
	local digits = math.max(3, #tostring(self:_send(SCI.GETLINECOUNT)))
	if digits == self._digits then return end
	self._digits = digits
	self._number_width = sci.sends(self._control, SCI.TEXTWIDTH, STYLE_LINENUMBER, "_" .. string.rep("9", digits))
	self:_send(SCI.SETMARGINWIDTHN, MARGIN_NUMBERS, self._number_width)
end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------

function CodeView:_putText(text)
	self._setting = true
	self:_send(SCI.SETREADONLY, 0)
	-- New lines typed into the file end the way its own lines do (0: CRLF, 2: LF).
	self:_send(SCI.SETEOLMODE, text:find(string.char(13, 10), 1, true) and 0 or 2)
	self._iup.SetAttribute(self._control, "VALUE", text)
	self:_send(SCI.EMPTYUNDOBUFFER)
	self:_send(SCI.SETSAVEPOINT)
	self:_send(SCI.SETREADONLY, self._read_only and 1 or 0)
	self._setting = false
	self._digits = nil
	self:_syncNumbers()
	self:_updateBars()
end

--- Replace the text. Diagnostics are cleared: they described the old text.
function CodeView:setText(text)
	self._text = text or ""
	self._diagnostics = {}
	if not self._ready then return end
	if not sci then
		self._iup.SetAttribute(self._control, "VALUE", self._text)
		return
	end
	self:_putText(self._text)
	self:_drawDiagnostics()
end

--- The current text.
function CodeView:text()
	if self._ready and sci then return self._iup.GetAttribute(self._control, "VALUE") or "" end
	return self._text
end

--- Change the language (a key of `CodeView.LANGUAGES`; unknown means plain text).
function CodeView:setLanguage(language)
	self._language = CodeView.LANGUAGES[language] and language or "text"
	self:_applyLanguage()
end

function CodeView:language() return self._language end

--- Allow or refuse edits.
function CodeView:setReadOnly(read_only)
	self._read_only = read_only ~= false
	if not self._ready then return end
	if sci then
		self:_send(SCI.SETREADONLY, self._read_only and 1 or 0)
	else
		self._iup.SetAttribute(self._control, "READONLY", self._read_only and "YES" or "NO")
	end
end

function CodeView:isReadOnly() return self._read_only end

--- Has the text changed since it was loaded or `markSaved` was called?
function CodeView:isModified()
	if not (self._ready and sci) then return false end
	return self:_send(SCI.GETMODIFY) ~= 0
end

--- Say the text is now what is on disk.
function CodeView:markSaved()
	if self._ready and sci then self:_send(SCI.SETSAVEPOINT) end
end

-- ---------------------------------------------------------------------------
-- Positions
-- ---------------------------------------------------------------------------

function CodeView:_position(line, column)
	local start = self:_send(SCI.POSITIONFROMLINE, line)
	if start < 0 then return self:_send(SCI.GETLENGTH) end
	return math.min(start + math.max(0, column or 0), self:_send(SCI.GETLINEENDPOSITION, line))
end

-- Screen coordinates of the left edge of a position, and of the line below it.
function CodeView:_screenPoint(position)
	local origin_x, origin_y = tostring(self._iup.GetAttribute(self._control, "SCREENPOSITION") or "")
		:match("(-?%d+),(-?%d+)")
	local line = self:_send(SCI.LINEFROMPOSITION, position)
	local x = self:_send(SCI.POINTXFROMPOSITION, 0, position)
	local y = self:_send(SCI.POINTYFROMPOSITION, 0, position)
	local height = self:_send(SCI.TEXTHEIGHT, line)
	return { x = (tonumber(origin_x) or 0) + x, y = (tonumber(origin_y) or 0) + y, line_height = height }
end

--- Where the caret is.
-- @treturn number line
-- @treturn number byte column
function CodeView:caret()
	if not (self._ready and sci) then return 0, 0 end
	local position = self:_send(SCI.GETCURRENTPOS)
	local line = self:_send(SCI.LINEFROMPOSITION, position)
	return line, position - self:_send(SCI.POSITIONFROMLINE, line)
end

--- Screen position of a place in the text: `{ x, y, line_height }`, `y` being the
-- top of its line. For anchoring a popup.
function CodeView:pointOf(line, column)
	if not (self._ready and sci) then return nil end
	return self:_screenPoint(self:_position(line, column))
end

--- The identifier around a column: where it starts and ends on the line, and its text.
-- @treturn number start column
-- @treturn number end column
-- @treturn string
function CodeView:wordAt(line, column)
	if not (self._ready and sci) then return column, column, "" end
	local position = self:_position(line, column)
	local line_start = self:_send(SCI.POSITIONFROMLINE, line)
	local from = self:_send(SCI.WORDSTARTPOSITION, position, 1)
	local to = self:_send(SCI.WORDENDPOSITION, position, 1)
	local text = self:lineText(line)
	return from - line_start, to - line_start, text:sub(from - line_start + 1, to - line_start)
end

--- One line's text, without its line ending.
function CodeView:lineText(line)
	if not (self._ready and sci) then return "" end
	local from = self:_send(SCI.POSITIONFROMLINE, line)
	local to = self:_send(SCI.GETLINEENDPOSITION, line)
	if from < 0 or to <= from then return "" end
	return self:text():sub(from + 1, to)
end

--- How many lines there are.
function CodeView:lineCount()
	if not (self._ready and sci) then return select(2, self._text:gsub("\n", "\n")) + 1 end
	return self:_send(SCI.GETLINECOUNT)
end

--- Replace a stretch of one line (an accepted completion).
function CodeView:replace(line, from_column, to_column, text)
	if not (self._ready and sci) or self._read_only then return false end
	local from, to = self:_position(line, from_column), self:_position(line, to_column)
	self:_send(SCI.SETTARGETSTART, from)
	self:_send(SCI.SETTARGETEND, to)
	sci.sends(self._control, SCI.REPLACETARGET, #text, text)
	self:_send(SCI.GOTOPOS, from + #text)
	return true
end

--- Move the caret to a place and bring it into view, a third of the way down.
-- With an end, the range is selected, which is how a destination is pointed out.
function CodeView:goTo(line, column, end_line, end_column)
	if not self._ready then
		self._pending_goto = { line = line, column = column, end_line = end_line, end_column = end_column }
		return
	end
	if not sci then return end
	line = math.max(0, math.min(line or 0, self:_send(SCI.GETLINECOUNT) - 1))
	self:_send(SCI.ENSUREVISIBLE, line)
	local from = self:_position(line, column or 0)
	if end_line then
		self:_send(SCI.SETSEL, from, self:_position(end_line, end_column or 0))
	else
		self:_send(SCI.GOTOPOS, from)
	end
	local page = self:_send(SCI.LINESONSCREEN)
	local display = self:_send(SCI.VISIBLEFROMDOCLINE, line)
	self:_send(SCI.SETFIRSTVISIBLELINE, math.max(0, display - math.floor(page / 3)))
	self:_updateBars()
end

--- Give the view the keyboard.
function CodeView:focus()
	pcall(self._iup.SetFocus, self._control)
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

--- Mark problems in the text: a squiggle under each range and a mark in the
-- gutter on its line (the most severe, when a line has several).
--
-- @tparam {table,...} list each `{ line, column, end_line, end_column, severity, message }`;
--   `severity` is 1 (error) to 4 (hint)
function CodeView:setDiagnostics(list)
	self._diagnostics = list or {}
	self:_drawDiagnostics()
end

function CodeView:_drawDiagnostics()
	if not (self._ready and sci) then return end
	local length = self:_send(SCI.GETLENGTH)
	for severity = 1, 4 do
		self:_send(SCI.SETINDICATORCURRENT, FIRST_INDICATOR + severity - 1)
		self:_send(SCI.INDICATORCLEARRANGE, 0, length)
		self:_send(SCI.MARKERDELETEALL, severity - 1)
	end
	local worst = {}
	for _, d in ipairs(self._diagnostics) do
		local severity = math.max(1, math.min(4, tonumber(d.severity) or 1))
		local from = self:_position(d.line, d.column)
		local to = self:_position(d.end_line or d.line, d.end_column or d.column)
		if to <= from then
			-- A point: mark the word there, or one character, so there is something to see.
			local word_end = self:_send(SCI.WORDENDPOSITION, from, 1)
			to = word_end > from and word_end or from + 1
			if to > length then from, to = math.max(0, length - 1), length end
		end
		if to > from then
			self:_send(SCI.SETINDICATORCURRENT, FIRST_INDICATOR + severity - 1)
			self:_send(SCI.INDICATORFILLRANGE, from, to - from)
		end
		if not worst[d.line] or severity < worst[d.line] then worst[d.line] = severity end
	end
	for line, severity in pairs(worst) do self:_send(SCI.MARKERADD, line, severity - 1) end
end

--- The diagnostics covering a place, most severe first.
function CodeView:diagnosticsAt(line, column)
	local out = {}
	for _, d in ipairs(self._diagnostics) do
		local end_line, end_column = d.end_line or d.line, d.end_column or d.column
		local starts = d.line < line or (d.line == line and d.column <= column)
		local ends = end_line > line or (end_line == line and math.max(end_column, d.column + 1) >= column)
		if starts and ends then out[#out + 1] = d end
	end
	table.sort(out, function(a, b) return (a.severity or 1) < (b.severity or 1) end)
	return out
end

--- The diagnostics on a line, most severe first.
function CodeView:diagnosticsOnLine(line)
	local out = {}
	for _, d in ipairs(self._diagnostics) do
		if d.line == line then out[#out + 1] = d end
	end
	table.sort(out, function(a, b) return (a.severity or 1) < (b.severity or 1) end)
	return out
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

--- `fn(text)` after the user edits.
function CodeView:onChange(fn) self._on_change = fn end
--- `fn(line, column, point)` when the pointer rests on text; `fn(nil)` when it moves on.
function CodeView:onHover(fn) self._on_hover = fn end
--- `fn(character)` after a single character is typed.
function CodeView:onChar(fn) self._on_char = fn end
--- `fn(line, column)` when the caret moves.
function CodeView:onCaret(fn) self._on_caret = fn end
--- `fn(key) -> handled` before the view acts on a key.
function CodeView:onKey(fn) self._on_key = fn end
--- `fn(line, column, status) -> handled` on a left press on text.
function CodeView:onClick(fn) self._on_click = fn end
--- `fn()` when the view scrolls.
function CodeView:onScroll(fn) self._on_scroll = fn end
--- `fn()` when the view loses the keyboard.
function CodeView:onBlur(fn) self._on_blur = fn end

return CodeView
